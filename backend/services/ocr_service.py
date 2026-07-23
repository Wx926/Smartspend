"""
OCR-Based Receipt Digitisation Pipeline (FYP report Chapter 3.1.2 / Algorithm 1).

Stage 1: Image Input and Validation
Stage 2: Text Extraction via Google Cloud Vision API (DOCUMENT_TEXT_DETECTION)
Stage 3: Post-Processing and Data Structure (regex for vendor/date/amount + line items + warranty scan)
Stage 4: Warranty Validity Assessment  (delegated to warranty_service)
"""

import io
import re
import os
import base64
import json
import urllib.request
from datetime import datetime, date

from dotenv import load_dotenv
load_dotenv()

from services.categorisation_service import categorise_text, category_result_for
from services.warranty_service import detect_warranty

GOOGLE_VISION_API_KEY = os.environ.get("GOOGLE_VISION_API_KEY", "")

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "pdf"}
MAX_FILE_SIZE_MB = 10

AMOUNT_PATTERN = re.compile(
    r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*(\d+[.,]\d{2})",
    re.IGNORECASE,
)
DATE_PATTERNS = [
    r"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})",   # 27/06/2026 or 27-06-26
    r"(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})",     # 2026-06-27
    r"(\d{4}\.\d{1,2}\.\d{1,2})",             # 2026.07.15 (dot-separated POS timestamp)
]

# Restricted to actual month names/abbreviations (not any 3-9 letter word) —
# an earlier looser version matched things like "Seksyen 14, 46100" (an
# address/postcode fragment) as a false "date". Each letter allows an
# optional stray space after it (matching e.g. "M ar" as well as "Mar") since
# Vision sometimes splits a short word mid-way; the month/day and day/year
# gaps are also optional whitespace, since Vision is equally inconsistent
# about whether it prints a space there at all ("Mar 30,2026" vs "Mar30,2026").
def _loose(word: str) -> str:
    return r"\s?".join(re.escape(c) for c in word)


_MONTH_TO_NUM = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}
_MONTH_NAME = "(?:" + "|".join(_loose(abbr) for abbr in _MONTH_TO_NUM) + r")[A-Za-z]*"
_MONTH_NAME_DATE = re.compile(
    rf"({_MONTH_NAME})\s*(\d{{1,2}}),?\s*(\d{{4}})", re.IGNORECASE
)

_CURRENCY = r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*"

# CJK Unicode ranges (common + extension-A) — Malaysian receipts are frequently
# printed in Mandarin (esp. Chinese-Malaysian restaurants/vendors), and Chinese
# item names carry no spaces between characters, so they must be admitted into
# the same name-matching character classes as Latin letters, not handled as a
# separate special case. Full-width parentheses are included too (e.g. a size
# marker like "（小）" for "(Small)") — the ASCII "()" already allowed
# elsewhere in these patterns doesn't cover their full-width equivalents.
_CJK = r"一-鿿㐀-䶿（）"

# A standalone "-" (space-hyphen-space, a stylistic word separator like
# "Naughty Spare Rib - Full Slab"), a standalone "&" (space-ampersand-space,
# e.g. "Fish & Chips" — as opposed to one glued onto a word, e.g. "Fish&Chips",
# which the word-token character classes already cover on their own), or a
# "+"/"/"-joined size descriptor like "1+1/2" (as in "HH Asahi 1+1/2") — none
# of these fit a plain word token, so all three need their own alternative in
# the word-continuation groups below.
_LOOSE_WORD_SEP = r"-|::|&|\d+(?:[+\/]\d+)+"

# Single-line item: alphabetical name, optional product-code/content in middle, price at end.
# e.g. "TEH TARIK 3.50"  →  TEH TARIK, 3.50
# e.g. "FRAP 001200010451 F 5.48 N"  →  FRAP, 5.48
# e.g. "1/2 Roasted Chicken 15.90" → 1/2 Roasted Chicken, 15.90 (menu portion
#      names like "1/4"/"1/2" start with a fraction, not a letter)
# Word tokens allow embedded digits (e.g. "R1-12", "R1-4pcs" — a department/
# SKU code glued onto the front of the name on some invoice layouts) and a
# bare 1-4 digit continuation word (e.g. the "100" in "Gummy Shark 100 pc"),
# matching the same allowances _NAME_ONLY already makes — without them, any
# item name containing an embedded number failed to match this layout at all.
LINE_ITEM_PATTERN = re.compile(
    rf"^((?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*|\d+\/\d+)"
    rf"(?:\s(?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*"
    rf"|[0-9]+[A-Za-z][A-Za-z0-9\-&'\/\(\)]*|\d{{1,4}}|{_LOOSE_WORD_SEP}))*)"
    rf"\s+.*?{_CURRENCY}(\d+[.,]\d{{2}})\s*\*?\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)


def _match_line_item(line: str) -> re.Match | None:
    """LINE_ITEM_PATTERN.match(), with one extra safety check: if the gap
    between the captured name and the captured price contains ANOTHER
    decimal number, only accept the match when the line ends with a
    trailing 1-2 letter tax code — a strong "this row is deliberately
    closed out" signal. Without this, a row with an embedded discount/
    subtotal column ahead of the real total (e.g. "A01 - SERVICE 0.00
    499.00", where "0.00" is a discount column, not part of the name) reads
    as a plausible name+price match for the WRONG number entirely, since the
    non-greedy middle gap will happily skip over an earlier decimal to reach
    a later one.
    """
    m = LINE_ITEM_PATTERN.match(line)
    if not m:
        return None
    gap = line[m.end(1):m.start(2)]
    if re.search(r"\d[.,]\d{2}", gap) and not re.search(r"[A-Z]{1,2}\s*$", line):
        return None
    return m

# Item name alone on this line (no price, no code) — multi-line item formats.
# Allows:
#   pure-alpha words:          "GINSENG", "CLIF BAR PB"
#   alpha-start with digits:   "PEPPERONI3Z", "LAMP/STITCH"
#   digit-start WITH a letter: "500MG", "3Z"  (excludes pure barcodes like "001200010451")
#   CJK text:                  "干妙海鲜河粉", "豆奶仙草" (no spaces between characters)
#   dash separator/size descriptor: "Naughty Spare Rib - Full", "HH Asahi 1+1/2"
_NAME_ONLY = re.compile(
    rf"^([A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*"
    # A bare 1-4 digit token (no letters at all) is allowed as a continuation
    # word too — product names commonly end in a model/size number that
    # Vision sometimes splits off as its own token with no attached letter,
    # e.g. "ARTLINE 70" read as "AR TL IN E 70" or "A4 SIZE 20 POCKETS". The
    # line must still start with a letter (required by the first token
    # above), so this can't turn a genuine numbers-only barcode/price row
    # into a false "name" match.
    rf"(?:\s(?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*|[0-9]+[A-Za-z][A-Za-z0-9\-&'\/\(\)]*|\d{{1,4}}|{_LOOSE_WORD_SEP}))*)"
    r"\s*$",
    re.IGNORECASE,
)

# Two-line item: name + product-code on this line (no price at end), price on next line.
# Allows an optional trailing 1-2 letter tax code after the product code (e.g. "...F").
_NAME_THEN_CODE = re.compile(
    rf"^([A-Za-z{_CJK}][A-Za-z{_CJK}\-&'\/\(\)]*(?:\s[A-Za-z{_CJK}][A-Za-z{_CJK}\-&'\/\(\)]*){{0,4}})"
    r"\s+(?!\d+[.,]\d{2}\s*[A-Z]?\s*$)[A-Z0-9]{3,}\S*(?:\s+[A-Z]{1,2})?\s*$",
    re.IGNORECASE,
)

# Single-line item where the "name" is a bare barcode/UPC (price-override items that
# have no description on file): "44500982114  004450098211 F  3.98 Y"
BARCODE_NAME_ITEM_PATTERN = re.compile(
    rf"^(\d{{5,}})\s+.*?{_CURRENCY}(\d+[.,]\d{{2}})\s*\*?\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# Weight/quantity computation lines that precede the real line total, e.g.
# "1.75 lb @ 1 lb/0.54" or "4 AT 1 FOR 0.44" — the number at the end of these
# lines is a unit price, NOT the charged total, so they must not be mistaken
# for the item's price line during multi-line lookahead.
_QTY_CALC_LINE = re.compile(r"@|\bfor\b|\blb\b|\bkg\b|\boz\b", re.IGNORECASE)

# Name-only line whose trailing "@X.XX" is a per-unit RATE, not the charged
# total — e.g. "1/4 Chic+1sd-T @17.90" (the real total, e.g. 71.60 for a
# quantity of 4, is on a separate line further down). Menu abbreviations like
# "Chic+1sd-T" mix letters/digits/+ freely, so the continuation class here is
# deliberately looser than _NAME_ONLY's.
_NAME_WITH_RATE_SUFFIX = re.compile(
    rf"^((?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)+]*|\d+\/\d+)"
    rf"(?:[\s+][A-Za-z0-9{_CJK}\-&'\/\(\)+]*)*)"
    r"\s*@\s*\d+[.,]\d{2}\s*$",
    re.IGNORECASE,
)

# Same glued name style as above, but the real charged total follows the rate
# on the *same* line instead of a separate one — e.g. "1/4 Chic+1sd-T @17.90
# 71.60 S" (qty×rate already multiplied out into the trailing total). Without
# this, such a line matches neither Layout 1 (whose stricter name grammar
# can't parse "Chic+1sd-T"'s embedded "+") nor Layout 2 (whose lookahead
# expects the price on a following line) and the item is silently dropped.
_NAME_WITH_RATE_AND_PRICE = re.compile(
    rf"^((?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)+]*|\d+\/\d+)"
    rf"(?:[\s+][A-Za-z0-9{_CJK}\-&'\/\(\)+]*)*)"
    rf"\s*@\s*\d+[.,]\d{{2}}"
    rf"\s+.*?{_CURRENCY}(\d+[.,]\d{{2}})\s*\*?\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# Price at end of any line — used for multi-line item continuation lines
# Allows 0-2 letter tax codes after price: N, T, F (US) or SR, ZR, TX (Malaysian GST),
# and an optional "*" GST-applicability flag (with or without a preceding space —
# Vision is inconsistent about whether it glues the asterisk to the number).
_PRICE_AT_END = re.compile(
    rf"(\d{{1,6}}[.,]\d{{2}})\s*\*?\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# A line that is *nothing but* a price, e.g. "1.00 Y" — optionally with a
# 1-2 letter tax code stuck on either side with no space (OCR sometimes glues
# a tax-code letter directly to the number, e.g. "F3.98 Y"). Also tolerates a
# stray space next to the decimal point (e.g. "1 .70" for a printed "1.70") —
# the same Vision quirk already worked around in _extract_amount's total
# detection, here affecting a bare per-item price instead of the grand total.
_BARE_PRICE_LINE = re.compile(
    rf"^[A-Z]{{0,2}}\s*{_CURRENCY}(\d+\s?[.,]\s?\d{{2}})\s*\*?\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# A row of nothing but numbers — item#, qty, unit price, discount% — with the
# real charged amount as the LAST one, optionally marked with a trailing "*"
# (a common Malaysian tax-invoice GST-applicability marker) or short tax-code
# letters, e.g. "1  2  0.50  0.00  1.00*". The item's actual description sits
# on a following line instead of anywhere on this row (unlike every other
# layout, which expects the name somewhere on the price's own line or the
# reverse order) — this is the "no name at all" case, so only the price can
# be captured here; it's deferred the same way a bare price line is. One of
# the qty/rate/disc% columns is allowed to be a single stray letter instead
# of a digit (e.g. "9557369305006 f 3.96 4.09 3.80*") — Vision sometimes
# misreads a printed "1" quantity as "f"/"l"/"I" in this position; without
# tolerating it here, the whole row falls through to the bare-barcode-name
# pattern below and gets wrongly emitted as an item named after its own
# barcode instead of being deferred for the real name on the next line.
# The leading "item#" column is also allowed to be a short alphanumeric SKU
# code with a hyphen (e.g. "TP-24"), not just a plain digit barcode — without
# this, a row like "TP-24 5 1.32 0.00 6.60 *" fails to match at all, its price
# is never buffered, and the following name's forward lookahead then wrongly
# steals the *next* item's price instead. That code alternative requires at
# least one digit in it (unlike a plain barcode, which can be pure digits on
# its own) — without that requirement it would also match an ordinary
# name+price single-line item like "FRAP 001200010451 F 5.48 N", silently
# swallowing the real name "FRAP" as if it were a headerless numbers-row.
_ALL_NUMBERS_ROW = re.compile(
    r"^(?:\d+(?:[.,]\d+)?|[A-Za-z\-]{0,4}\d[A-Za-z0-9\-]{0,6})\s+"
    r"(?:(?:\d+(?:[.,]\d+)?|[A-Za-z])\s+){1,}(\d+[.,]\d{2})\s*\*?\s*[A-Z]{0,2}\s*$"
)

# A line with two bare 5+ digit barcodes and nothing else — a price-override
# item where Vision misread the product's own barcode as its "name" and split
# it from a second (real) barcode, e.g. "4450098211, 004450098211".
_BARE_BARCODE_NAME_LINE = re.compile(r"^(\d{5,}),?\s+\d{5,}\s*$")

# A long digit-run barcode (optionally with a 1-2 letter suffix, e.g. a
# weight-code) glued onto the end of an item name by Layout 2's name-only
# match, e.g. "BANANAS 000000004011KF" — carries no information useful to
# the user, so it's stripped before display.
_TRAILING_BARCODE = re.compile(r"\s+\d{6,}[A-Za-z]{0,2}$")

# Reaching this section means we're past the itemised list — any names still
# awaiting a price are unrecoverable and must not be paired with a totals figure.
_TOTALS_BOUNDARY = re.compile(
    r"\b(sub[\s\-]?total|total|(?:amount|amt)\s*due|balance\s*due)\b", re.IGNORECASE
)

# A genuine extra charge line (e.g. "Take away fee RM 0.50") that commonly
# prints AFTER the subtotal line that trips _TOTALS_BOUNDARY above — a real
# cost the user paid, not more totals-section noise, so it's captured as its
# own line item as a carve-out from the "past totals" skip.
_EXTRA_FEE_LINE = re.compile(
    rf"^((?:take[\s\-]?away|delivery|service|packaging|container|eco)\s*fee)\b"
    rf".*?{_CURRENCY}(\d+[.,]\d{{2}})\s*$",
    re.IGNORECASE,
)

# A tabular receipt's own column-header row (e.g. "QTY ITEM TOTAL") — contains
# both "qty" and "item"/"description" together, unlike a real end-of-items
# total line. Must be checked before _TOTALS_BOUNDARY, since such a header
# often also contains the word "total" as its price-column label and would
# otherwise be mistaken for the actual end-of-items boundary, cutting off
# every item that follows before it's ever parsed.
_ITEM_TABLE_HEADER = re.compile(
    r"(?=.*\bqty\b)(?=.*\b(?:item|description)\b)", re.IGNORECASE
)

# Lines containing these words are totals/summaries/headers/footers — not items
SKIP_KEYWORDS = re.compile(
    r"\b(total|subtotal|sub-total|tax|gst|sst|service\s*charge|discount|"
    r"change|cash|rounding|amount|amt|balance|tip|gratuity|receipt|invoice|"
    r"thank\s*you|welcome|visit|shop|store|tel|phone|fax|address|hotline|"
    r"website|www|http|member|loyalty|point|void|refund|exchange|"
    r"description|qty|quantity|item|price|sub\s*total|general\s*ex|sales\s*tax|"
    r"everything|on-line|online|follow\s*us|open|hour|manager|cashier|"
    r"associate|operator|server|bill|order|no\.|ref|reg|"
    r"visa|mastercard|master\s*card|amex|american\s*express|debit\s*card|"
    r"credit\s*card|approval\s*code|auth(?:orization)?\s*code|eftpos|"
    r"coleslaw|chargrill|grillveg"
    r"|(?<!\-)table)\b"
    # Register/terminal codes like "ST#", "TE#", "TR#", "OP#" always end in a
    # literal "#" — a trailing \b can never fire there (a non-word "#" followed
    # by a non-word space has no word/non-word transition to anchor on), so
    # these are matched separately without one.
    r"|\b(?:tr|op|st|te)#",
    re.IGNORECASE,
)

# Chinese-labelled equivalents of the same receipt structural terms — checked
# as plain substrings (not \b-bounded regex) because Chinese has no spaces
# between characters, so a word-boundary requirement would miss a label like
# "总计" sitting directly against other CJK text with no delimiter.
_CHINESE_SKIP_TERMS = (
    "总计", "合计", "小计", "现金", "找零", "找续", "找赎",
    "消费税", "服务税", "服务费", "税", "折扣", "优惠", "会员",
    "收据", "发票", "谢谢惠顾", "谢谢光临", "欢迎光临", "欢迎",
    "地址", "电话", "收银员", "销售员", "数量", "单价", "金额",
    "品名", "商品", "桌号", "台号", "应付", "实收", "积分",
)


# A combo/set-meal spice-level or size marker with no price of its own, e.g.
# "1/4-H" (quarter, hot), "1/2-M" (half, medium) — a fraction, a hyphen, then
# just 1-2 letters and nothing else on the line.
_COMBO_DESCRIPTOR = re.compile(r"^\d+/\d+-[A-Za-z]{1,2}$")

# The same letter repeated and nothing else, e.g. "SSS" — never a real product
# name; usually Vision's OCR garbling of a nearby label (here, "S=GST @6%:"
# from the tax-summary table) landing on its own line due to scrambled
# reading order.
_REPEATED_LETTER_NOISE = re.compile(r"^([A-Za-z])\1+$")


def _is_noise_line(line: str) -> bool:
    """True if this line is a structural/total/header line, not an item —
    checks the English keyword regex, Chinese-labelled equivalents, and
    known included-side/combo-descriptor patterns that never carry their own
    price (so they can't wrongly steal a nearby item's price)."""
    return (
        bool(SKIP_KEYWORDS.search(line))
        or any(term in line for term in _CHINESE_SKIP_TERMS)
        or bool(_COMBO_DESCRIPTOR.match(line))
        or bool(_REPEATED_LETTER_NOISE.match(line))
    )

# Masked account/card numbers, e.g. "xXxXxXxXxXxxxxxx4318" or "XXXX-XXXX-4318"
# or "************4318" — never an item, always a payment-method line.
_MASKED_ACCOUNT_NUMBER = re.compile(r"^[xX*][xX*\-\s]{3,}\d{2,6}$")


class OcrValidationError(Exception):
    """Raised when the uploaded file fails Stage 1 validation."""
    pass


class OcrExtractionError(Exception):
    """Raised when Vision API fails to extract usable text."""
    pass


# ─── Stage 1: Image Input and Validation ────────────────────────────────────
def validate_image(filename: str, file_size_bytes: int) -> None:
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise OcrValidationError(
            f"Unsupported file format '.{extension}'. Use PNG, JPG, JPEG, or PDF."
        )

    size_mb = file_size_bytes / (1024 * 1024)
    if size_mb > MAX_FILE_SIZE_MB:
        raise OcrValidationError(
            f"File too large ({size_mb:.1f}MB). Max allowed is {MAX_FILE_SIZE_MB}MB."
        )


# ─── PDF → image conversion (FR 4.2) ────────────────────────────────────────
def _pdf_to_image_bytes(pdf_bytes: bytes) -> bytes:
    # PyMuPDF ships its own PDF renderer as a pip wheel — no external Poppler
    # binary needed, unlike pdf2image (important since this runs on whatever
    # machine happens to host the Flask backend, not just the dev's own PC).
    import fitz
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    if doc.page_count == 0:
        raise OcrValidationError("Could not extract a page from the PDF.")
    page = doc.load_page(0)
    pix = page.get_pixmap(dpi=200)
    return pix.tobytes("png")


# Vision's own fullTextAnnotation.text groups words by *paragraph block*
# (e.g. every item name in one block, every price in a separate block to its
# right) rather than by visual row — so a tabular "QTY ITEM ... PRICE" receipt
# layout comes back with all names first, then all prices, instead of each
# row's name and price adjacent to each other the way a human reads it.
# Rebuilding the text from symbol-level bounding boxes — clustering by actual
# Y-position into rows, then sorting left-to-right within each row — recovers
# the natural reading order regardless of how Vision internally grouped its
# blocks.
#
# Whether to insert a space between two adjacent symbols in a row is decided
# by the actual horizontal *pixel gap* between them, not Vision's per-symbol
# detectedBreak flag — that flag turned out to be inconsistently present (real
# spaces between plainly separate words like "DELIVERY" and "CHG" often came
# back with no break marked at all), whereas the geometric gap between glued
# characters like "Chic" and "+" in "Chic+1sd-T" is reliably much smaller than
# the gap between genuinely separate words. Falls back to Vision's own text if
# a response has no symbol boxes.
def _reconstruct_reading_order(full_text_annotation: dict) -> str:
    # Operates on whole WORDS, not individual characters. An earlier
    # character-level version sorted every single symbol by Y-position across
    # the full page width before bucketing rows — on a wide, dense,
    # multi-column receipt (letterhead + a 5-column item table), even a
    # slight camera skew drifts Y-position enough across that width to make
    # the greedy row-bucketing interleave characters from different physical
    # lines, producing an unreadable single-character scramble. Words are far
    # fewer and narrower than characters, so the same skew has much less room
    # to drift a word's average Y off its true row — and Vision has already
    # solved the much harder "which characters belong to the same word"
    # problem for us, so there's no need to re-derive it from character gaps.
    words = []  # (y_center, x_left, x_right, height, text)
    for page in full_text_annotation.get("pages", []):
        for block in page.get("blocks", []):
            for paragraph in block.get("paragraphs", []):
                for word in paragraph.get("words", []):
                    vertices = word.get("boundingBox", {}).get("vertices", [])
                    if len(vertices) < 4:
                        continue
                    text = "".join(s.get("text", "") for s in word.get("symbols", []))
                    if not text:
                        continue
                    ys = [v.get("y", 0) for v in vertices]
                    xs = [v.get("x", 0) for v in vertices]
                    words.append((
                        sum(ys) / len(ys), min(xs), max(xs),
                        max(ys) - min(ys) or 1, text,
                    ))

    if not words:
        return ""

    words.sort(key=lambda w: w[0])  # top to bottom by vertical center

    rows: list[list[tuple]] = []
    for w in words:
        if rows:
            row_y = sum(r[0] for r in rows[-1]) / len(rows[-1])
            row_h = sum(r[3] for r in rows[-1]) / len(rows[-1])
            if abs(w[0] - row_y) <= row_h * 0.6:
                rows[-1].append(w)
                continue
        rows.append([w])

    lines = []
    for row in rows:
        row.sort(key=lambda w: w[1])  # left to right
        # Every entry here is already a distinct word per Vision's own
        # segmentation, so — unlike the old character-level gap heuristic —
        # a single space always belongs between consecutive words.
        lines.append(" ".join(w[4] for w in row))
    return "\n".join(lines)


# ─── Stage 2: Text Extraction via Google Cloud Vision API ───────────────────
def extract_text(image_bytes: bytes) -> str:
    if not GOOGLE_VISION_API_KEY:
        raise OcrExtractionError(
            "GOOGLE_VISION_API_KEY is not set. Add it to backend/.env"
        )

    image_b64 = base64.b64encode(image_bytes).decode()
    payload = json.dumps({
        "requests": [{
            "image": {"content": image_b64},
            "features": [{"type": "DOCUMENT_TEXT_DETECTION"}]
        }]
    }).encode()

    url = f"https://vision.googleapis.com/v1/images:annotate?key={GOOGLE_VISION_API_KEY}"
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise OcrExtractionError(f"Google Vision API error {e.code}: {body}")

    full_text_annotation = result["responses"][0].get("fullTextAnnotation", {})
    text = _reconstruct_reading_order(full_text_annotation)
    if not text or not text.strip():
        # No word-box data in this response for some reason — fall back to
        # Vision's own best-guess ordering rather than failing outright.
        text = full_text_annotation.get("text", "")
    if not text or not text.strip():
        raise OcrExtractionError(
            "No text detected — image may be too blurry, faded, or crumpled. "
            "Please retake the photo."
        )

    # Strip angle-bracket markers (e.g. <i>, <b>) that receipt printers embed
    text = re.sub(r"<[^>]{1,10}>", "", text)

    print("\n===== GOOGLE VISION RAW TEXT =====")
    print(text)
    print("==================================\n")

    return text


# ─── Stage 3: Post-Processing and Data Structure ────────────────────────────
def parse_receipt_fields(raw_text: str) -> dict:
    lines = [line.strip() for line in raw_text.splitlines() if line.strip()]

    amount = _extract_amount(raw_text)
    receipt_date = _extract_date(raw_text)
    vendor_name = _extract_vendor(lines)
    line_items = _extract_line_items(raw_text)  # FR 4.6
    print("===== EXTRACTED ITEMS =====")
    for it in line_items:
        print(f"  x{it['quantity']}  {it['item_name']}  →  {it['price']}")
    print("===========================\n")

    return {
        "vendor_name": vendor_name,
        "amount": amount,
        "date": receipt_date.isoformat() if receipt_date else None,
        "line_items": line_items,
        "_date_obj": receipt_date,
    }


def _extract_amount(raw_text: str) -> float | None:
    """
    FR 4.10: Extract the receipt grand total.
    Scans bottom-up so the grand total line (always near the end of the
    receipt) is found before any 'TOTAL' column header in the items table.
    Strategy 1: last 'Total / Amount Due' line that carries an amount on
                 the same line or within the next 2 lines.
    Strategy 2: fallback to the largest amount in the receipt.
    """
    lines = [ln.strip() for ln in raw_text.splitlines()]

    _TOTAL_LINE = re.compile(
        r"^(total|amount\s*due|balance\s*due|rounded?\s*total"
        r"|总计|合计|总额|应付)",
        re.IGNORECASE,
    )
    _TOTAL_EXCLUDE = re.compile(
        r"\b(subtotal|sub[\s\-]total|cash|change|tax|gst|sst|qty|items?\s*sold|payable|savings?)\b"
        r"|小计|现金|找零|找续|找赎|消费税|服务税|数量",
        re.IGNORECASE,
    )

    _ROUNDING = re.compile(r"\brounding\b|抹零|四舍五入", re.IGNORECASE)

    # Malaysian GST/SST tax invoices commonly print a breakdown table after
    # the real grand total (e.g. "GST SUMMARY" / tax code / amount / tax
    # columns), which has its own "TOTAL" row for that table's own amount+tax
    # subtotal — a *different* number from the receipt's actual total. Since
    # this table sits nearer the bottom, scanning bottom-up would otherwise
    # reach it before the real total and return the wrong figure. Skip the
    # entire section once its heading is seen.
    _TAX_BREAKDOWN_HEADER = re.compile(r"\b(?:gst|tax)\s*summary\b", re.IGNORECASE)
    tax_breakdown_idx = next(
        (i for i, ln in enumerate(lines) if _TAX_BREAKDOWN_HEADER.search(ln)), None
    )

    # Vision sometimes introduces a stray space between the decimal point and
    # the cents digits (e.g. "TOTAL 5. 11" for a printed "5.11") — tolerate it
    # here specifically rather than loosening the shared AMOUNT_PATTERN used
    # elsewhere, since that would risk false positives in line-item parsing.
    _AMOUNT_LOOSE = re.compile(rf"{_CURRENCY}(\d+[.,]\s?\d{{2}})", re.IGNORECASE)

    # Some receipts' real total line gets so badly OCR-mangled (e.g. a
    # multi-column letterhead/footer layout that interleaves unrelated text)
    # that the "total"/"amount" label no longer sits at the start of its own
    # line — e.g. a wrapped "TOTAL AMOUNT 539.00" surviving only as
    # "...AL AMOUNT 539.00" glued onto an unrelated card-swipe reference
    # number. Track the first such mid-line match as a middle-tier fallback,
    # since it's still far more reliable than blindly taking the largest
    # number anywhere in the receipt (which can pick up a reference number,
    # phone number, or invoice ID with a decimal accidentally glued to it).
    _TOTAL_KEYWORD_ANYWHERE = re.compile(r"\b(total|amount)\b", re.IGNORECASE)
    midline_amount = None

    # Scan from bottom upward — grand total is near the end; column-header
    # "TOTAL" is near the top and will only be reached if no real total found.
    for i in range(len(lines) - 1, -1, -1):
        if tax_breakdown_idx is not None and i >= tax_breakdown_idx:
            continue
        line = lines[i]
        if _TOTAL_LINE.match(line) and not _TOTAL_EXCLUDE.search(line):
            check_lines = [line] + lines[i + 1: i + 4]
            # If a rounding-adjustment line follows, the real total comes after it
            rounding_pos = next(
                (k for k, c in enumerate(check_lines) if _ROUNDING.search(c)), None
            )
            if rounding_pos is not None:
                for check in check_lines[rounding_pos + 1:]:
                    if _TOTAL_EXCLUDE.search(check):
                        continue
                    m = _AMOUNT_LOOSE.search(check)
                    if m:
                        return float(m.group(1).replace(" ", "").replace(",", "."))
            # No rounding: take first amount on total line or next 2 lines —
            # re-checking _TOTAL_EXCLUDE on each is what stops a "CASH TEND
            # 11.00" or "CHANGE DUE 5.89" line (checked only as a fallback
            # when the total line's own amount fails to parse) from being
            # mistaken for the grand total.
            for check in check_lines[:3]:
                if _TOTAL_EXCLUDE.search(check):
                    continue
                m = _AMOUNT_LOOSE.search(check)
                if m:
                    return float(m.group(1).replace(" ", "").replace(",", "."))

        if midline_amount is None:
            # Check each total/amount occurrence on this line in turn, rather
            # than excluding the whole line if it contains "tax"/"payable"
            # ANYWHERE — reconstruction can merge unrelated content onto the
            # same physical line (e.g. an early "Tax Details" label sharing a
            # line with the real "...TOTAL AMOUNT 539.00" much further along,
            # or a card-swipe reference sharing a line with an unrelated
            # "Total ST Payable 0.00"). A whole-line check would wrongly
            # block the first case and wrongly allow the second; checking a
            # window right around each specific match keeps both correct.
            for kw in _TOTAL_KEYWORD_ANYWHERE.finditer(line):
                m = _AMOUNT_LOOSE.search(line[kw.end():])
                if not m:
                    continue
                window = line[max(0, kw.start() - 20):kw.end() + m.end()]
                if _TOTAL_EXCLUDE.search(window):
                    continue
                midline_amount = float(m.group(1).replace(" ", "").replace(",", "."))
                break

    if midline_amount is not None:
        return midline_amount

    # Fallback: largest amount in the receipt
    matches = AMOUNT_PATTERN.findall(raw_text)
    return max(float(m.replace(",", ".")) for m in matches) if matches else None


def _extract_date(raw_text: str) -> date | None:
    for pattern in DATE_PATTERNS:
        match = re.search(pattern, raw_text)
        if match:
            date_str = match.group(1)
            for fmt in ("%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d-%m-%y",
                        "%Y/%m/%d", "%Y-%m-%d", "%m/%d/%y", "%m/%d/%Y",
                        "%Y.%m.%d"):
                try:
                    return datetime.strptime(date_str, fmt).date()
                except ValueError:
                    continue

    # Month-name dates (e.g. "Mar 30,2026") are matched and parsed separately
    # from strptime — month/day/year are captured as distinct groups by
    # _MONTH_NAME_DATE, so there's no single literal format string that could
    # tolerate Vision's inconsistent spacing (see comment above that pattern).
    match = _MONTH_NAME_DATE.search(raw_text)
    if match:
        month_key = re.sub(r"\s+", "", match.group(1)).lower()[:3]
        month_num = _MONTH_TO_NUM.get(month_key)
        if month_num:
            try:
                return date(int(match.group(3)), month_num, int(match.group(2)))
            except ValueError:
                pass

    return None



# Each word must start with a capital letter (or a CJK character, which has no
# case) — genuine stylised brand names are capitalised ("Walmart", "Nando's",
# "McDonald's"), whereas plain lowercase filler sentences that happen to be
# short ("formerly known as", "thank you") are not, and must never be mistaken
# for one.
_VENDOR_WORD_LINE = re.compile(
    rf"^[A-Z{_CJK}][A-Za-z{_CJK}'&\-]*(\s[A-Z{_CJK}][A-Za-z{_CJK}'&\-]*){{0,2}}$"
)

# Order-type labels ("Takeaway", "Dine In", "Delivery") are short,
# capitalised, single-to-two-word lines — they satisfy _VENDOR_WORD_LINE's
# shape exactly as well as a genuine short brand name does, and would
# otherwise win over the real (often longer) vendor name printed elsewhere
# on the receipt.
_ORDER_TYPE_LABEL = re.compile(
    r"^(?:take[\s\-]?away|dine[\s\-]?in|eat[\s\-]?in|delivery|"
    r"drive[\s\-]?(?:thru|through))$",
    re.IGNORECASE,
)


_BHD_LINE = re.compile(r"\bbhd\b|\bberhad\b", re.IGNORECASE)

# Malaysian tax invoices for franchised outlets are required to print the
# holding company's registered name (e.g. "Gerbang Alaf Restaurants Sdn Bhd")
# alongside a disclosure of the actual consumer-facing brand it trades as
# ("Licensee of McDonald's", "trading as X") — the disclosed brand is what a
# customer actually recognises and should win over the legal entity name.
_BRAND_DISCLOSURE = re.compile(
    r"(?:licensee of|trading as|t/a)\s+(.+)", re.IGNORECASE
)


def _extract_vendor(lines: list[str]) -> str | None:
    """
    Heuristic: first checks for a "Licensee of X" / "trading as X" brand
    disclosure line (common on Malaysian franchise tax invoices), since that
    names the actual consumer-facing brand rather than the legal entity.
    Otherwise prefers ALL CAPS lines in the first 5 lines (store names are
    usually all-caps). Falls back to a short mixed-case word/phrase line
    (e.g. a stylised logo like "Walmart") in the first 8 lines, then to the
    first non-digit line. Lines with '#'/':'/'*' (IDs, transaction numbers,
    "*** COPY ***"-style stamps) or known non-vendor keywords are excluded.

    Before any of that: if a "Sdn Bhd"/"Berhad" registered-company line
    appears nearby, prefer the *earliest* short candidate line whose text
    also appears inside that region — e.g. "Nando's" repeats inside "Nando's
    Chickenland Malaysia Sdn Bhd", so it wins over an unrelated ALL-CAPS
    tagline like "PERI-PERI CHICKEN" printed directly below the logo that
    would otherwise satisfy the plain ALL-CAPS check first.
    """
    for line in lines[:15]:
        m = _BRAND_DISCLOSURE.search(line)
        if m:
            candidate = m.group(1).strip().rstrip(".,")
            if candidate and not _is_noise_line(candidate):
                return candidate

    window = lines[:10]
    if any(_BHD_LINE.search(ln) for ln in window):
        for idx, line in enumerate(lines[:5]):
            stripped = line.strip()
            if (any(c in stripped for c in "#:*")
                    or len(stripped) <= 3
                    or _is_noise_line(stripped)):
                continue
            # A line that itself names the registered company ("X Sdn Bhd")
            # is strong enough evidence on its own — a nearby legally-
            # required registration number on the same line (e.g. "(541512-
            # U)") must not disqualify it via the digit-run check below,
            # which exists to filter out unrelated ID/phone-number lines
            # instead. Without this, that disqualification let a short
            # digit-free address fragment ("Selangor U13, Shah Alam") win by
            # default through a looser fallback further down.
            if _BHD_LINE.search(stripped):
                # A company name never legitimately starts with a lowercase
                # word — that's always a stray fragment of unrelated text
                # (e.g. an address block wrapping into the same reconstructed
                # line as "TMT Lot L1-012 ... Technology Sdn Bhd", leaving a
                # leading "ent " left over from "ment" elsewhere). Trim any
                # such leading run before returning.
                words = stripped.split()
                while len(words) > 1 and words[0][:1].islower():
                    words.pop(0)
                return " ".join(words)
            if re.search(r"\d{3,}", stripped):
                continue
            normalised = stripped.lower()
            rest = " ".join(window[:idx] + window[idx + 1:]).lower()
            if normalised in rest:
                return stripped

    for line in lines[:5]:
        if (not re.search(r"\d{3,}", line)
                and not any(c in line for c in "#:*")
                and line == line.upper()
                and len(line.strip()) > 3
                and not _is_noise_line(line)):
            return line
    for line in lines[:8]:
        stripped = line.strip()
        if (_VENDOR_WORD_LINE.match(stripped)
                and not _is_noise_line(stripped)
                and not _ORDER_TYPE_LABEL.match(stripped)):
            return stripped
    for line in lines[:3]:
        stripped = line.strip()
        # Same minimum length as every other candidate check above — without
        # it, a stray single-character OCR artifact (e.g. a lone "0" picked
        # up near the letterhead) can win this last-resort fallback outright.
        if (not re.search(r"\d{3,}", stripped)
                and not any(c in stripped for c in "#:*")
                and len(stripped) > 3):
            return stripped
    return lines[0] if lines else None


def _extract_line_items(raw_text: str) -> list[dict]:
    """
    FR 4.6: Extracts individual line items (item name + price) from receipt text.
    Handles four layouts produced by Google Vision:
      1. Single-line: "ITEM [optional code]  PRICE [optional tax flag]"
      1b. Bare-barcode name: "44500982114  004450098211 F  3.98 Y" (price-override
          items with no description on file — the barcode itself is the "name")
      2. Name-only:   "ITEM" alone, then price appears within 4 lines
                      (Walmart weighted items: BANANAS → barcode → weight → price)
      3. Two-line:    "ITEM   PRODUCTCODE" on one line, price on the next
      4. Deferred name→price:  when a name can't find its price nearby (Vision's
                      reading order can scatter a whole cluster of names away
                      from their prices — e.g. a hand-drawn mark on the receipt
                      confusing the block order), the name is queued and paired
                      FIFO with the next unclaimed bare-price line found later.
      5. Deferred price→name:  some invoice layouts print the code/qty/price/
                      amount row *before* the item's own description line
                      (e.g. Malaysian tax invoices). An unclaimed bare price is
                      buffered and paired FIFO with the next name that can't
                      find its price forward.
    """
    items = []
    pending_names: list[str] = []
    pending_prices: list[float] = []
    past_totals = False
    # Set once the table's own "QTY ITEM ... TOTAL" column-header row is seen —
    # a stronger, earlier signal that we're inside the itemised list than
    # waiting for the first item to already have been emitted (which never
    # happens if that very first item has a leading quantity digit needing to
    # be stripped first — a chicken-and-egg deadlock without this flag).
    seen_header = False
    # A bare 1-3 digit line just before an item's name (e.g. Nando's printing
    # "4" on its own line above "1/4 Chic+1sd-T") is that item's quantity —
    # captured here and consumed by whichever item is emitted next.
    pending_qty: int | None = None
    # A name-only line whose own forward lookahead broke on ANOTHER bare name
    # immediately after it (e.g. "Tom Yum" then "XL White Fish Ball", both
    # wrapping across two physical lines to describe ONE item, before its
    # qty/price row appears) — that second name gets its own shot at Layout 2
    # first, so this holds the first fragment in reserve. If what eventually
    # gets priced next turns out to be a bare quantity word ("each"/"ea"/
    # "unit") rather than a real name, this fragment is prepended to it,
    # since a quantity word alone is never the actual item description.
    pending_wrapped_name: str | None = None
    _QTY_WORD_ONLY = re.compile(r"^(?:each|ea|unit|units|pcs|pc)$", re.IGNORECASE)

    def _emit(name: str, price: float, line_qty: int | None = None) -> None:
        nonlocal pending_qty, pending_wrapped_name
        if pending_wrapped_name and _QTY_WORD_ONLY.match(name):
            # The quantity word itself ("each"/"ea"/"unit") carries no real
            # description — replace it outright with the accumulated name.
            name = pending_wrapped_name
        pending_wrapped_name = None
        # A quantity glued to this exact line (line_qty) always wins over an
        # older standalone pending_qty from a prior line — see the qty-prefix
        # stripping comment below for why the fresher one takes precedence.
        qty = line_qty if line_qty is not None else (
            pending_qty if pending_qty is not None else 1
        )
        pending_qty = None
        items.append({"item_name": name, "price": price, "quantity": qty})

    # Strip printer formatting tags (e.g. <i>, <b>) that Google Vision reads literally
    _TAG = re.compile(r"<[^>]*>")
    # On some Malaysian tax-invoice layouts, the item table's own column
    # headers ("QTY Tax Code", "U. PRICE DISC (%) AMOUNT") end up reconstructed
    # onto the SAME line as a wrapped item description instead of their own
    # standalone header row (a long description spans more physical lines
    # than the numeric columns beside it, so the header ends up Y-aligned
    # with the description's middle rather than its top). These are
    # unambiguous multi-word column labels that never legitimately appear
    # inside real item text, so strip them out before layout matching rather
    # than let them derail name/price pairing.
    _EMBEDDED_HEADER_FRAGMENTS = re.compile(
        r"\bQTY\s+Tax\s*Code\b|\bU\.?\s*PRICE\s+DISC\s*\(\s*%\s*\)\s*(?:AMOUNT\b)?",
        re.IGNORECASE,
    )
    lines = [
        re.sub(r"\s{2,}", " ", _EMBEDDED_HEADER_FRAGMENTS.sub(" ", _TAG.sub("", ln))).rstrip()
        for ln in raw_text.splitlines()
    ]
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if past_totals:
            # Once we've crossed Sub Total/Total, nothing after it is ever a
            # purchasable item — GST breakdown tables, marketing surveys, and
            # footer notes must never be matched, not just excluded from
            # pending-queue bookkeeping (which only stops *new* deferrals).
            # Exception: a genuine extra charge (takeaway/delivery/service
            # fee) commonly prints AFTER a "Total Sales (Exc. Tax)" subtotal
            # line — which itself trips this same boundary — but is still a
            # real cost the user paid, not more totals-section noise, so it
            # must still be captured as its own line item.
            fee_match = _EXTRA_FEE_LINE.match(line)
            if fee_match:
                fee_price = float(fee_match.group(2).replace(",", "."))
                if fee_price > 0:
                    _emit(fee_match.group(1).strip(), fee_price)
            i += 1
            continue
        if not line or _is_noise_line(line) or _MASKED_ACCOUNT_NUMBER.match(line):
            if line and _ITEM_TABLE_HEADER.search(line):
                # Anything queued before the item table itself started (e.g. a
                # letterhead/address line that coincidentally parsed as a
                # "name" while scanning through the receipt's header block)
                # is guaranteed to be pre-item-table noise, never a real
                # item — left uncleared, it would sit in the queue and get
                # wrongly claimed by the first genuine bare price line inside
                # the table.
                pending_names.clear()
                pending_prices.clear()
                pending_qty = None
                pending_wrapped_name = None
                seen_header = True
            elif line and _TOTALS_BOUNDARY.search(line):
                # Past the itemised list now — any names/prices still waiting
                # are unrecoverable; don't let them pair with a totals figure.
                pending_names.clear()
                pending_prices.clear()
                pending_qty = None
                pending_wrapped_name = None
                past_totals = True
            i += 1
            continue

        # A quantity Vision sometimes glues directly onto the same line as the
        # name instead of printing it on its own line above (e.g. Nando's
        # "3 1/4 Chic+1sd-T @17.90" vs. the usual "3" / "1/4 Chic+1sd-T @17.90"
        # split across two lines) — peel it off so the name underneath is
        # still recognisable by the layouts below. Kept in a line-scoped
        # `line_qty` rather than written into the persisting `pending_qty`:
        # this line's own number belongs only to whatever gets emitted from
        # *this* line, and must never leak forward onto some later, unrelated
        # item if this candidate doesn't pan out — e.g. a store address line
        # like "951 Avenida Pico" would otherwise attach quantity 951 to
        # whatever real item is emitted next. Not gated on items already
        # having been emitted — a receipt whose very first item line has a
        # leading quantity digit (e.g. "2 M SpicyDeluxe") would otherwise
        # never strip it, never match any layout, and so never emit that
        # first item, permanently keeping this gate closed. Header lines with
        # a leading number (e.g. "4 NANDOS3 76 SYAFIQ 2") are already safe
        # without this gate: stripping "4 " just leaves "NANDOS3 76 SYAFIQ 2",
        # which still fails every layout's name pattern (a bare "76" token
        # breaks the name-continuation rules), so nothing false gets emitted.
        qty_prefix = re.match(r"^(\d{1,3})\s+([A-Za-z\d].*)$", line)
        line_qty = int(qty_prefix.group(1)) if qty_prefix else None
        if qty_prefix:
            line = qty_prefix.group(2)

        # A leading "-"/"•" bullet, "*" add-on marker (Chinese receipts prefix
        # a modifier line like "* 加鸡蛋" this way), or "N." menu-numbering
        # prefix (e.g. "1.冬菇肉碎老鼠粉（小）") on an item-description line —
        # stripped so the name-matching layouts below, which all require a
        # letter or CJK character as the actual first character, can
        # recognise it. A space is tolerated between the digit and the period
        # (Vision sometimes prints "1 ." instead of "1." when the CJK text
        # immediately after it needs its own spacing).
        bullet_prefix = re.match(
            rf"^(?:[-•*]|\d{{1,2}}\s*\.)\s*([A-Za-z{_CJK}].*)$", line
        )
        if bullet_prefix:
            line = bullet_prefix.group(1)

        # A nameless "item#/qty/rate/disc%/amount" row (see _ALL_NUMBERS_ROW) —
        # the description is always on the very next line for this layout, so
        # buffer the price for it specifically rather than handing it to
        # pending_names' oldest entry — that queue can already hold unrelated
        # stray candidates (e.g. an address line that broke its own lookahead
        # on a noise line before ever reaching here), and this row's price
        # belongs to the item immediately following it, not to whichever name
        # happened to be queued first.
        an = _ALL_NUMBERS_ROW.match(line)
        if an:
            price = float(an.group(1).replace(",", "."))
            if price > 0 and not past_totals:
                pending_prices.append(price)
            i += 1
            continue

        # Layout 1a: name+rate+realprice all on one line (e.g. "1/4 Chic+1sd-T
        # @17.90 71.60 S") — checked before the rate-marker exclusion below,
        # since this *is* the real charged total, just sharing a line with the
        # per-unit rate rather than sitting on a separate one.
        rm = _NAME_WITH_RATE_AND_PRICE.match(line)
        if rm:
            name = rm.group(1).strip()
            price = float(rm.group(2).replace(",", "."))
            if name and price > 0 and 3 <= len(name) <= 40:
                _emit(name, price, line_qty)
            i += 1
            continue

        # Layout 1: single-line match. Skipped for lines carrying a rate marker
        # (@, lb, kg, for) — regex backtracking would otherwise shrink the name
        # capture down to just the token before the marker and mistake the
        # per-unit rate for the real charged total (e.g. "1/4 Chic+1sd-T
        # @17.90" → wrongly "1/4"/17.90 instead of "1/4 Chic+1sd-T"/71.60 from
        # the next line). Such lines fall through to Layout 2's lookahead.
        m = None if _QTY_CALC_LINE.search(line) else _match_line_item(line)
        if m:
            name = m.group(1).strip()
            price = float(m.group(2).replace(",", "."))
            # Minimum length 3 rejects bare 1-2 letter GST rate codes (SR, ZR,
            # TX) that Malaysia prints directly before the amount, e.g.
            # "SR 106.90" — without this, "SR" itself gets treated as an item.
            if name and price > 0 and 3 <= len(name) <= 40:
                _emit(name, price, line_qty)
            i += 1
            continue

        # Layout 1b: bare-barcode "name" (price-override item with no description)
        bm = BARCODE_NAME_ITEM_PATTERN.match(line)
        if bm:
            name = bm.group(1).strip()
            price = float(bm.group(2).replace(",", "."))
            if price > 0:
                _emit(name, price, line_qty)
            i += 1
            continue

        # Layout 2: item name alone on this line, look ahead up to 4 lines for price.
        # Also matches a name ending in "@X.XX" (a per-unit rate, e.g. a menu
        # portion price) — the real charged total is the price being looked
        # ahead for, not the rate itself.
        no = _NAME_ONLY.match(line) or _NAME_WITH_RATE_SUFFIX.match(line)
        if no:
            name = _TRAILING_BARCODE.sub("", no.group(1).strip())
            if 3 <= len(name) <= 40:
                # An already-buffered bare price (inverted "numbers-row-then-
                # name" layout, e.g. Malaysian tax invoices printing the
                # code/qty/price row before the item's own description) was
                # deferred specifically for whichever name comes next — claim
                # it immediately rather than risk the forward lookahead below
                # finding a *different*, later item's price first and stealing
                # it before this name ever gets its rightful match.
                if pending_prices:
                    price = pending_prices.pop(0)
                    full_name = name
                    consumed = 1
                    if i + 1 < len(lines):
                        cont = lines[i + 1].strip()
                        # A plain continuation line — no bullet marker, no
                        # leading digits — right after a just-claimed name is
                        # this same item's description wrapping onto a second
                        # physical line (e.g. "-CBEA4SIZE 20 POCKETS
                        # REFILLABLENEW" / "CLEAR HOLDER"), not a new item:
                        # every genuine item's own description in this
                        # "numbers-row-then-name" layout is bullet-prefixed,
                        # so its absence is the tell. Left unstitched, the
                        # orphaned fragment would itself match as a "name"
                        # next and steal whatever price/lookahead comes after.
                        if (cont and not re.match(r"^[-•\d]", cont)
                                and _NAME_ONLY.match(cont)):
                            full_name = f"{full_name} {cont}"
                            consumed = 2
                    _emit(full_name, price, line_qty)
                    i += consumed
                    continue
                price_found = False
                broke_on_name = False
                for j in range(i + 1, min(i + 5, len(lines))):
                    ahead = lines[j].strip()
                    if not ahead:
                        continue
                    if _is_noise_line(ahead):
                        break
                    # Stop if we hit another standalone item name (next item
                    # started) — same 3-char minimum as everywhere else, so a
                    # bare 1-2 letter GST code (e.g. "SR" on its own line, its
                    # price on the next) isn't mistaken for a new item name.
                    ahead_name = _NAME_ONLY.match(ahead) or _NAME_WITH_RATE_SUFFIX.match(ahead)
                    if ahead_name and len(ahead_name.group(1)) >= 3:
                        broke_on_name = True
                        break
                    # Stop if this line is actually a *different* item's own
                    # complete "qty + name + price" row (e.g. "1 M GrilChicBgr
                    # 12.50") rather than a bare price continuation for the
                    # pending name — otherwise that item's price gets stolen
                    # here and the item itself is skipped over entirely when
                    # the outer loop reaches it. Strip a possible leading qty
                    # digit first, the same way the outer loop does. Same
                    # 3-char minimum as every other name-emission check in
                    # this file — LINE_ITEM_PATTERN's non-greedy middle
                    # wildcard will happily match straight through a messy
                    # continuation line (e.g. a serial-number line like
                    # "SN # : S5GXNU0WC15502 ... SR 499.00") and capture just
                    # "SN" as a "name", wrongly treating the pending item's
                    # own price line as if a whole new item had started and
                    # dropping the pending item entirely.
                    ahead_unqtied = re.sub(r"^\d{1,3}\s+", "", ahead)
                    ahead_item_match = _match_line_item(ahead_unqtied)
                    if (not _QTY_CALC_LINE.search(ahead_unqtied)
                            and ahead_item_match
                            and len(ahead_item_match.group(1).strip()) >= 3):
                        broke_on_name = True
                        break
                    # Weight/quantity lines (e.g. "1.75 lb @ 1 lb/0.54") carry a
                    # unit price, not the charged total — keep looking past them.
                    # But some formats (e.g. Walmart's "0.41 lb @ 1 lb /0.49
                    # 0.20 N") print the real charged total on this SAME line,
                    # right after the rate. Three decimal numbers on one line
                    # (weight, rate, total) rather than the usual two (weight,
                    # rate alone with the total on a separate later line) is
                    # normally the tell — grab the trailing one in that case
                    # instead of skipping past the item's only chance at a
                    # price. A bare-integer quantity (e.g. "2 pc @ 2.50 5.00
                    # GO" — qty=2, rate=2.50, total=5.00, only 2 of those 3
                    # are decimal-formatted) won't clear that 3-decimal bar,
                    # so a trailing tax-code letter right after the last
                    # number is accepted as an equally strong "this row is a
                    # complete, closed-out charge" signal on its own — a
                    # genuine rate-only line (no total baked in) never has
                    # one, ending right after the bare rate instead.
                    if _QTY_CALC_LINE.search(ahead):
                        decimals_found = len(re.findall(r"\d+[.,]\d{2}", ahead))
                        has_trailing_code = bool(
                            re.search(r"\d[.,]\d{2}\s*\*?\s*[A-Z]{1,2}\s*$", ahead)
                        )
                        if decimals_found >= 3 or (
                            decimals_found == 2 and has_trailing_code
                        ):
                            pm = _PRICE_AT_END.search(ahead)
                            if pm:
                                price = float(pm.group(1).replace(",", "."))
                                if price > 0:
                                    ahead_qty = re.match(r"^(\d{1,3})\s+", ahead)
                                    emit_qty = line_qty if line_qty is not None else (
                                        int(ahead_qty.group(1)) if ahead_qty else None
                                    )
                                    _emit(name, price, emit_qty)
                                    i = j + 1
                                    price_found = True
                                    break
                        continue
                    pm = _PRICE_AT_END.search(ahead)
                    if pm:
                        price = float(pm.group(1).replace(",", "."))
                        if price > 0:
                            _emit(name, price, line_qty)
                            i = j + 1
                            price_found = True
                            break
                        # price == 0.00 is a discount/empty column — keep looking
                if not price_found:
                    # If another item's name started before we found a price,
                    # this candidate never had its own charge (an included
                    # side/sub-item, or a leftover word-wrap fragment) — drop
                    # it rather than defer, so it can't steal a later unrelated
                    # item's price via the FIFO pending queue. Only a genuinely
                    # exhausted lookahead (Vision's reading order scattering a
                    # real price further away) defers.
                    if not broke_on_name:
                        if pending_prices:
                            # An earlier unclaimed bare price (inverted layout) claims it.
                            _emit(name, pending_prices.pop(0), line_qty)
                        else:
                            # Price wasn't nearby — defer and keep scanning forward for it.
                            pending_names.append(name)
                    else:
                        # Dropped because what looked like a different item's
                        # name/price row came next — but this is often really
                        # the SAME item's name wrapping across several
                        # physical lines (e.g. "Tom Yum" then "XL White Fish
                        # Ball", with the combined item's qty/price only
                        # appearing after both fragments). Keep accumulating;
                        # _emit() below uses this in place of a bare quantity
                        # word ("each"/"ea"/"unit") that carries no real name
                        # of its own, and clears it after every emit either
                        # way so it can never leak into an unrelated item.
                        pending_wrapped_name = (
                            f"{pending_wrapped_name} {name}"
                            if pending_wrapped_name else name
                        )
                    i += 1
            else:
                i += 1
            continue

        # Layout 3: name + product-code on this line, price on the next
        nm = _NAME_THEN_CODE.match(line)
        if nm:
            name = nm.group(1).strip()
            next_line = lines[i + 1].strip() if i + 1 < len(lines) else ""
            pm = (
                _PRICE_AT_END.search(next_line)
                if next_line and not _is_noise_line(next_line)
                else None
            )
            if pm:
                price = float(pm.group(1).replace(",", "."))
                if name and price > 0 and 3 <= len(name) <= 40:
                    _emit(name, price, line_qty)
                i += 2
                continue
            if name and 3 <= len(name) <= 40:
                if pending_prices:
                    _emit(name, pending_prices.pop(0), line_qty)
                    i += 1
                    continue
                pending_names.append(name)
                i += 1
                continue

        # Layout 4a: bare barcode pair with no price (misread price-override item)
        bn = _BARE_BARCODE_NAME_LINE.match(line)
        if bn:
            pending_names.append(bn.group(1))
            i += 1
            continue

        # Layout 4b: a bare price line pairs with the oldest name still waiting,
        # or — if no name is waiting yet — gets buffered for one that hasn't
        # appeared yet (inverted layouts print the price before the name).
        bp = _BARE_PRICE_LINE.match(line)
        if bp:
            price = float(bp.group(1).replace(",", ".").replace(" ", ""))
            if price > 0:
                if pending_names:
                    _emit(pending_names.pop(0), price)
                elif not past_totals:
                    pending_prices.append(price)
            i += 1
            continue

        # A bare 1-3 digit line (not a barcode, not a price — those are already
        # handled above) is this item's quantity, printed on its own line just
        # above the name, e.g. Nando's "4" above "1/4 Chic+1sd-T @17.90".
        if re.match(r"^\d{1,3}$", line):
            pending_qty = int(line)
            i += 1
            continue

        i += 1

    # Consolidate duplicate items — e.g. the same dish rung up as separate
    # order lines for different spice levels/sides (Nando's "1/4 Chic+1sd-T"
    # ordered once as x4 and again as x3) prints identically once those
    # sub-details are stripped out. Merge by summing quantity and price so
    # the total stays accurate while avoiding a misleading-looking duplicate.
    merged: dict[str, dict] = {}
    for it in items:
        key = it["item_name"]
        if key in merged:
            merged[key]["price"] += it["price"]
            merged[key]["quantity"] += it["quantity"]
        else:
            merged[key] = dict(it)
    return list(merged.values())


# ─── Orchestration: runs all stages ─────────────────────────────────────────
def process_receipt(filename: str, file_size_bytes: int, image_bytes: bytes) -> dict:
    validate_image(filename, file_size_bytes)

    # FR 4.2: convert PDF to a raster image before sending to Vision API
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if extension == "pdf":
        image_bytes = _pdf_to_image_bytes(image_bytes)

    raw_text = extract_text(image_bytes)
    parsed = parse_receipt_fields(raw_text)

    # Vision succeeds at "finding text" on ANY text-heavy photo — a
    # screenshot of an unrelated app screen, a document, a poster — not just
    # actual receipts, so a clean OCR pass alone doesn't mean this was a
    # receipt. Every genuine receipt in testing always yields at least a
    # date (Malaysian receipts always print one) or a line item; a photo
    # with neither is almost certainly not a receipt at all rather than just
    # a hard-to-read one, so it's rejected here instead of silently handing
    # back a plausible-looking but meaningless result (e.g. a stray "RM
    # 12.50" from unrelated UI text getting treated as the total).
    if parsed["date"] is None and not parsed["line_items"]:
        raise OcrExtractionError(
            "This doesn't look like a receipt — no date or items were "
            "found. Please retake the photo or choose a clearer image."
        )

    receipt_date = parsed.pop("_date_obj") or date.today()
    warranty_info = detect_warranty(raw_text, receipt_date)

    # FR 4.8: assign a category to each line item based on its description
    line_items_with_categories = [
        {
            "item_name": item["item_name"],
            "price": item["price"],
            "quantity": item["quantity"],
            "category_id": (cat := categorise_text(item["item_name"]))["category_id"],
            "category_name": cat["category_name"],
        }
        for item in parsed["line_items"]
    ]

    # Receipt-level category: prefer majority category from line items over vendor name
    if line_items_with_categories:
        item_cats = [i["category_name"] for i in line_items_with_categories
                     if i["category_name"] != "Others"]
        if item_cats:
            majority = max(set(item_cats), key=item_cats.count)
            receipt_category = category_result_for(majority)
        else:
            receipt_category = categorise_text(parsed["vendor_name"] or "")
    else:
        receipt_category = categorise_text(parsed["vendor_name"] or "")

    return {
        "vendor_name": parsed["vendor_name"],
        "amount": parsed["amount"],                     # FR 4.10: receipt total summary
        "date": parsed["date"],
        "raw_text": raw_text,
        "line_items": line_items_with_categories,       # FR 4.6, 4.7, 4.8, 4.9
        "suggested_category_id": receipt_category["category_id"],
        "suggested_category_name": receipt_category["category_name"],
        "suggested_category_confidence": receipt_category["confidence"],
        "date_confidence": "high" if parsed["date"] else "low",
        "warranty": warranty_info,
    }

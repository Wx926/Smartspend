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

from services.categorisation_service import categorise_text
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
]

_CURRENCY = r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*"

# CJK Unicode ranges (common + extension-A) — Malaysian receipts are frequently
# printed in Mandarin (esp. Chinese-Malaysian restaurants/vendors), and Chinese
# item names carry no spaces between characters, so they must be admitted into
# the same name-matching character classes as Latin letters, not handled as a
# separate special case.
_CJK = r"一-鿿㐀-䶿"

# A standalone "-" (space-hyphen-space, a stylistic word separator like
# "Naughty Spare Rib - Full Slab") or a "+"/"/"-joined size descriptor like
# "1+1/2" (as in "HH Asahi 1+1/2") — neither fits a plain word token, so both
# need their own alternative in the word-continuation groups below.
_LOOSE_WORD_SEP = r"-|\d+(?:[+\/]\d+)+"

# Single-line item: alphabetical name, optional product-code/content in middle, price at end.
# e.g. "TEH TARIK 3.50"  →  TEH TARIK, 3.50
# e.g. "FRAP 001200010451 F 5.48 N"  →  FRAP, 5.48
# e.g. "1/2 Roasted Chicken 15.90" → 1/2 Roasted Chicken, 15.90 (menu portion
#      names like "1/4"/"1/2" start with a fraction, not a letter)
LINE_ITEM_PATTERN = re.compile(
    rf"^((?:[A-Za-z{_CJK}][A-Za-z{_CJK}\-&'\/\(\)]*|\d+\/\d+)"
    rf"(?:\s(?:[A-Za-z{_CJK}][A-Za-z{_CJK}\-&'\/\(\)]*|{_LOOSE_WORD_SEP}))*)"
    rf"\s+.*?{_CURRENCY}(\d+[.,]\d{{2}})\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# Item name alone on this line (no price, no code) — multi-line item formats.
# Allows:
#   pure-alpha words:          "GINSENG", "CLIF BAR PB"
#   alpha-start with digits:   "PEPPERONI3Z", "LAMP/STITCH"
#   digit-start WITH a letter: "500MG", "3Z"  (excludes pure barcodes like "001200010451")
#   CJK text:                  "干妙海鲜河粉", "豆奶仙草" (no spaces between characters)
#   dash separator/size descriptor: "Naughty Spare Rib - Full", "HH Asahi 1+1/2"
_NAME_ONLY = re.compile(
    rf"^([A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*"
    rf"(?:\s(?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*|[0-9]+[A-Za-z][A-Za-z0-9\-&'\/\(\)]*|{_LOOSE_WORD_SEP}))*)"
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
    rf"^(\d{{5,}})\s+.*?{_CURRENCY}(\d+[.,]\d{{2}})\s*[A-Z]{{0,2}}\s*$",
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

# Price at end of any line — used for multi-line item continuation lines
# Allows 0-2 letter tax codes after price: N, T, F (US) or SR, ZR, TX (Malaysian GST)
_PRICE_AT_END = re.compile(
    rf"(\d{{1,6}}[.,]\d{{2}})\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# A line that is *nothing but* a price, e.g. "1.00 Y" — optionally with a
# 1-2 letter tax code stuck on either side with no space (OCR sometimes glues
# a tax-code letter directly to the number, e.g. "F3.98 Y").
_BARE_PRICE_LINE = re.compile(
    rf"^[A-Z]{{0,2}}\s*{_CURRENCY}(\d+[.,]\d{{2}})\s*[A-Z]{{0,2}}\s*$",
    re.IGNORECASE,
)

# A line with two bare 5+ digit barcodes and nothing else — a price-override
# item where Vision misread the product's own barcode as its "name" and split
# it from a second (real) barcode, e.g. "4450098211, 004450098211".
_BARE_BARCODE_NAME_LINE = re.compile(r"^(\d{5,}),?\s+\d{5,}\s*$")

# Reaching this section means we're past the itemised list — any names still
# awaiting a price are unrecoverable and must not be paired with a totals figure.
_TOTALS_BOUNDARY = re.compile(
    r"\b(sub[\s\-]?total|total|(?:amount|amt)\s*due|balance\s*due)\b", re.IGNORECASE
)

# Lines containing these words are totals/summaries/headers/footers — not items
SKIP_KEYWORDS = re.compile(
    r"\b(total|subtotal|sub-total|tax|gst|sst|service\s*charge|discount|"
    r"change|cash|rounding|amount|amt|balance|tip|gratuity|receipt|invoice|"
    r"thank\s*you|welcome|visit|shop|store|tel|phone|fax|address|hotline|"
    r"website|www|http|member|loyalty|point|void|refund|exchange|"
    r"description|qty|quantity|item|price|sub\s*total|general\s*ex|sales\s*tax|"
    r"everything|on-line|online|follow\s*us|open|hour|manager|cashier|"
    r"associate|operator|server|bill|order|no\.|ref|reg|tr#|op#|st#|te#|"
    r"visa|mastercard|master\s*card|amex|american\s*express|debit\s*card|"
    r"credit\s*card|approval\s*code|auth(?:orization)?\s*code|eftpos|"
    r"coleslaw|chargrill|grillveg"
    r"|(?<!\-)table)\b",
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
    from pdf2image import convert_from_bytes
    images = convert_from_bytes(pdf_bytes, first_page=1, last_page=1, dpi=200)
    if not images:
        raise OcrValidationError("Could not extract a page from the PDF.")
    buf = io.BytesIO()
    images[0].save(buf, format="PNG")
    return buf.getvalue()


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

    text = result["responses"][0].get("fullTextAnnotation", {}).get("text", "")
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
        r"\b(subtotal|sub[\s\-]total|cash|change|tax|gst|sst|qty|items?\s*sold)\b"
        r"|小计|现金|找零|找续|找赎|消费税|服务税|数量",
        re.IGNORECASE,
    )

    _ROUNDING = re.compile(r"\brounding\b|抹零|四舍五入", re.IGNORECASE)

    # Scan from bottom upward — grand total is near the end; column-header
    # "TOTAL" is near the top and will only be reached if no real total found.
    for i in range(len(lines) - 1, -1, -1):
        line = lines[i]
        if _TOTAL_LINE.match(line) and not _TOTAL_EXCLUDE.search(line):
            check_lines = [line] + lines[i + 1: i + 4]
            # If a rounding-adjustment line follows, the real total comes after it
            rounding_pos = next(
                (k for k, c in enumerate(check_lines) if _ROUNDING.search(c)), None
            )
            if rounding_pos is not None:
                for check in check_lines[rounding_pos + 1:]:
                    m = AMOUNT_PATTERN.search(check)
                    if m:
                        return float(m.group(1).replace(",", "."))
            # No rounding: take first amount on total line or next 2 lines
            for check in check_lines[:3]:
                m = AMOUNT_PATTERN.search(check)
                if m:
                    return float(m.group(1).replace(",", "."))

    # Fallback: largest amount in the receipt
    matches = AMOUNT_PATTERN.findall(raw_text)
    return max(float(m.replace(",", ".")) for m in matches) if matches else None


def _extract_date(raw_text: str) -> date | None:
    for pattern in DATE_PATTERNS:
        match = re.search(pattern, raw_text)
        if match:
            date_str = match.group(1)
            for fmt in ("%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d-%m-%y",
                        "%Y/%m/%d", "%Y-%m-%d", "%m/%d/%y", "%m/%d/%Y"):
                try:
                    return datetime.strptime(date_str, fmt).date()
                except ValueError:
                    continue
    return None


_VENDOR_WORD_LINE = re.compile(
    rf"^[A-Za-z{_CJK}][A-Za-z{_CJK}'&\-]*(\s[A-Za-z{_CJK}][A-Za-z{_CJK}'&\-]*){{0,2}}$"
)


_BHD_LINE = re.compile(r"\bbhd\b|\bberhad\b", re.IGNORECASE)


def _extract_vendor(lines: list[str]) -> str | None:
    """
    Heuristic: prefer ALL CAPS lines in the first 5 lines (store names are
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
    window = lines[:10]
    if any(_BHD_LINE.search(ln) for ln in window):
        for idx, line in enumerate(lines[:5]):
            stripped = line.strip()
            if (not re.search(r"\d{3,}", stripped)
                    and not any(c in stripped for c in "#:*")
                    and len(stripped) > 3
                    and not _is_noise_line(stripped)):
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
        if _VENDOR_WORD_LINE.match(stripped) and not _is_noise_line(stripped):
            return stripped
    for line in lines[:3]:
        if not re.search(r"\d{3,}", line) and not any(c in line for c in "#:*"):
            return line
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
    # A bare 1-3 digit line just before an item's name (e.g. Nando's printing
    # "4" on its own line above "1/4 Chic+1sd-T") is that item's quantity —
    # captured here and consumed by whichever item is emitted next.
    pending_qty: int | None = None

    def _emit(name: str, price: float) -> None:
        nonlocal pending_qty
        qty = pending_qty if pending_qty is not None else 1
        pending_qty = None
        items.append({"item_name": name, "price": price, "quantity": qty})

    # Strip printer formatting tags (e.g. <i>, <b>) that Google Vision reads literally
    _TAG = re.compile(r"<[^>]*>")
    lines = [_TAG.sub("", ln).rstrip() for ln in raw_text.splitlines()]
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if past_totals:
            # Once we've crossed Sub Total/Total, nothing after it is ever a
            # purchasable item — GST breakdown tables, marketing surveys, and
            # footer notes must never be matched, not just excluded from
            # pending-queue bookkeeping (which only stops *new* deferrals).
            i += 1
            continue
        if not line or _is_noise_line(line) or _MASKED_ACCOUNT_NUMBER.match(line):
            if line and _TOTALS_BOUNDARY.search(line):
                # Past the itemised list now — any names/prices still waiting
                # are unrecoverable; don't let them pair with a totals figure.
                pending_names.clear()
                pending_prices.clear()
                pending_qty = None
                past_totals = True
            i += 1
            continue

        # A quantity Vision sometimes glues directly onto the same line as the
        # name instead of printing it on its own line above (e.g. Nando's
        # "3 1/4 Chic+1sd-T @17.90" vs. the usual "3" / "1/4 Chic+1sd-T @17.90"
        # split across two lines) — peel it off so the name underneath is
        # still recognisable by the layouts below. Only once we're past the
        # header (an item has already matched normally), same caution as the
        # deferred-name/price queues use, to avoid misreading a header line's
        # leading number (e.g. "4 NANDOS3") as a quantity+name pair. Not
        # gated on pending_qty being unset: a stray unconsumed qty line just
        # before this one (e.g. a dropped "1/4-M" spice-level line sitting
        # between them) shouldn't block the fresher, more relevant number
        # glued directly to this name from taking over.
        if items:
            qty_prefix = re.match(r"^(\d{1,3})\s+([A-Za-z\d].*)$", line)
            if qty_prefix:
                pending_qty = int(qty_prefix.group(1))
                line = qty_prefix.group(2)

        # Layout 1: single-line match. Skipped for lines carrying a rate marker
        # (@, lb, kg, for) — regex backtracking would otherwise shrink the name
        # capture down to just the token before the marker and mistake the
        # per-unit rate for the real charged total (e.g. "1/4 Chic+1sd-T
        # @17.90" → wrongly "1/4"/17.90 instead of "1/4 Chic+1sd-T"/71.60 from
        # the next line). Such lines fall through to Layout 2's lookahead.
        m = None if _QTY_CALC_LINE.search(line) else LINE_ITEM_PATTERN.match(line)
        if m:
            name = m.group(1).strip()
            price = float(m.group(2).replace(",", "."))
            # Minimum length 3 rejects bare 1-2 letter GST rate codes (SR, ZR,
            # TX) that Malaysia prints directly before the amount, e.g.
            # "SR 106.90" — without this, "SR" itself gets treated as an item.
            if name and price > 0 and 3 <= len(name) <= 40:
                _emit(name, price)
            i += 1
            continue

        # Layout 1b: bare-barcode "name" (price-override item with no description)
        bm = BARCODE_NAME_ITEM_PATTERN.match(line)
        if bm:
            name = bm.group(1).strip()
            price = float(bm.group(2).replace(",", "."))
            if price > 0:
                _emit(name, price)
            i += 1
            continue

        # Layout 2: item name alone on this line, look ahead up to 4 lines for price.
        # Also matches a name ending in "@X.XX" (a per-unit rate, e.g. a menu
        # portion price) — the real charged total is the price being looked
        # ahead for, not the rate itself.
        no = _NAME_ONLY.match(line) or _NAME_WITH_RATE_SUFFIX.match(line)
        if no:
            name = no.group(1).strip()
            if 3 <= len(name) <= 40:
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
                    # Weight/quantity lines (e.g. "1.75 lb @ 1 lb/0.54") carry a
                    # unit price, not the charged total — keep looking past them.
                    if _QTY_CALC_LINE.search(ahead):
                        continue
                    pm = _PRICE_AT_END.search(ahead)
                    if pm:
                        price = float(pm.group(1).replace(",", "."))
                        if price > 0:
                            _emit(name, price)
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
                            _emit(name, pending_prices.pop(0))
                        elif items:
                            # Price wasn't nearby — defer and keep scanning forward
                            # for it. Only once we're past the header (i.e. an item
                            # has already matched normally) — otherwise store-name/
                            # address lines that superficially fit this pattern get
                            # queued ahead of real items.
                            pending_names.append(name)
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
                    _emit(name, price)
                i += 2
                continue
            if name and 3 <= len(name) <= 40:
                if pending_prices:
                    _emit(name, pending_prices.pop(0))
                    i += 1
                    continue
                if items:
                    pending_names.append(name)
                    i += 1
                    continue

        # Layout 4a: bare barcode pair with no price (misread price-override item)
        bn = _BARE_BARCODE_NAME_LINE.match(line)
        if bn and items:
            pending_names.append(bn.group(1))
            i += 1
            continue

        # Layout 4b: a bare price line pairs with the oldest name still waiting,
        # or — if no name is waiting yet — gets buffered for one that hasn't
        # appeared yet (inverted layouts print the price before the name).
        bp = _BARE_PRICE_LINE.match(line)
        if bp:
            price = float(bp.group(1).replace(",", "."))
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
            receipt_category = categorise_text(majority)
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
        "warranty": warranty_info,
    }

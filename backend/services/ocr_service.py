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
import time
import urllib.request
from datetime import datetime, date

from dotenv import load_dotenv
load_dotenv()

from services.categorisation_service import (
    categorise_text,
    category_result_for,
    majority_category,
)
from services.warranty_service import detect_warranty

GOOGLE_VISION_API_KEY = os.environ.get("GOOGLE_VISION_API_KEY", "")

# Deliberately a SEPARATE key from the Flutter app's own GEMINI_API_KEY (in
# the project-root .env, used by the AI Advisor) — a dedicated backend key
# keeps the two features from competing for the same free-tier rate-limit
# pool, especially during a live demo. Add it to backend/.env; there's no
# backend/.env.example yet to update. If unset, the Gemini fallback below is
# silently skipped (same graceful-no-op philosophy as the Dart-side
# GeminiService's own empty-key check).
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
GEMINI_MODEL = "gemini-3.5-flash"  # matches the model already used by gemini_service.dart

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "pdf"}
MAX_FILE_SIZE_MB = 10

AMOUNT_PATTERN = re.compile(
    r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*"
    # Ordered most-specific first, since alternation tries left-to-right and
    # only falls through on failure:
    #   1. comma-grouped thousands WITH decimal cents, e.g. "1,234.56"
    #   2. comma-grouped thousands with NO decimal point, e.g. "175,000" --
    #      common on Indonesian Rupiah receipts, which have no minor decimal
    #      unit at all. Without its own alternative, the plain-decimal
    #      pattern below still partially matches this (its `\d{2}` is happy
    #      to take just the first 2 of the 3 trailing digits, e.g. "175,00"
    #      out of "175,000"), silently undercounting the real amount by
    #      1000x -- confirmed on a real receipt ("TOTAL 175,000" parsed as
    #      175.0 instead of 175000). See _parse_amount_match for how the
    #      resulting string is actually converted to a float.
    #   3. plain decimal amount, e.g. "15.00" or "12,50" -- the original
    #      pattern, `(?!\d)` added so it can't partially match into a longer
    #      digit run the way case 2 exists to prevent.
    r"(\d{1,3}(?:,\d{3})+\.\d{2}(?!\d)"
    r"|\d{1,3}(?:,\d{3})+(?!\d)"
    r"|\d+[.,]\d{2}(?!\d))",
    re.IGNORECASE,
)

# A pure comma-grouped whole number with NO decimal point anywhere, e.g.
# "175,000" or "1,234,567" -- used by _parse_amount_match to tell a thousands
# separator apart from a decimal-comma (e.g. "12,50" meaning 12.50 in some
# European formats), which this pattern deliberately does NOT match (its
# groups are exactly 3 digits each, never 2).
_THOUSANDS_GROUPED = re.compile(r"^\d{1,3}(?:,\d{3})+$")


def _parse_amount_match(raw: str) -> float:
    """Converts a regex-captured amount string to a float, correctly
    distinguishing a comma-grouped THOUSANDS separator from a comma used AS
    a decimal point. A captured string containing an actual "." is
    unambiguous either way -- any comma in it must be a thousands separator,
    since a real amount is never written with two different punctuation
    marks both meaning "decimal point" -- so commas are simply stripped. One
    with no "." at all is a thousands separator only if the whole string is
    pure 3-digit comma groups (_THOUSANDS_GROUPED); otherwise the comma IS
    the decimal point, exactly as before this function existed."""
    cleaned = raw.replace(" ", "")
    if "." in cleaned or _THOUSANDS_GROUPED.match(cleaned):
        return float(cleaned.replace(",", ""))
    return float(cleaned.replace(",", "."))
# Each guarded with (?<!\d)/(?!\d) so it can't match a substring of a LONGER
# digit run — without this, "2018-03-23" (a real YYYY-MM-DD date) contains
# "18-03-23" as a substring, which the DD-MM-YY pattern happily matches on
# its own, misreading the date as "18 Mar 2023" instead of "23 Mar 2018"
# before the correct YYYY-MM-DD pattern below it ever gets a chance to run.
DATE_PATTERNS = [
    r"(?<!\d)(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})(?!\d)",   # 27/06/2026 or 27-06-26
    r"(?<!\d)(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})(?!\d)",     # 2026-06-27
    r"(?<!\d)(\d{4}\.\d{1,2}\.\d{1,2})(?!\d)",             # 2026.07.15 (dot-separated POS timestamp)
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

# Day-Month-Year order, e.g. "07 Jun 2026" — the convention most Malaysian
# receipts actually use, as opposed to the American "Month Day, Year" order
# _MONTH_NAME_DATE above handles. A receipt printing this order fell
# through both this and every numeric DATE_PATTERN entirely (none of them
# expect a month NAME), silently defaulting to today's date with no
# indication anything had gone wrong — confirmed on a real receipt ("07
# Jun 2026" parsed as None, only "Jun 07, 2026" worked). Day and month
# swap position relative to _MONTH_NAME_DATE's groups, handled separately
# in _extract_date rather than trying to force one pattern to cover both
# orders, since that would make an already-dense regex harder to reason
# about for a fairly small gain.
_DAY_MONTH_NAME_DATE = re.compile(
    rf"(\d{{1,2}})\s*(?:st|nd|rd|th)?,?\s*({_MONTH_NAME})\s*,?\s*(\d{{4}})", re.IGNORECASE
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
    # The first token may also be a digit-run WITH a letter attached (e.g.
    # "18CT" in "18CT EGGS") — the same allowance already granted to
    # continuation tokens below, extended to the first position too, since
    # a real item name can just as easily start with a count/size prefix as
    # end with one. Still requires an actual letter somewhere in the token
    # (unlike a bare digit run), so a genuine numbers-only barcode/price row
    # still can't match this as a false "name".
    rf"^((?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*|[0-9]+[A-Za-z][A-Za-z0-9\-&'\/\(\)]*)"
    # A bare 1-4 digit token (no letters at all) is allowed as a continuation
    # word too — product names commonly end in a model/size number that
    # Vision sometimes splits off as its own token with no attached letter,
    # e.g. "ARTLINE 70" read as "AR TL IN E 70" or "A4 SIZE 20 POCKETS".
    rf"(?:\s(?:[A-Za-z{_CJK}][A-Za-z0-9{_CJK}\-&'\/\(\)]*|[0-9]+[A-Za-z][A-Za-z0-9\-&'\/\(\)]*|\d{{1,4}}|{_LOOSE_WORD_SEP}))*"
    # A trailing " #" specifically at the very end of the line is allowed —
    # a size/weight-class marker on US grocery receipts (e.g. "MONT JACK
    # 2#" reconstructed with a space as "MONT JACK 2 #"). Deliberately NOT
    # added as a general mid-line continuation token: that would also let a
    # "#" anywhere else (e.g. an address fragment like "Thornton # 629")
    # falsely match as a plausible item name. Kept inside the capture group
    # so the "#" is actually included in the extracted name, not just
    # matched and discarded.
    r"(?:\s#)?)"
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
# The column right after the item#/barcode is always QTY on this layout —
# captured separately (group 1) from the trailing AMOUNT (group 2) so the
# caller can attach the real printed quantity to the item instead of always
# defaulting to 1. It's a single token, digit-run or lone letter (the same
# misread-"1" tolerance as the trailing columns), never a decimal.
_ALL_NUMBERS_ROW = re.compile(
    r"^(?:\d+(?:[.,]\d+)?|[A-Za-z\-]{0,4}\d[A-Za-z0-9\-]{0,6})\s+"
    r"(\d+|[A-Za-z])\s+"
    r"(?:(?:\d+(?:[.,]\d+)?|[A-Za-z])\s+)*(\d+[.,]\d{2})\s*\*?\s*[A-Z]{0,2}\s*$"
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
#
# "qty" also accepts "price" as an alternative -- confirmed on a real
# receipt (HON HWA HARDWARE) whose header printed as "Ofy Description Price
# Total ( RM )": Vision misread "Qty" as "Ofy" (a plausible glyph confusion,
# Q/O and t/f both being visually similar), so the strict "qty"-only check
# failed to recognise this as a header row at all. That let this exact
# scenario play out: _TOTALS_BOUNDARY caught the header's own "Total (RM)"
# column label instead, wrongly setting past_totals=True before a single
# real item had been parsed, silently discarding all of them (confirmed:
# this receipt's only item, clearly printed and legible, produced zero
# extracted items). "item"/"description" staying a HARD requirement (not
# loosened the same way) is what keeps this safe: a genuine grand-total line
# essentially never contains "item"/"description" itself, so requiring one
# of those PLUS one of "qty"/"price" still can't misfire on an ordinary
# "Total Amount : $8.20" line (has "total"/"amount", but no "item" or
# "description" to pair with it).
_ITEM_TABLE_HEADER = re.compile(
    r"(?=.*\b(?:qty|price)\b)(?=.*\b(?:item|description)\b)", re.IGNORECASE
)

# Lines containing these words are totals/summaries/headers/footers — not items
#
# "clearance" added alongside "discount" -- a real FamilyMart receipt's
# markdown line ("RTE Clearance 25% Timebase -1.23") doesn't say "discount"
# anywhere, so it fell through every check and got extracted as if it were a
# purchased item named "RTE Clearance 25" for a POSITIVE 1.23 -- the sign of
# the actual printed markdown was lost too, in addition to it not being a
# product at all. Kept separate from "discount" (not merged into one regex
# alternative) since both need to independently match on their own.
SKIP_KEYWORDS = re.compile(
    r"\b(total|subtotal|sub-total|tax|gst|sst|service\s*charge|discount|"
    r"clearance|"
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
    # Row membership is keyed on each word's TOP edge rather than its
    # vertical center (a marginally more stable anchor for mixed digit/
    # letter rows) — but this alone does NOT fix a whole-column vertical
    # offset between a wide table's far-left and far-right text (e.g. a
    # name column vs. a price column on a narrow receipt), only borderline
    # same-row-vs-different-row calls for words that are already close in Y.
    # A real case of that wider drift was found on a Costco receipt, root-
    # caused via logged per-word pixel geometry: a price sitting ~9px from
    # the row above and ~10px from its own true row is genuinely closer to
    # the WRONG row by pure Y-distance — no Y-only threshold, however
    # tuned, can resolve that. See _split_price_column below for the fix.
    words = []  # (y_top, x_left, x_right, height, text)
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
                        min(ys), min(xs), max(xs),
                        max(ys) - min(ys) or 1, text,
                    ))

    if not words:
        return ""

    words.sort(key=lambda w: w[0])  # top to bottom by top edge

    # Temporary diagnostic dump — one line per word with its actual pixel
    # geometry, kept so a future case of this same failure can be measured
    # directly instead of guessed at from the reconstructed text alone.
    print("\n===== OCR WORD BOUNDING BOXES (y_top, x_left, x_right, height) =====")
    for y_top, x_left, x_right, height, text in words:
        print(f"  y={y_top:>5}  x=[{x_left:>5},{x_right:>5}]  h={height:>4}  {text!r}")
    print("======================================================================\n")

    rows = _split_price_column(words)

    lines = []
    for row in rows:
        row.sort(key=lambda w: w[1])  # left to right
        # Every entry here is already a distinct word per Vision's own
        # segmentation, so — unlike the old character-level gap heuristic —
        # a single space always belongs between consecutive words.
        lines.append(" ".join(w[4] for w in row))
    return "\n".join(lines)


def _cluster_rows(words: list[tuple]) -> list[list[tuple]]:
    """Groups words (already sorted by top-edge Y) into physical rows by
    comparing each word's Y position against the running row's average —
    the original single-pass reading-order clustering, factored out so it
    can be applied independently to a sub-region's words (see
    _split_price_column)."""
    rows: list[list[tuple]] = []
    for w in words:
        if rows:
            row_y = sum(r[0] for r in rows[-1]) / len(rows[-1])
            row_h = sum(r[3] for r in rows[-1]) / len(rows[-1])
            if abs(w[0] - row_y) <= row_h * 0.6:
                rows[-1].append(w)
                continue
        rows.append([w])
    return rows


# A clean decimal amount, e.g. "23.99" — used to detect a recurring price
# column. Deliberately stricter than AMOUNT_PATTERN (no currency prefix, no
# surrounding text): a barcode or reference number never matches this on its
# own, only an actual charged amount does.
_BARE_DECIMAL = re.compile(r"^\d{1,4}[.,]\d{2}$")

# A standalone totals-section label — used only to cap where the detected
# price column actually ends. Without this, a subtotal/tax/total figure
# printed in the same tight right-aligned x-band as the real item prices
# (extremely common — they're column-aligned on purpose) gets treated as
# part of the item table, dragging its OWN label (SUBTOTAL/TAX/TOTAL) into
# the reconstructed "left column" ahead of where the real prices end up —
# which trips the parser's own totals-boundary detection before it ever
# reaches the real prices, discarding every item.
_TOTALS_LABEL = re.compile(
    r"^(sub[\s\-]?total|total|tax|amount\s*due|balance\s*due)$", re.IGNORECASE
)

# A synthetic line inserted between the left (name) and right (price) blocks
# by _split_price_column — never real receipt text, so it can't collide with
# anything Vision would actually produce. Exists purely as a hard stop for
# the item parser's forward lookahead: a name near the end of the left block
# has fewer real left-column lines left before the price block starts than
# its lookahead window is wide, so without an explicit boundary it can reach
# straight across into the price block and grab the FIRST unrelated price
# there instead of correctly deferring (confirmed: "ECO HALF PAN" — 3 lines
# from the boundary — stole "23.99", the true first item's price, via a
# 4-line lookahead that crossed straight over the boundary).
_PRICE_COLUMN_BOUNDARY = "\x00SPLIT_PRICE_COLUMN_BOUNDARY\x00"


def _split_price_column(words: list[tuple]) -> list[list[tuple]]:
    """Detects a wide item table whose price column sits far enough to the
    right that Y-only row clustering can misattach a price to the row
    above its true item (see the Costco case documented above _cluster_rows'
    caller) — and if found, re-clusters that region's left (name/code) and
    right (price/tax-code) words independently, rather than as one mixed
    Y-ordered stream where a price's own Y position can legitimately sit
    closer to the wrong row than to its true one.

    Falls back to the original single-pass clustering entirely unchanged
    whenever no such recurring column is detected — every other receipt
    layout goes through the exact same code as before.
    """
    decimals = [w for w in words if _BARE_DECIMAL.match(w[4])]
    if len(decimals) < 4:
        return _cluster_rows(words)

    # A genuine price column's amounts share a tight, recurring left edge —
    # unlike barcodes/reference numbers (excluded by _BARE_DECIMAL already).
    # Found via the largest tightly-packed run of x_left values rather than
    # a plain min/max spread: a single unrelated decimal elsewhere on the
    # page (e.g. the per-unit rate "4.29" in a weight annotation like
    # "3 @ 4.29", printed in the name column) would otherwise blow out a
    # naive spread check and hide a real price column behind one outlier.
    x_lefts = sorted(w[1] for w in decimals)
    clusters: list[list[int]] = [[x_lefts[0]]]
    for x in x_lefts[1:]:
        if x - clusters[-1][-1] <= 25:
            clusters[-1].append(x)
        else:
            clusters.append([x])
    price_cluster = max(clusters, key=len)
    if len(price_cluster) < 4:
        return _cluster_rows(words)

    column_boundary = price_cluster[0] - 15
    price_decimals = [
        w for w in decimals if price_cluster[0] - 5 <= w[1] <= price_cluster[-1] + 5
    ]
    table_y_min = min(w[0] for w in price_decimals)

    # A subtotal/tax/total figure is very often printed in this exact same
    # tight x-band (they're column-aligned with the item prices on purpose)
    # and can sit only a few pixels past the last real item — too close for
    # a fixed margin to reliably exclude by Y-position alone. Excluding by
    # the label word's presence instead of a fixed distance handles that
    # regardless of how tight the gap happens to be.
    label_ys = [w[0] for w in words if w[0] > table_y_min and _TOTALS_LABEL.match(w[4])]
    table_margin = 5
    if label_ys:
        cutoff = min(label_ys) - 5
        price_decimals = [w for w in price_decimals if w[0] + w[3] < cutoff]
        if len(price_decimals) < 4:
            return _cluster_rows(words)
        table_margin = 0

    table_y_max = max(w[0] + w[3] for w in price_decimals)

    before = [w for w in words if w[0] < table_y_min - 5]
    table = [w for w in words if table_y_min - 5 <= w[0] <= table_y_max + table_margin]
    after = [w for w in words if w[0] > table_y_max + table_margin]

    left_col = [w for w in table if w[1] < column_boundary]
    right_col = [w for w in table if w[1] >= column_boundary]

    # Require the left column to actually look like a barcode-driven retail
    # table (several standalone 5+ digit product codes), not just "any
    # receipt with a right-aligned price column" — which describes most
    # menu/invoice layouts too (qty + name + tax-code + price all on one
    # line), and those already reconstruct correctly under plain Y
    # clustering with no ambiguity to fix. Splitting one of those into
    # "names now, prices later" anyway doesn't fix anything real and instead
    # actively breaks it: with no barcode of their own, none of those names
    # qualify for the reliable `pending_barcode_names` queue, so they fall
    # into the same speculative queue as any unrelated stray word earlier in
    # the document (a receipt title, a letterhead line) that also failed to
    # find a nearby price — and whichever got queued first wins, scrambling
    # names and prices from completely unrelated items together. Confirmed
    # on a real menu-style Malaysian receipt (Morganfield's): no barcodes,
    # split wrongly triggered, items came out paired with fragments of the
    # letterhead and receipt title instead of their own names.
    barcode_count = sum(1 for w in left_col if re.match(r"^\d{5,}$", w[4]))
    if barcode_count < 3:
        return _cluster_rows(words)

    # Having barcodes isn't itself proof of the misalignment this function
    # exists to fix — a Malaysian tax invoice's "numbers-row-then-name"
    # layout (barcode + qty + unit-price + amount ALL on one printed row,
    # the item's own name on a SEPARATE bulleted row below it) also has one
    # barcode per item, but each row's price is already correctly attached
    # to its own barcode under plain Y clustering — there's no cross-column
    # drift there to begin with, because it was never really a two-column
    # table (name and price were never on the same physical row in the
    # first place). Splitting it anyway doesn't fix anything and actively
    # breaks it: the price gets sliced away from its own barcode row, and a
    # wrapped item name can get torn apart if part of it lands past the
    # column boundary (confirmed on a real TED HENG receipt: split
    # incorrectly triggered — barcode-count alone was satisfied — and an
    # item's price vanished while a fragment of another item's wrapped name
    # landed in the price column).
    #
    # Detected by re-clustering the table region with the ORIGINAL,
    # unsplit algorithm and checking whether each price's own row already
    # matches _ALL_NUMBERS_ROW (a bare "barcode qty ... amount" row with no
    # real name text in it — Costco-style misaligned rows never match this,
    # since a real item name's multi-letter words break the pattern; TED
    # HENG's genuine numbers-rows always do). If most already do, this
    # table was never actually misaligned — leave it alone.
    baseline_table_rows = _cluster_rows(table)
    row_texts = [
        (row, " ".join(w[4] for w in sorted(row, key=lambda w: w[1])))
        for row in baseline_table_rows
    ]
    already_correct = 0
    for pd in price_decimals:
        for row, text in row_texts:
            if pd in row:
                if _ALL_NUMBERS_ROW.match(text):
                    already_correct += 1
                break
    if already_correct >= len(price_decimals) * 0.5:
        return _cluster_rows(words)

    # All left-column (name/code) rows first, in top-to-bottom order, then
    # all right-column (price/tax-code) rows — rather than interleaving them
    # by Y position, which is exactly the unreliable comparison this
    # function exists to avoid. The downstream item parser already expects
    # and correctly handles this "names now, prices later" shape (its
    # deferred-name FIFO queue), as long as each name is recognised as
    # definitely belonging to its own catalogued item rather than treated as
    # possibly wrapping into the next line — see `had_barcode_prefix` in
    # _extract_line_items.
    boundary_row = [[(0, 0, 0, 1, _PRICE_COLUMN_BOUNDARY)]]  # one row, one word
    return (
        _cluster_rows(before)
        + _cluster_rows(left_col)
        + boundary_row
        + _cluster_rows(right_col)
        + _cluster_rows(after)
    )


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


# A correct extraction's line-item prices should sum to something close to
# the grand total — the gap is usually tax (total > items) or a discount/
# clearance markdown (total < items, e.g. "RTE Clearance 25%" knocking the
# printed total below the item subtotal — confirmed on a real FamilyMart
# receipt: items summed to 15.80, printed TOTAL was 14.55 after an -RM1.23
# discount, ratio 1.086, a completely correct extraction that the old
# tighter ceiling wrongly flagged as broken). A badly mis-parsed receipt
# (missed items, a row's price stolen by the wrong item, etc.) usually shows
# up as this sum falling far short of the total instead, so the floor (0.7)
# stays tight — that direction has no legitimate everyday explanation the
# way a discount does. The ceiling only needs enough headroom to clear that
# confirmed 1.086 case with margin (1.2) — NOT the 1.5 this was briefly
# widened to: that wide a window let moderately-wrong regex extractions
# (missing/duplicated items, a stray extra row) slide through as "high"
# confidence purely by coincidental ratio, silently skipping the Gemini
# fallback below and quietly regressing accuracy with no visible warning —
# matches a real regression report: once the ceiling was loosened that far,
# the "Re-extracted with AI" badge stopped appearing across a retest of
# receipts that had previously triggered it, and accuracy dropped to ~80-90%
# (pure regex, uncorrected) with no low-confidence warning either.
#
# Shared with voice_service.parse_voice_expense (hence no leading underscore
# despite being internal to this package) — the same "do the parsed items
# actually add up" question applies just as much to a voice-parsed entry as
# an OCR one, and the confidence UI on the Flutter side defaults to treating
# a MISSING items_confidence field as high/trustworthy rather than low — so
# leaving it unset for voice results (as it originally was) isn't neutral,
# it's actively misleading (confirmed: saying "Hello!" with no expense
# content produced a synthetic RM0.00 placeholder item that still showed a
# green "HIGH" confidence badge, while every other field on the same result
# correctly showed LOW for genuinely having nothing to go on).
def items_confidence(line_items: list[dict], amount: float | None) -> str:
    if not amount or amount <= 0 or not line_items:
        return "low"
    items_sum = sum(it["price"] for it in line_items)
    if items_sum <= 0:
        return "low"
    ratio = items_sum / amount
    return "high" if 0.7 <= ratio <= 1.2 else "low"


# ─── Stage 3: Post-Processing and Data Structure ────────────────────────────
def parse_receipt_fields(raw_text: str) -> dict:
    # _PRICE_COLUMN_BOUNDARY is a synthetic marker _extract_line_items relies
    # on (see its declaration) — everything else here works off the text a
    # human would actually expect, with that marker invisible to it.
    clean_text = raw_text.replace(_PRICE_COLUMN_BOUNDARY, "")
    lines = [line.strip() for line in clean_text.splitlines() if line.strip()]

    amount = _extract_amount(clean_text)
    receipt_date = _extract_date(clean_text)
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
        "items_confidence": items_confidence(line_items, amount),
        "_date_obj": receipt_date,
    }


def _find_reliable_total(raw_text: str) -> float | None:
    """
    Strategies 1+2 of _extract_amount (see its docstring) -- an amount found
    because a 'Total'/'Amount Due' keyword was actually seen nearby, as
    opposed to Strategy 3's blind "largest 2-decimal number anywhere" guess.
    Split out so the not-a-receipt check in process_receipt can require
    *this* specific kind of evidence -- a keyword-anchored total -- without
    letting the blind guess (which fires on ANY document containing two
    decimal-formatted numbers, receipt or not) count as proof something is
    a receipt at all. See _looks_like_non_receipt_report's docstring for the
    real case (a gym body-scan printout) this was guarding against.
    """
    lines = [ln.strip() for ln in raw_text.splitlines()]

    _TOTAL_LINE = re.compile(
        r"^(total|amount\s*due|balance\s*due|rounded?\s*total"
        r"|总计|合计|总额|应付)",
        re.IGNORECASE,
    )
    _TOTAL_EXCLUDE = re.compile(
        # "total\s*items?" (e.g. "Total Items = 1.00") is a distinct
        # exclusion from "items?\s*sold" -- confirmed on a real receipt
        # (RESTORAN HASSANBISTRO) whose actual grand total got scrambled
        # into unreadable fragments by reading-order reconstruction, leaving
        # "Total Items = 1.00" -- a bare ITEM COUNT, not a currency amount --
        # as the only "total"-prefixed line _TOTAL_LINE could still match,
        # wrongly returning 1.00 as the receipt's total. Deliberately
        # requires "total" and "item(s)" to sit adjacent (only whitespace
        # between them) rather than matching bare "items?" anywhere on the
        # line -- a looser version would also wrongly exclude a genuinely
        # correct total line like "TOTAL FOR 14 ITEMS 338.16" (a real SPAR
        # receipt), where the grand total amount IS printed on that same
        # line, just with "FOR 14" separating the two words.
        r"\b(subtotal|sub[\s\-]total|cash|change|tax|gst|sst|qty|"
        r"items?\s*sold|total\s*items?|payable|savings?)\b"
        r"|小计|现金|找零|找续|找赎|消费税|服务税|数量",
        re.IGNORECASE,
    )

    # Carve-out for the blanket "gst" exclusion just above: that exclusion
    # exists to stop a bare GST/tax-only figure ("GST Payable : 1.76", "Total
    # GST 3.57") from being mistaken for the grand total -- but the same
    # blanket check also wrongly excludes a line that IS the genuine grand
    # total and merely says so using the word "GST" as a descriptor, e.g.
    # "Total Incl . of GST 7.00" / "Total ( Inclusive of GST ) : 31.02".
    # Confirmed on a real receipt (LIM SENG THO HARDWARE) whose only total
    # line is exactly this shape, with no cleaner GST-free "TOTAL: X" line
    # anywhere else to fall back on -- without this carve-out, the search
    # fell through every candidate and landed on an unrelated GST-summary
    # sub-figure instead.
    #
    # Requires "incl"/"inclusive" to be followed by "of" specifically, NOT
    # just present anywhere after "total" -- an earlier looser version
    # (matching bare "incl") caused a real regression on a McDonald's
    # receipt: "TOTAL INCLUDES 6 % GST 1.44" also contains "incl", but that
    # line states the GST amount ITSELF ("the total includes 6% GST, [equal
    # to] 1.44"), not the grand total -- wrongly un-excluding it overwrote an
    # already-correct result (25.40, from a separate clean "Total Rounded
    # 25.40" line) with the tax component instead. "Total Incl. of GST" and
    # "Total (Inclusive of GST)" both have "of" directly after incl(usive);
    # "TOTAL INCLUDES ... GST" does not -- a reliable distinguishing signal
    # confirmed against both real cases.
    #
    # Between "incl(usive)" and "of", `[\s.]*` (not `\.?\s+`) tolerates any
    # mix of stray spaces and a period in either order -- Vision's own
    # reconstruction of the real LIM SENG THO receipt inserted a SPACE
    # before AND after the period ("Total Incl . of GST 7.00"), which a
    # dot-then-whitespace-only pattern can't match at all. Confirmed the
    # hard way: with the stricter version, this carve-out silently never
    # fired on the real image (only ever verified against a hand-typed test
    # string using plain "Incl. of"), so _find_reliable_total fell through
    # every candidate to the blind Strategy-3 max -- which then grabbed
    # "10.00" off an unrelated "10.00 NOS X 0.70 7.00 SR" quantity column
    # instead of the real total (7.00).
    _TOTAL_INCLUSIVE_GST = re.compile(
        r"total\W*\(?\s*incl(?:usive)?[\s.]*of\b", re.IGNORECASE
    )

    def _is_total_excluded(text: str) -> bool:
        return bool(_TOTAL_EXCLUDE.search(text)) and not _TOTAL_INCLUSIVE_GST.search(text)

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
    # The comma-grouped-thousands alternative (see AMOUNT_PATTERN's own
    # comment) is included here too, so a receipt total's own comma-
    # thousands format (e.g. "TOTAL 175,000") isn't separately re-broken by
    # this loosened pattern even after AMOUNT_PATTERN itself was fixed.
    _AMOUNT_LOOSE = re.compile(
        rf"{_CURRENCY}(\d{{1,3}}(?:,\d{{3}})+\.\d{{2}}(?!\d)"
        rf"|\d{{1,3}}(?:,\d{{3}})+(?!\d)"
        rf"|\d+[.,]\s?\d{{2}}(?!\d))",
        re.IGNORECASE,
    )

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
        if _TOTAL_LINE.match(line) and not _is_total_excluded(line):
            check_lines = [line] + lines[i + 1: i + 4]
            # If a rounding-adjustment line follows, the real total comes after it
            rounding_pos = next(
                (k for k, c in enumerate(check_lines) if _ROUNDING.search(c)), None
            )
            if rounding_pos is not None:
                for check in check_lines[rounding_pos + 1:]:
                    if _is_total_excluded(check):
                        continue
                    m = _AMOUNT_LOOSE.search(check)
                    if m:
                        return _parse_amount_match(m.group(1))
            # No rounding: take first amount on total line or next 2 lines —
            # re-checking _is_total_excluded on each is what stops a "CASH
            # TEND 11.00" or "CHANGE DUE 5.89" line (checked only as a
            # fallback when the total line's own amount fails to parse) from
            # being mistaken for the grand total.
            for check in check_lines[:3]:
                if _is_total_excluded(check):
                    continue
                m = _AMOUNT_LOOSE.search(check)
                if m:
                    return _parse_amount_match(m.group(1))

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
                if _is_total_excluded(window):
                    continue
                midline_amount = _parse_amount_match(m.group(1))
                break

    return midline_amount


def _extract_amount(raw_text: str) -> float | None:
    """
    FR 4.10: Extract the receipt grand total.
    Scans bottom-up so the grand total line (always near the end of the
    receipt) is found before any 'TOTAL' column header in the items table.
    Strategy 1+2: see _find_reliable_total.
    Strategy 3: fallback to the largest amount anywhere in the text.
    """
    reliable = _find_reliable_total(raw_text)
    if reliable is not None:
        return reliable

    # Fallback: largest amount in the receipt
    matches = AMOUNT_PATTERN.findall(raw_text)
    return max((_parse_amount_match(m) for m in matches), default=None)


# Two independent signals distinguish a body-composition/lab-report style
# document (e.g. Anytime Fitness's Evolt 360 body scan printout) from a real
# purchase receipt -- kept separate because either one surviving Vision's
# reading-order reconstruction alone is enough:
#
# 1. Bracketed reference ranges ("[52.9 - 64.7]", "[70%]") printed next to a
#    measured value. The FULL "[number - number]" pattern turned out to be
#    fragile in practice: confirmed on a real photo of just this document's
#    lower half where Vision's block-based reconstruction interleaved
#    unrelated text between the "[" and its numbers, breaking the sequence
#    apart even though the bracket characters themselves survived intact.
#    Counting BARE "[" characters was the looser proxy used for this, on
#    the assumption that "a real receipt essentially never prints a square
#    bracket at all" -- but that assumption is simply false, confirmed on a
#    real Thunder Match Technology (TMT) invoice whose footer prints
#    "[[Customer Service Hotline Tel : ...]]". Two brackets in ordinary
#    prose were enough to condemn an otherwise perfectly good receipt as a
#    "report", with no way for the user to get past it. (It only surfaced
#    once a photo captured the full receipt including that footer -- an
#    earlier scan cropped above it and sailed through, which is exactly how
#    misleading this heuristic was.)
#    So the bracket must now be followed by a DIGIT ("[52.9", "[70%") --
#    faithful to what a reference range actually looks like, and what this
#    signal was always described as detecting, while ignoring bracketed
#    prose. Signal 2 below independently covers the fragile case that
#    motivated the loose version (brackets separated from their numbers),
#    so nothing is lost by tightening this one back up.
# 2. Large, clearly-printed section headings unique to this report type
#    ("SEGMENTAL ANALYSIS", "TOTAL BODY WATER", ...). Confirmed necessary
#    against that same lower-half crop, which had no visible date/name
#    header and still needed a second, independent signal once the bracket
#    check alone proved fragile. Large printed headings are far less prone
#    to the character-level noise that breaks up small bracket punctuation.
_NON_RECEIPT_REPORT_PHRASES = [
    "body composition", "body scan", "segmental analysis",
    "skeletal muscle mass", "visceral fat", "lean body mass",
    "total body water", "total body fat percentage",
    "intracellular fluid", "extracellular fluid", "bio age", "bwi score",
    "basal metabolic rate", "waist to hip ratio", "abdominal circumference",
]


# A "[" opening what looks like a measured reference range -- i.e. followed
# by a number ("[52.9 - 64.7]", "[70%]"), not by prose ("[[Customer Service
# Hotline"). See signal 1's comment above.
_REFERENCE_RANGE_BRACKET = re.compile(r"\[\s*\d")


def _looks_like_non_receipt_report(raw_text: str) -> bool:
    if len(_REFERENCE_RANGE_BRACKET.findall(raw_text)) >= 2:
        return True
    lowered = raw_text.lower()
    return sum(1 for phrase in _NON_RECEIPT_REPORT_PHRASES if phrase in lowered) >= 2


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

    # Day-Month-Year order (e.g. "07 Jun 2026") -- see _DAY_MONTH_NAME_DATE's
    # own comment for why this needs its own pattern rather than reusing
    # _MONTH_NAME_DATE above, which expects the opposite word order.
    match = _DAY_MONTH_NAME_DATE.search(raw_text)
    if match:
        month_key = re.sub(r"\s+", "", match.group(2)).lower()[:3]
        month_num = _MONTH_TO_NUM.get(month_key)
        if month_num:
            try:
                return date(int(match.group(3)), month_num, int(match.group(1)))
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
        # A clean, plausible-brand candidate line seen just before reaching
        # the Sdn Bhd line itself — used as a fallback below when that line
        # doesn't recur elsewhere (the ONLY signal the loop otherwise has
        # for preferring it). Malaysian receipts overwhelmingly print the
        # trading name directly above the legal entity's registered name
        # (confirmed: "FARM TO PLATE" / "MALAYSIA FOOD CORPORATION SDN
        # BHD", with no recurrence anywhere else on the receipt and no
        # "trading as" disclosure either — the recurrence check alone left
        # this case falling straight through to the legal entity name).
        # Deliberately only the line IMMEDIATELY prior, not just any
        # earlier candidate — an unrelated tagline further up (the exact
        # "PERI-PERI CHICKEN" case the recurrence check itself already
        # guards against) must not win this way too.
        immediately_prior_candidate: str | None = None
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
                if immediately_prior_candidate is not None:
                    return immediately_prior_candidate
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
                immediately_prior_candidate = None
                continue
            normalised = stripped.lower()
            rest = " ".join(window[:idx] + window[idx + 1:]).lower()
            if normalised in rest:
                return stripped
            # A real trading name/logo on a Malaysian receipt letterhead is
            # printed in caps or title case -- never entirely lowercase --
            # confirmed on two real SROIE receipts where a person's name
            # ("tan woon yann", "tan chay yee", both printed all-lowercase
            # directly above the Sdn Bhd line, apparently a cashier/customer
            # name on that receipt template) was wrongly returned as the
            # vendor purely for sitting in this position, ahead of the
            # actual business name ("BOOK TA K (TAMAN DAYA) SDN BHD",
            # "OJC MARKETING SDN BHD") printed right below it. An all-
            # lowercase line is disqualified from this specific
            # position-only signal (NOT from the stronger recurrence check
            # just above, which still applies regardless of case) so the
            # loop falls through to the Sdn Bhd line's own name instead.
            if stripped != stripped.lower() or not any(c.isalpha() for c in stripped):
                immediately_prior_candidate = stripped

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
    # Names known to belong to a real catalogued item — their own barcode
    # was seen and stripped (see `had_barcode_prefix`) — kept separate from
    # the more speculative `pending_names` (a name-only line that merely
    # failed to find a nearby price, which can just as easily be a stray
    # letterhead/tagline word with no real price anywhere). A bare price
    # line always satisfies this reliable queue first — otherwise a stray
    # word queued earlier in the document (e.g. a brand tagline like
    # "WHOLESALE" sitting alone with no price nearby either) would jump the
    # line ahead of a genuine item and consume its price.
    pending_barcode_names: list[str] = []
    pending_prices: list[float] = []
    # Parallel to pending_prices — the real printed quantity for a price
    # queued from a numbers-row (_ALL_NUMBERS_ROW), or None when a queued
    # price came from a layout with no qty column of its own (e.g. a bare
    # price line), so the default-to-1 behaviour in _emit still applies.
    # Always appended/popped in lockstep with pending_prices so the two
    # stay index-aligned.
    pending_qtys: list[int | None] = []
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
        if line == _PRICE_COLUMN_BOUNDARY:
            # Purely a marker for the lookahead loop below — never a real
            # line, skip over it without touching any pending queues (prices
            # genuinely haven't been reached yet at this point).
            i += 1
            continue
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
                pending_barcode_names.clear()
                pending_prices.clear()
                pending_qtys.clear()
                pending_qty = None
                pending_wrapped_name = None
                seen_header = True
            elif line and _TOTALS_BOUNDARY.search(line):
                # Past the itemised list now — any names/prices still waiting
                # are unrecoverable; don't let them pair with a totals figure.
                pending_names.clear()
                pending_barcode_names.clear()
                pending_prices.clear()
                pending_qtys.clear()
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
        #
        # The leading digit itself is also allowed to be a stray punctuation
        # mark or look-alike letter standing in for a misread "1" -- the same
        # tolerance _ALL_NUMBERS_ROW above already needs for its own qty
        # column, for the same reason (a partially obscured "1" degrades to
        # whatever vertical-stroke-shaped glyph Vision guesses instead).
        # Confirmed on a real receipt with a physical fold across the item
        # table: "1 PARMESAN TRUFFLE FRIES 29.00" came back as "! MESAN
        # TRUFFLE FRIES 29.00" (the fold ate the "PAR" too) -- without this,
        # the "!" fails every layout's name-start check and the entire line,
        # price included, silently vanishes rather than just losing its qty.
        qty_prefix = re.match(r"^(\d{1,3}|[!|lI])\s+([A-Za-z\d].*)$", line)
        line_qty = (
            int(qty_prefix.group(1)) if qty_prefix and qty_prefix.group(1).isdigit()
            else 1 if qty_prefix else None
        )
        if qty_prefix:
            line = qty_prefix.group(2)

        # A long barcode/SKU number (5+ digits) glued as a bare prefix before
        # the item's own name on its own line — e.g. Parkson's "438049 ALAIN
        # DELON BRIEF -" — carries no information useful to the user and,
        # unlike the 1-3 digit QUANTITY prefix stripped above, doesn't fit
        # any layout's name grammar at all as a bare digit-run, so the whole
        # line would otherwise never match anything and the item is silently
        # dropped entirely.
        # Guarded against a headerless numbers-row (_ALL_NUMBERS_ROW) whose
        # QTY column got misread as a single stray letter, e.g. "9557546953990
        # f 0.85 0.00 0.85 *" — without this guard that single letter looks
        # exactly like a name starting after the barcode, stripping it down to
        # "f 0.85 0.00 0.85 *", which then matches NEITHER pattern and silently
        # loses the row's price. The item name on the next line then finds no
        # price waiting for it, steals the *following* item's price via its
        # forward lookahead instead, and every item after that shifts by one.
        # An optional single tax-flag letter (e.g. "E"/"A") is tolerated
        # before the barcode too — a US-retail-style receipt (Costco) prints
        # one immediately to the left of every item's own barcode+name row.
        # The name itself may start with a digit-run+letter token (e.g.
        # "18CT" in "18CT EGGS") as well as a plain letter/CJK — same
        # allowance as _NAME_ONLY's first token, for the same reason.
        barcode_prefix = re.match(
            rf"^(?:[A-Za-z]\s+)?\d{{5,}}\s+((?:[A-Za-z{_CJK}]|\d+[A-Za-z]).*)$", line
        )
        had_barcode_prefix = bool(barcode_prefix) and not _ALL_NUMBERS_ROW.match(line)
        if had_barcode_prefix:
            line = barcode_prefix.group(1)

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
            qty_str = an.group(1)
            price = float(an.group(2).replace(",", "."))
            if price > 0 and not past_totals:
                pending_prices.append(price)
                pending_qtys.append(int(qty_str) if qty_str.isdigit() else 1)
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
                    row_qty = pending_qtys.pop(0)
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
                    _emit(full_name, price, line_qty if line_qty is not None else row_qty)
                    i += consumed
                    continue
                price_found = False
                broke_on_name = False
                for j in range(i + 1, min(i + 5, len(lines))):
                    ahead = lines[j].strip()
                    if not ahead:
                        continue
                    if ahead == _PRICE_COLUMN_BOUNDARY:
                        # Hard stop: the price column genuinely hasn't started
                        # yet at this point, so nothing beyond this marker
                        # could possibly be this name's own price — without
                        # this, a name near the end of the left block (fewer
                        # real lines left before the boundary than the
                        # lookahead window is wide) reaches straight across
                        # into the price block and grabs the FIRST unrelated
                        # price there instead. Deliberately NOT broke_on_name
                        # (this isn't "another item's name interrupted us") —
                        # falls through to the exhausted-lookahead defer path.
                        break
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
                            row_qty = pending_qtys.pop(0)
                            _emit(name, pending_prices.pop(0), line_qty if line_qty is not None else row_qty)
                        elif had_barcode_prefix:
                            # This name's own barcode was just stripped off the
                            # same line, so it's definitely a distinct
                            # catalogued item — queue it in the reliable,
                            # barcode-confirmed queue rather than the
                            # speculative one, so a later unrelated stray word
                            # (e.g. a letterhead line that also failed its own
                            # lookahead) can't jump the line and steal its price.
                            pending_barcode_names.append(name)
                        else:
                            # Price wasn't nearby — defer and keep scanning forward for it.
                            pending_names.append(name)
                    elif had_barcode_prefix:
                        # What looked like a different item's name came next —
                        # but unlike the generic case below, this name's own
                        # barcode was already confirmed, so it can't be a
                        # same-item wrap fragment (a wrap fragment never has
                        # its own barcode). This is exactly what happens on a
                        # reconstructed two-column table (see
                        # _split_price_column): every barcode-confirmed name
                        # from that region is immediately followed by MORE
                        # names, not its own price, so the lookahead above
                        # was never going to find it — defer to the reliable
                        # queue instead of misfiling it as a wrap fragment.
                        pending_barcode_names.append(name)
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
                    row_qty = pending_qtys.pop(0)
                    _emit(name, pending_prices.pop(0), line_qty if line_qty is not None else row_qty)
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
                if pending_barcode_names:
                    _emit(pending_barcode_names.pop(0), price)
                elif pending_names:
                    _emit(pending_names.pop(0), price)
                elif not past_totals:
                    pending_prices.append(price)
                    pending_qtys.append(None)
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


# A phone camera commonly stores a photo in its sensor's native orientation
# and records how to rotate it for display as an EXIF "Orientation" tag,
# rather than physically rotating the pixel data — a viewer that honours
# that tag renders it upright, but Vision's own decoder doesn't reliably
# apply it every time (confirmed: the exact same receipt, rescanned,
# sometimes comes back as an unreadable scramble of disconnected text
# fragments — the same failure mode as genuinely feeding it a sideways
# image). Baking the rotation into the pixels here removes that ambiguity
# regardless of how Vision's decoder happens to behave on a given request.
def _normalize_orientation(image_bytes: bytes) -> bytes:
    from PIL import Image, ImageOps

    try:
        image = Image.open(io.BytesIO(image_bytes))
        transposed = ImageOps.exif_transpose(image)
        if transposed is image:
            # No orientation tag, or already upright — skip the lossy
            # re-encode and hand back the original bytes untouched.
            return image_bytes
        out = io.BytesIO()
        transposed.save(out, format=image.format or "JPEG")
        return out.getvalue()
    except Exception:
        # Anything unreadable as an image here still gets a shot at Vision
        # as-is, rather than failing the whole request outright.
        return image_bytes


# Structured-output schema for the Gemini fallback below (Gemini's schema
# format — a Google-specific, upper-cased subset of OpenAPI, NOT the same
# casing as JSON Schema). Requesting responseMimeType "application/json"
# against this schema, rather than free-form prose, means the response is
# reliably parseable JSON with no markdown-fence stripping or ad-hoc regex
# needed — appropriate here specifically because this call's whole purpose
# is structured extraction, unlike gemini_service.dart's prose-advice calls.
_GEMINI_RECEIPT_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "vendor_name": {"type": "STRING"},
        "date": {"type": "STRING", "description": "ISO 8601 date, YYYY-MM-DD"},
        "total": {"type": "NUMBER"},
        "line_items": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "item_name": {"type": "STRING"},
                    "quantity": {"type": "INTEGER"},
                    "price": {"type": "NUMBER"},
                    # Piggybacked onto this same call rather than a separate
                    # categorisation request — costs nothing extra against
                    # the tight daily quota, and Gemini's actual language
                    # understanding of a menu item ("Seafood Pomodoro
                    # Risotto") meaningfully beats the rule-based keyword
                    # matcher (categorisation_service.py) for exactly the
                    # cases that reach this fallback in the first place:
                    # unusual receipts the simple regex/keyword layers
                    # already struggled with. enum constrains it to the
                    # app's actual category set so it can never invent a
                    # category name the rest of the system doesn't know.
                    "category": {
                        "type": "STRING",
                        "enum": ["Food & Dining", "Transport", "Shopping",
                                 "Entertainment", "Health", "Utilities", "Others"],
                    },
                },
                "required": ["item_name", "price"],
            },
        },
    },
    "required": ["line_items"],
}

_GEMINI_RECEIPT_PROMPT = """You are reading a photo of a purchase receipt. Extract the following as JSON matching the given schema:

- vendor_name: the store/merchant name
- date: the receipt's date, in YYYY-MM-DD format
- total: the final grand total actually charged (after tax, not the subtotal)
- line_items: each individual purchased item, with:
  - item_name: the product/item description as printed
  - quantity: the number of units purchased (use 1 if not shown separately)
  - price: the TOTAL charged for that line (quantity x unit price), not a per-unit rate
  - category: your best guess at which ONE of these categories this item belongs to,
    based on what the item actually is (not the store it's from): Food & Dining, Transport,
    Shopping, Entertainment, Health, Utilities, Others. Use "Others" only if none plausibly fit.

Read the receipt's actual column layout carefully — an item's name and its price may be printed on the same physical row, or wrap across nearby rows, depending on how this particular receipt is laid out. Do not guess or invent items that aren't printed. If a value truly isn't legible, omit it rather than fabricating one."""


# HTTP 429 from Gemini covers two VERY different situations that must not be
# handled the same way -- confirmed by reading the actual error body during a
# real batch run over FYP_IMAGES, not just the status code:
#   1. A short per-minute request-rate burst (status RESOURCE_EXHAUSTED, but
#      the violated quotaId has no "PerDay" in it, or a 503 -- an ordinary
#      transient server hiccup). Both clear up in seconds; retrying shortly
#      after reliably rescues the call.
#   2. The free tier's actual quota, which is PER-DAY, not per-minute (e.g.
#      quotaId "GenerateRequestsPerDayPerProjectPerModel-FreeTier", a cap as
#      low as 20 requests/day for this model on the free tier). Once that's
#      exhausted, EVERY call fails with 429 for the rest of the day -- no
#      amount of short-backoff retrying will ever clear it (confirmed: the
#      body's own "retryDelay" hint, e.g. "38s", is meaningless here and does
#      NOT mean the daily quota resets that soon). Retrying it anyway wastes
#      several seconds per receipt for a call that cannot possibly succeed,
#      and burns through this module's daily allowance faster to boot.
# So: retry #1, never retry #2 -- and once #2 is seen, remember it for the
# rest of this process so later receipts in the same run/session skip the
# network call entirely instead of each independently rediscovering the same
# exhausted quota (see _gemini_daily_quota_exhausted_until below).
_GEMINI_RETRYABLE_CODES = {429, 503}
_GEMINI_MAX_ATTEMPTS = 3
_GEMINI_RETRY_BACKOFF_S = (2, 5)  # delay before attempt 2, then attempt 3

# Set to a wall-clock time.time() cutoff once a PerDay quota exhaustion is
# seen -- module-level (not per-request) so every receipt processed by this
# running backend after that point can skip straight to "don't bother", not
# just retries within a single call. 24h is a conservative upper bound on a
# free-tier daily reset; a fresh process restart also clears it immediately,
# which happens naturally on every redeploy.
_gemini_daily_quota_exhausted_until: float | None = None


def _is_daily_quota_exhausted(http_error) -> bool:
    """True if this 429's body identifies a PerDay quota (see the module
    comment above) rather than a short per-minute burst. Defensive default:
    an unparseable body is treated as NOT a daily exhaustion, so a genuinely
    transient 429 whose body happens to fail to parse still gets retried
    rather than being wrongly written off for the rest of the day."""
    if http_error.code != 429:
        return False
    try:
        body = http_error.read().decode(errors="replace")
    except Exception:
        return False
    return "PerDay" in body


def _urlopen_with_retry(req: urllib.request.Request, timeout: int) -> bytes:
    """urllib.request.urlopen(), retrying a transient 503 (or a non-daily
    429) with a short backoff. A daily-quota-exhaustion 429 is never
    retried, and instead sets _gemini_daily_quota_exhausted_until so later
    calls this process makes short-circuit before even reaching the network
    (see _gemini_fallback_extract)."""
    import urllib.error

    global _gemini_daily_quota_exhausted_until

    last_error = None
    for attempt in range(_GEMINI_MAX_ATTEMPTS):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            last_error = e
            if e.code == 429 and _is_daily_quota_exhausted(e):
                _gemini_daily_quota_exhausted_until = time.time() + 24 * 3600
                print("Gemini fallback: daily free-tier quota exhausted -- "
                      "skipping retries and further calls for the rest of today.")
                raise
            if e.code not in _GEMINI_RETRYABLE_CODES or attempt == _GEMINI_MAX_ATTEMPTS - 1:
                raise
            print(f"Gemini fallback got HTTP {e.code}, retrying in "
                  f"{_GEMINI_RETRY_BACKOFF_S[attempt]}s (attempt {attempt + 2}/{_GEMINI_MAX_ATTEMPTS})...")
            time.sleep(_GEMINI_RETRY_BACKOFF_S[attempt])
    raise last_error  # unreachable -- loop always either returns or raises above


# Called only when the regex-based extraction above looks unreliable (see
# `items_confidence` in parse_receipt_fields) — sent the ORIGINAL PHOTO, not
# the already-reconstructed OCR text, so it can bypass whatever reading-order
# mistake caused the low-confidence result in the first place, rather than
# re-parsing the same already-scrambled text a second time. Never raises: on
# any failure (no key configured, network error, malformed response) this
# returns None and the caller keeps the original regex result — the same
# graceful-degradation philosophy already used by gemini_service.dart on the
# Dart side and by _normalize_orientation just above.
def _gemini_fallback_extract(image_bytes: bytes) -> dict | None:
    if not GEMINI_API_KEY:
        return None

    global _gemini_daily_quota_exhausted_until
    if _gemini_daily_quota_exhausted_until is not None:
        if time.time() < _gemini_daily_quota_exhausted_until:
            print("Gemini fallback skipped -- daily free-tier quota was exhausted "
                  "earlier this run; keeping regex result.")
            return None
        _gemini_daily_quota_exhausted_until = None  # cooldown window elapsed, try again

    from PIL import Image

    try:
        image_format = (Image.open(io.BytesIO(image_bytes)).format or "JPEG").upper()
    except Exception:
        image_format = "JPEG"
    mime_type = "image/png" if image_format == "PNG" else "image/jpeg"

    payload = json.dumps({
        "contents": [{
            "parts": [
                {"inline_data": {"mime_type": mime_type, "data": base64.b64encode(image_bytes).decode()}},
                {"text": _GEMINI_RECEIPT_PROMPT},
            ],
        }],
        "generationConfig": {
            "temperature": 0.1,
            # 2048 was too tight and silently truncated the response mid-
            # JSON on a real 10-item receipt (confirmed via the backend log:
            # "Gemini fallback failed... Expecting value: line 31 column 19"
            # -- the classic json.loads() error for a string that just
            # stops partway through, not malformed content). This model
            # spends some of its output budget on internal reasoning before
            # ever emitting the actual JSON answer, and adding a `category`
            # field to every line item (for the categorisation piggyback)
            # made each item's JSON longer too -- both eating into the same
            # budget. Raised well past what even a large receipt needs,
            # rather than tuning a fragile exact number.
            "maxOutputTokens": 8192,
            "responseMimeType": "application/json",
            "responseSchema": _GEMINI_RECEIPT_SCHEMA,
        },
    }).encode()

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json", "x-goog-api-key": GEMINI_API_KEY},
    )
    try:
        result = json.loads(_urlopen_with_retry(req, timeout=30))
        text = result["candidates"][0]["content"]["parts"][0]["text"]
        extracted = json.loads(text)
        line_items = extracted.get("line_items")
        if not isinstance(line_items, list) or not line_items:
            return None
        # Belt-and-suspenders even with the schema's enum constraint --
        # constraints on model output are strong but not absolute, and a
        # category name outside this set must not silently propagate to
        # category_result_for() and fail its own Supabase lookup later.
        _valid_categories = {
            "Food & Dining", "Transport", "Shopping",
            "Entertainment", "Health", "Utilities", "Others",
        }
        clean_items = []
        for it in line_items:
            name = str(it.get("item_name", "")).strip()
            price = it.get("price")
            # len(name) < 2 rejects single-character placeholders (e.g. "Y")
            # that the model occasionally emits on a hard-to-read photo
            # (stained/creased paper, glare) instead of a real item name --
            # confirmed on a real receipt where this fired inconsistently
            # from one attempt to the next on the same image. A genuine
            # printed item name is never one character, so this can't
            # reject a real item, only a hallucinated placeholder.
            if not name or len(name) < 2 or not isinstance(price, (int, float)) or price <= 0:
                continue
            qty = it.get("quantity")
            category = it.get("category")
            clean_items.append({
                "item_name": name,
                "price": float(price),
                "quantity": int(qty) if isinstance(qty, (int, float)) and qty >= 1 else 1,
                "category_name": category if category in _valid_categories else None,
            })
        if not clean_items:
            return None

        # Same placeholder guard for vendor_name -- caller does
        # `fallback.get("vendor_name") or parsed["vendor_name"]`, so
        # returning None here (instead of a garbage "Y") correctly makes it
        # fall through to the regex parser's own vendor guess rather than
        # overwriting a plausible answer with an implausible one.
        vendor_name = extracted.get("vendor_name")
        if isinstance(vendor_name, str):
            vendor_name = vendor_name.strip()
        if not vendor_name or len(vendor_name) < 2:
            vendor_name = None

        print(f"===== GEMINI FALLBACK: {len(clean_items)} item(s) extracted =====")
        return {
            "vendor_name": vendor_name,
            "date": extracted.get("date"),
            "total": extracted.get("total"),
            "line_items": clean_items,
        }
    except Exception as e:
        print(f"Gemini fallback failed, keeping regex result: {e}")
        return None


# ─── Orchestration: runs all stages ─────────────────────────────────────────
def process_receipt(filename: str, file_size_bytes: int, image_bytes: bytes) -> dict:
    validate_image(filename, file_size_bytes)

    # FR 4.2: convert PDF to a raster image before sending to Vision API
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if extension == "pdf":
        image_bytes = _pdf_to_image_bytes(image_bytes)
    else:
        image_bytes = _normalize_orientation(image_bytes)

    raw_text = extract_text(image_bytes)

    # Checked before anything else (and before the Gemini fallback call, so
    # an obvious non-receipt doesn't waste one of the scarce daily quota
    # calls on it): a real purchase receipt never prints bracketed reference
    # ranges next to its numbers, so seeing that pattern is conclusive on
    # its own regardless of what the regex parser below manages to guess for
    # a date/amount/items from the surrounding text. See
    # _looks_like_non_receipt_report's own docstring for the real case (a
    # gym body-composition scan) this closes off.
    if _looks_like_non_receipt_report(raw_text):
        raise OcrExtractionError(
            "This looks like a report or document, not a purchase receipt. "
            "Please retake the photo or choose a clearer image."
        )

    parsed = parse_receipt_fields(raw_text)

    # Hybrid extraction, step 2: regex already ran above (fast, free, handles
    # the common case). If it looks unreliable, fall back to Gemini reading
    # the actual photo — see _gemini_fallback_extract's own docstring for why
    # that's the photo and not the OCR text. Checked BEFORE the "not a
    # receipt" rejection below (not after) so a receipt regex found zero
    # items on — including because it found no date either — still gets a
    # chance at Gemini rescuing it; a genuinely non-receipt photo just costs
    # one harmless wasted call (_gemini_fallback_extract returns None when
    # it can't find real items either) and still gets correctly rejected.
    extraction_method = "regex"
    if parsed["items_confidence"] == "low":
        fallback = _gemini_fallback_extract(image_bytes)
        if fallback and fallback.get("line_items"):
            parsed["vendor_name"] = fallback.get("vendor_name") or parsed["vendor_name"]
            parsed["amount"] = fallback.get("total") or parsed["amount"]
            fallback_date = fallback.get("date")
            if fallback_date:
                try:
                    parsed["_date_obj"] = datetime.strptime(fallback_date, "%Y-%m-%d").date()
                    parsed["date"] = parsed["_date_obj"].isoformat()
                except ValueError:
                    pass  # unparseable — keep regex's own date, if any
            parsed["line_items"] = fallback["line_items"]
            parsed["items_confidence"] = items_confidence(parsed["line_items"], parsed["amount"])
            extraction_method = "gemini_fallback"

    # A single-letter placeholder name (e.g. "Y") on a hard-to-read receipt --
    # previously only guarded against on the Gemini-fallback path (see
    # TestGeminiFallbackPlausibilityGuard), but confirmed on a real stained/
    # creased receipt (TOMO VISION SETAPAK) to also come out of the plain
    # REGEX path on its own, with no guard at all: vendor_name AND the item
    # name both came back as bare "Y", and since the single item's price
    # happened to exactly equal the total, the sum-ratio check in
    # items_confidence read that as "high" -- confidently wrong, with no
    # warning shown, on a receipt that plainly needed one. Applied here
    # regardless of which path (regex or Gemini) produced the final result,
    # since either can hit the same illegible pixels. Never drops the
    # item/price itself (still useful, editable data) -- only clears an
    # implausible vendor name and forces low confidence so the warning
    # banner reliably surfaces instead of silently trusting a coincidence.
    if parsed["vendor_name"] and len(parsed["vendor_name"].strip()) < 2:
        parsed["vendor_name"] = None
    if any(len(it["item_name"].strip()) < 2 for it in parsed["line_items"]):
        parsed["items_confidence"] = "low"

    # Vision succeeds at "finding text" on ANY text-heavy photo — a
    # screenshot of an unrelated app screen, a document, a poster — not just
    # actual receipts, so a clean OCR pass alone doesn't mean this was a
    # receipt. Every genuine receipt in testing always yields at least a
    # date (Malaysian receipts always print one) or a line item; a photo
    # with neither is almost certainly not a receipt at all rather than just
    # a hard-to-read one, so it's rejected here instead of silently handing
    # back a plausible-looking but meaningless result (e.g. a stray "RM
    # 12.50" from unrelated UI text getting treated as the total).
    #
    # A date alone is deliberately NOT enough on its own anymore -- plenty
    # of non-receipt documents print a date too (forms, reports, printouts).
    # It must be corroborated by either real extracted line items, or a
    # total actually anchored to a "Total"/"Amount Due"-style keyword
    # (_find_reliable_total) rather than _extract_amount's own blind
    # "largest 2-decimal number anywhere" fallback, which can and did latch
    # onto an unrelated measurement on a non-receipt document.
    has_items = bool(parsed["line_items"])
    has_reliable_total = _find_reliable_total(raw_text) is not None
    if not has_items and not (parsed["date"] is not None and has_reliable_total):
        raise OcrExtractionError(
            "This doesn't look like a receipt — no date or items were "
            "found. Please retake the photo or choose a clearer image."
        )

    receipt_date = parsed.pop("_date_obj") or date.today()
    warranty_info = detect_warranty(raw_text, receipt_date)

    # FR 4.8: assign a category to each line item based on its description.
    # A Gemini-sourced item may already carry its own category suggestion
    # (see _gemini_fallback_extract) -- prefer that over re-running the
    # keyword matcher on the same name, since Gemini already read the item
    # in context and its language understanding covers cases (obscure menu
    # dish names, etc.) the rule-based matcher structurally can't. Regex-
    # sourced items never have this key at all, so .get() naturally falls
    # through to the keyword matcher for them, unchanged from before.
    line_items_with_categories = [
        {
            "item_name": item["item_name"],
            "price": item["price"],
            "quantity": item["quantity"],
            "category_id": (cat := (
                category_result_for(item["category_name"])
                if item.get("category_name")
                else categorise_text(item["item_name"])
            ))["category_id"],
            "category_name": cat["category_name"],
        }
        for item in parsed["line_items"]
    ]

    # Receipt-level category: prefer majority category from line items over vendor name
    if line_items_with_categories:
        item_cats = [i["category_name"] for i in line_items_with_categories
                     if i["category_name"] != "Others"]
        if item_cats:
            majority = majority_category(item_cats)
            receipt_category = category_result_for(majority)
        else:
            receipt_category = categorise_text(parsed["vendor_name"] or "")
    else:
        receipt_category = categorise_text(parsed["vendor_name"] or "")

    return {
        "vendor_name": parsed["vendor_name"],
        "amount": parsed["amount"],                     # FR 4.10: receipt total summary
        "date": parsed["date"],
        "raw_text": raw_text.replace(_PRICE_COLUMN_BOUNDARY, ""),
        "line_items": line_items_with_categories,       # FR 4.6, 4.7, 4.8, 4.9
        "suggested_category_id": receipt_category["category_id"],
        "suggested_category_name": receipt_category["category_name"],
        "suggested_category_confidence": receipt_category["confidence"],
        "date_confidence": "high" if parsed["date"] else "low",
        "items_confidence": parsed["items_confidence"],
        "extraction_method": extraction_method,          # "regex" | "gemini_fallback"
        "warranty": warranty_info,
    }

"""
Voice-Assisted Expense Categorisation Pipeline — Stage 3/4 (FYP report
Chapter 3.1.3, Module 5.0).

Takes the transcript produced by `whisper_service.transcribe_audio()` (Stage
2 — WhisperAI API) and parses it into the same structured shape
`ocr_service.process_receipt()` returns, so the Flutter app can feed either
result into the same ReceiptReviewScreen for confirmation and save.

This is a rule-based (regex + keyword) parser, not free-form NLP — it handles
a range of short spoken-expense phrasings by extracting the amount first and
working with whatever text is left, rather than requiring one fixed sentence
shape. Confirmed against:
  "I spent RM 25 on lunch at KFC"
  "RM 12.50 for Grab to KLCC today"
  "Bought groceries at Aeon, RM 68"
  "15 ringgit chicken rice"
  "80 dollars on clothes"
"""

import re
from datetime import date, timedelta

from services.categorisation_service import categorise_text, category_result_for

# "RM 25", "RM25.00", or a bare number followed by a currency word. "dollars"/
# "bucks" are accepted as colloquial stand-ins for ringgit, and so are the
# Malaysian-Chinese terms "块" (kuai, colloquial "dollar") and "令吉" (the
# actual Chinese transliteration of "ringgit" — "零吉" is also accepted since
# it's a plausible speech-to-text mishearing of the same word) — this is a
# Malaysian-Ringgit-only app, so any spoken currency word is treated as RM
# rather than actually converting currencies.
_AMOUNT_PATTERN = re.compile(
    r"RM\s*(\d+(?:\.\d{1,2})?)"
    r"|(\d+(?:\.\d{1,2})?)\s*(?:ringgit|rm|dollars?|bucks?|块|令吉|零吉)\b",
    re.IGNORECASE,
)

# Chinese colloquial money shorthand: "9块9" spoken aloud means "9 kuai 9"
# (9 yuan/dollars + 9 jiao/10-cent units) = RM 9.90 — a trailing 1-2 digit
# number directly after "块" is a decimal shorthand, not a separate whole
# number, and is a completely different meaning from a bare "9块" alone
# (just "9 dollars", handled by _AMOUNT_PATTERN above). Checked first in
# _extract_amount since _AMOUNT_PATTERN's plain "number + currency word"
# alternative can't parse this shape at all — the trailing digit breaks its
# required word boundary immediately after "块".
_CHINESE_KUAI_DECIMAL = re.compile(r"(\d+)块(\d{1,2})\b")

# Last-resort fallback when no currency word is spoken at all (e.g. "movie
# tickets 45") — just the first bare number in the sentence. Trades off
# against misreading an unrelated number (a date, a quantity) as the amount,
# but for a short spoken-expense phrase that's an acceptable trade for
# covering the common case of a dropped currency word.
_BARE_NUMBER_PATTERN = re.compile(r"\b(\d+(?:\.\d{1,2})?)\b")

# "... for Grab to KLCC" — the vendor sits between "for" and "to" when the
# phrase describes a trip/destination rather than a place purchased at.
_VENDOR_TO_PATTERN = re.compile(r"\bfor\s+([A-Za-z][\w'&]*)\s+to\b", re.IGNORECASE)

# "... at KFC", "... at Aeon," — the common case: vendor follows "at".
_VENDOR_AT_PATTERN = re.compile(
    r"\bat\s+([A-Za-z][\w'&]*(?:\s+[A-Za-z][\w'&]*){0,2})", re.IGNORECASE
)

# Connector/filler words stripped out when deriving the item description from
# whatever text is left after the amount and vendor have been removed — e.g.
# "I spent  on lunch at " (KFC already removed) -> "lunch".
_FILLER_WORDS = re.compile(
    r"\b(?:i|spent|bought|on|for|at|to|today|yesterday)\b", re.IGNORECASE
)

# Known merchant/brand names — the fallback for phrasings with no "at X" or
# "for X to Y" structure to signal a vendor (e.g. "RM 30 on Nando's"). Without
# this, the parser has no way to tell a proper-noun brand name apart from a
# generic food/item word ("Nando's" vs "fried chicken") — a rule-based parser
# has no world knowledge, so this gazetteer *is* that knowledge, scoped to
# common Malaysian chains. A word not in this list is treated as a plain item
# description instead, which is the correct behaviour for "5 ringgit fried
# chicken" (no vendor was named at all, so none should be invented).
_KNOWN_VENDORS = {
    "kfc": "KFC",
    "mcdonald's": "McDonald's", "mcdonalds": "McDonald's",
    "nando's": "Nando's", "nandos": "Nando's",
    "starbucks": "Starbucks",
    "grab": "Grab",
    "shell": "Shell",
    "petronas": "Petronas",
    "caltex": "Caltex",
    "aeon": "Aeon",
    "mydin": "Mydin",
    "uniqlo": "Uniqlo",
    "shopee": "Shopee",
    "lazada": "Lazada",
    "netflix": "Netflix",
    "spotify": "Spotify",
    "gsc": "GSC",
    "tgv": "TGV",
    "watson": "Watsons", "watsons": "Watsons",
    "guardian": "Guardian",
    "domino's": "Domino's", "dominos": "Domino's",
    "subway": "Subway",
    "wingstop": "Wingstop",
    "texas chicken": "Texas Chicken",
    "chili's": "Chili's", "chilis": "Chili's",
    "coffee bean": "Coffee Bean",
    "old town": "OldTown",
    "tealive": "Tealive",
    "chagee": "Chagee",
    "familymart": "FamilyMart",
    "7-eleven": "7-Eleven", "seven eleven": "7-Eleven",
    "boost": "Boost Juice",
    "secret recipe": "Secret Recipe",
    "sushi king": "Sushi King",
    "marrybrown": "Marrybrown",
}

_YESTERDAY_PATTERN = re.compile(r"\byesterday\b", re.IGNORECASE)

# Splits a transcript describing MULTIPLE separate expenses in one recording
# (e.g. "Water, RM 4. Mamak, RM 9. Football jersey, RM 200.") into individual
# segments, each parsed as its own line item — mirroring how
# ocr_service.process_receipt() handles a multi-item receipt, just from
# spoken sentences instead of printed rows. A transcript describing only one
# expense (the common case, e.g. "I spent RM 25 on lunch at KFC" — no
# sentence-ending punctuation at all) naturally comes back as a single
# segment and is parsed exactly as before this multi-item support existed.
# A "." is only treated as a sentence end when NOT immediately followed by a
# digit — otherwise it would also split the decimal point inside an amount
# like "RM 12.50" into two fake segments ("RM 12" / "50 for Grab...").
_SENTENCE_SPLIT = re.compile(r"\.(?!\d)|[!?]")


def _split_segments(text: str) -> list[str]:
    """Splits a transcript into individual spoken-expense segments — first
    on sentence-ending punctuation, then (only within a sentence that itself
    contains MORE THAN ONE amount) on commas too. A comma alone is
    ambiguous: it can separate a description from its OWN amount within a
    single expense ("Bought groceries at Aeon, RM 68" — one amount total,
    must NOT split there), or it can join two complete item+amount pairs
    spoken as one sentence (e.g. Chinese "鸡饭 9块9,炒饭 15令吉" — two
    amounts, must split). Counting amounts first disambiguates the two.
    """
    segments = []
    for sentence in _SENTENCE_SPLIT.split(text):
        sentence = sentence.strip(" ,")
        if not sentence:
            continue
        amount_count = (
            len(_CHINESE_KUAI_DECIMAL.findall(sentence))
            + len(_AMOUNT_PATTERN.findall(sentence))
        )
        if amount_count >= 2:
            segments.extend(
                part.strip(" ,") for part in sentence.split(",") if part.strip(" ,")
            )
        else:
            segments.append(sentence)
    return segments


class VoiceParseError(Exception):
    """Raised when the transcript is empty or has no usable amount."""
    pass


def _extract_amount(text: str) -> tuple[float | None, tuple[int, int] | None]:
    """Returns (amount, span) so the caller can strip the matched words
    (number + currency) out of the text before deriving a description."""
    m = _CHINESE_KUAI_DECIMAL.search(text)
    if m:
        whole, cents = m.group(1), m.group(2)
        if len(cents) == 1:
            cents += "0"
        return float(f"{whole}.{cents}"), m.span()
    m = _AMOUNT_PATTERN.search(text)
    if m:
        raw = m.group(1) or m.group(2)
        return float(raw), m.span()
    m = _BARE_NUMBER_PATTERN.search(text)
    if m:
        return float(m.group(1)), m.span()
    return None, None


def _extract_vendor(text: str) -> tuple[str, str] | None:
    """Returns (as-spoken text, canonical display name) — see
    _match_known_vendor for why both forms matter: the as-spoken one is what
    must be stripped out of the remainder to derive the item description,
    while the canonical one (when the name is a recognised brand, e.g.
    transcribed "Nandos" -> "Nando's") is what gets displayed/stored."""
    m = _VENDOR_TO_PATTERN.search(text)
    if not m:
        m = _VENDOR_AT_PATTERN.search(text)
    if not m:
        return None
    name = m.group(1).strip().rstrip(",.")
    return name, _KNOWN_VENDORS.get(name.lower(), name)


def _match_known_vendor(text: str) -> tuple[str, str] | None:
    """Returns (as-spoken text, canonical display name) for the first known
    brand name found, longest name first so "texas chicken" wins over any
    shorter accidental overlap. As-spoken text is what actually needs
    stripping out of the remainder to derive the item description — it may
    differ from the canonical name (e.g. transcribed "Nandos" vs "Nando's")."""
    normalized = text.lower()
    for key in sorted(_KNOWN_VENDORS, key=len, reverse=True):
        m = re.search(rf"\b{re.escape(key)}\b", normalized)
        if m:
            return text[m.start():m.end()], _KNOWN_VENDORS[key]
    return None


def _extract_description(remainder: str, vendor: str | None) -> str | None:
    text = remainder
    if vendor:
        text = re.sub(re.escape(vendor), "", text, flags=re.IGNORECASE)
    text = _FILLER_WORDS.sub("", text)
    text = re.sub(r"[,\s]+", " ", text).strip(" ,.")
    return text or None


def _extract_date(text: str) -> tuple[date, bool]:
    """Returns (date, was_explicit) — was_explicit is False when no date
    phrase was spoken and today's date is just the fallback default."""
    if _YESTERDAY_PATTERN.search(text):
        return date.today() - timedelta(days=1), True
    return date.today(), False


def _parse_segment(text: str) -> dict | None:
    """Parses ONE spoken expense statement (a single sentence/segment) into
    its line-item fields. Returns None if it carries no recognisable amount
    at all, so a stray filler segment (e.g. an empty string left behind by
    the sentence split) doesn't turn into a bogus zero-price item."""
    amount, amount_span = _extract_amount(text)
    if amount is None:
        return None
    remainder = text[:amount_span[0]] + text[amount_span[1]:]
    found = _extract_vendor(text) or _match_known_vendor(remainder)
    vendor_raw, vendor = found if found else (None, None)
    description = _extract_description(remainder, vendor_raw) or vendor or text.strip()
    # Categorise off the combined description + vendor, same as OCR's
    # "vendor/item text" matching — e.g. "Grab" alone hits the Transport
    # keyword even when the spoken description was just "Grab" itself.
    category = categorise_text(f"{description} {vendor or ''}".strip())
    return {
        "vendor": vendor,
        "amount": amount,
        "item_name": description,
        "category_id": category["category_id"],
        "category_name": category["category_name"],
    }


def parse_voice_expense(transcript: str) -> dict:
    text = transcript.strip()
    if not text:
        raise VoiceParseError("Empty transcript — nothing to parse.")

    segments = _split_segments(text)
    parsed = [p for s in (segments or [text]) if (p := _parse_segment(s)) is not None]

    if not parsed:
        # No segment carried a recognisable amount on its own — fall back to
        # a single bare-number scan across the WHOLE transcript, the same
        # last-resort behaviour this parser always had before multi-item
        # support existed (covers an amount only findable by looking past a
        # sentence boundary the split above happened to cut through).
        single = _parse_segment(text)
        parsed = [single] if single else []

    expense_date, date_explicit = _extract_date(text)

    line_items = [
        {
            "item_name": p["item_name"],
            "price": p["amount"],
            "quantity": 1,
            "category_id": p["category_id"],
            "category_name": p["category_name"],
        }
        for p in parsed
    ]
    total_amount = sum(p["amount"] for p in parsed) if parsed else None

    # Overall vendor: the first segment that actually named one. Unlike a
    # physical receipt (always exactly one vendor for every line on it), a
    # single voice recording can describe purchases from several unrelated
    # places, so there's no single "correct" vendor to force here — left
    # blank (user fills it in) when nothing in any segment named one.
    vendor = next((p["vendor"] for p in parsed if p["vendor"]), None)

    # Overall category: majority vote across line items (excluding
    # "Others") — the same rule ocr_service.process_receipt() already
    # applies to a multi-item receipt spanning several categories, rather
    # than inventing a separate "mixed"/"Others" bucket just for voice.
    item_cats = [p["category_name"] for p in parsed if p["category_name"] != "Others"]
    if item_cats:
        majority_name = max(set(item_cats), key=item_cats.count)
        category = category_result_for(majority_name)
    elif parsed:
        category = categorise_text(f"{parsed[0]['item_name']} {vendor or ''}".strip())
    else:
        category = categorise_text("")

    return {
        "vendor_name": vendor,
        "amount": total_amount,
        "date": expense_date.isoformat(),
        "raw_text": transcript,
        "line_items": line_items,
        "suggested_category_id": category["category_id"],
        "suggested_category_name": category["category_name"],
        "suggested_category_confidence": category["confidence"],
        "date_confidence": "high" if date_explicit else "low",
        "warranty": None,
    }

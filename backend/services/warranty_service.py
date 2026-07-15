"""
Warranty detection and validity assessment — Stage 4 & 5 of the OCR pipeline
(per FYP report Chapter 3.1.2 and Algorithm 1 in Chapter 4.8.1).

Scans OCR raw text for warranty-related keywords, extracts the duration
(numerical e.g. "3 MONTHS WARRANTY" or descriptive e.g. "ONE MONTH WARRANTY"),
then computes a green/yellow/red validity status based on the receipt date.
"""

import re
from datetime import date

# "wrty" covers the common Malaysian electronics-retail abbreviation, e.g.
# "*5-Yrs LTD Wrty*" printed inline in an item description rather than as its
# own labelled line.
WARRANTY_KEYWORDS = ["warranty", "guarantee", "valid until", "expiry date", "wrty"]

# Descriptive duration words -> number of months
WORD_TO_MONTHS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

# Matches things like "3 MONTHS WARRANTY", "12 MONTH WARRANTY", "1 YEAR WARRANTY",
# and abbreviated forms like "5-Yrs LTD Wrty" or "3Mth Warranty" — a hyphen (or no
# separator at all) is tolerated between the number and unit, not just whitespace,
# and "yr(s)"/"mth(s)" are accepted alongside the full "year(s)"/"month(s)" words.
NUMERIC_DURATION_PATTERN = re.compile(
    r"(\d+)[\s-]*(month|months|mth|mths|year|years|yr|yrs)\b", re.IGNORECASE
)

# Matches things like "ONE MONTH WARRANTY", "TWO YEARS WARRANTY"
DESCRIPTIVE_DURATION_PATTERN = re.compile(
    r"\b("
    + "|".join(WORD_TO_MONTHS.keys())
    + r")[\s-]*(month|months|mth|mths|year|years|yr|yrs)\b",
    re.IGNORECASE,
)


def detect_warranty(raw_text: str, receipt_date: date) -> dict | None:
    """
    Scans raw OCR text for warranty info. Returns None if no warranty keyword found.

    Returns:
        {
            "has_warranty": True,
            "duration_months": int,
            "expiry_date": "YYYY-MM-DD",
            "status": "green" | "yellow" | "red",
            "days_remaining": int
        }
    """
    normalised = raw_text.lower()

    if not any(keyword in normalised for keyword in WARRANTY_KEYWORDS):
        return None

    duration_months = _extract_duration_months(normalised)
    if duration_months is None:
        # Warranty keyword present but no parsable duration — flag for manual review
        return {
            "has_warranty": True,
            "duration_months": None,
            "expiry_date": None,
            "status": "unknown",
            "days_remaining": None,
        }

    try:
        expiry_date = _add_months(receipt_date, duration_months)
    except ValueError:
        # Belt-and-suspenders: the _MAX_PLAUSIBLE_MONTHS cap above should
        # already rule this out, but a receipt_date close to date.max could
        # still overflow — fail gracefully instead of crashing the request.
        return {
            "has_warranty": True,
            "duration_months": duration_months,
            "expiry_date": None,
            "status": "unknown",
            "days_remaining": None,
        }
    status, days_remaining = _compute_status(expiry_date)

    return {
        "has_warranty": True,
        "duration_months": duration_months,
        "expiry_date": expiry_date.isoformat(),
        "status": status,
        "days_remaining": days_remaining,
    }


def _is_year_unit(unit: str) -> bool:
    return unit.lower() in ("year", "years", "yr", "yrs")


# No real product warranty runs longer than this. Garbled OCR text can make
# an unrelated number (a serial number, invoice number, etc.) land right next
# to a duration unit word and get misread as the duration itself — without a
# cap, a large enough bogus value (e.g. "15502" misread as "15502 yrs") turns
# into an equally bogus expiry date whose year overflows Python's date()
# constructor (valid range 1-9999), crashing the whole request instead of
# just leaving the duration unparsed.
_MAX_PLAUSIBLE_MONTHS = 1200  # 100 years


def _extract_duration_months(normalised_text: str) -> int | None:
    # Try numerical first, e.g. "3 months warranty"
    match = NUMERIC_DURATION_PATTERN.search(normalised_text)
    if match:
        value, unit = int(match.group(1)), match.group(2)
        months = value * 12 if _is_year_unit(unit) else value
        if months <= _MAX_PLAUSIBLE_MONTHS:
            return months

    # Fall back to descriptive, e.g. "one month warranty"
    match = DESCRIPTIVE_DURATION_PATTERN.search(normalised_text)
    if match:
        word, unit = match.group(1).lower(), match.group(2)
        value = WORD_TO_MONTHS.get(word)
        if value is not None:
            months = value * 12 if _is_year_unit(unit) else value
            if months <= _MAX_PLAUSIBLE_MONTHS:
                return months

    return None


def _add_months(start_date: date, months: int) -> date:
    month_index = start_date.month - 1 + months
    year = start_date.year + month_index // 12
    month = month_index % 12 + 1
    # Clamp day to avoid invalid dates (e.g. Jan 31 + 1 month)
    day = min(start_date.day, 28)
    return date(year, month, day)


def _compute_status(expiry_date: date) -> tuple[str, int]:
    today = date.today()
    days_remaining = (expiry_date - today).days

    if days_remaining < 0:
        return "red", days_remaining
    elif days_remaining <= 30:
        return "yellow", days_remaining
    else:
        return "green", days_remaining

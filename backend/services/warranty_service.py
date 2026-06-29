"""
Warranty detection and validity assessment — Stage 4 & 5 of the OCR pipeline
(per FYP report Chapter 3.1.2 and Algorithm 1 in Chapter 4.8.1).

Scans OCR raw text for warranty-related keywords, extracts the duration
(numerical e.g. "3 MONTHS WARRANTY" or descriptive e.g. "ONE MONTH WARRANTY"),
then computes a green/yellow/red validity status based on the receipt date.
"""

import re
from datetime import date

WARRANTY_KEYWORDS = ["warranty", "guarantee", "valid until", "expiry date"]

# Descriptive duration words -> number of months
WORD_TO_MONTHS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

# Matches things like "3 MONTHS WARRANTY", "12 MONTH WARRANTY", "1 YEAR WARRANTY"
NUMERIC_DURATION_PATTERN = re.compile(
    r"(\d+)\s*(month|months|year|years)\b", re.IGNORECASE
)

# Matches things like "ONE MONTH WARRANTY", "TWO YEARS WARRANTY"
DESCRIPTIVE_DURATION_PATTERN = re.compile(
    r"\b(" + "|".join(WORD_TO_MONTHS.keys()) + r")\s*(month|months|year|years)\b",
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

    expiry_date = _add_months(receipt_date, duration_months)
    status, days_remaining = _compute_status(expiry_date)

    return {
        "has_warranty": True,
        "duration_months": duration_months,
        "expiry_date": expiry_date.isoformat(),
        "status": status,
        "days_remaining": days_remaining,
    }


def _extract_duration_months(normalised_text: str) -> int | None:
    # Try numerical first, e.g. "3 months warranty"
    match = NUMERIC_DURATION_PATTERN.search(normalised_text)
    if match:
        value, unit = int(match.group(1)), match.group(2)
        return value * 12 if "year" in unit else value

    # Fall back to descriptive, e.g. "one month warranty"
    match = DESCRIPTIVE_DURATION_PATTERN.search(normalised_text)
    if match:
        word, unit = match.group(1).lower(), match.group(2)
        value = WORD_TO_MONTHS.get(word)
        if value is not None:
            return value * 12 if "year" in unit else value

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

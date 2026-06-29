"""
Rule-based keyword categorisation — shared by both:
  - OCR module (matches vendor name from receipt)
  - Voice module (matches transcribed expense description)

Categories here MUST match the seeded `categories` table exactly:
Food & Dining, Transport, Shopping, Entertainment, Health, Utilities, Others
"""

from utils.supabase_client import get_category_id

# Keyword -> category name. Add more keywords as you test with real receipts/voice.
CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Food & Dining": [
        "restaurant", "cafe", "kopitiam", "mamak", "nasi", "food",
        "mcdonald", "kfc", "starbucks", "pizza", "burger", "char",
        "kopi", "makan", "lunch", "dinner", "breakfast", "bakery",
    ],
    "Transport": [
        "grab", "petrol", "shell", "petronas", "caltex", "parking",
        "toll", "lrt", "mrt", "touch n go", "touch and go", "taxi",
        "bus fare", "train", "ride",
    ],
    "Shopping": [
        "shopee", "lazada", "mall", "uniqlo", "mr diy", "watson",
        "guardian", "shopping", "store", "mart", "supermarket",
        "hypermarket", "aeon", "lotus",
    ],
    "Entertainment": [
        "cinema", "gsc", "tgv", "netflix", "spotify", "movie",
        "concert", "game", "steam", "karaoke",
    ],
    "Health": [
        "pharmacy", "clinic", "hospital", "medicine", "doctor",
        "dental", "checkup", "vitamin",
    ],
    "Utilities": [
        "tnb", "water bill", "unifi", "maxis", "celcom", "digi",
        "electric", "wifi", "internet bill", "telco", "astro",
    ],
}

DEFAULT_CATEGORY = "Others"


def categorise_text(text: str) -> dict:
    """
    Matches free text (vendor name OR transcribed voice description)
    against keyword rules and returns the matched category + its id.

    Returns:
        {
            "category_name": str,
            "category_id": str | None,   # None if not found in Supabase yet
            "matched_keyword": str | None,
            "confidence": "high" | "low"
        }
    """
    if not text:
        return _build_result(DEFAULT_CATEGORY, None, "low")

    normalised = text.lower().strip()

    for category_name, keywords in CATEGORY_KEYWORDS.items():
        for keyword in keywords:
            if keyword in normalised:
                return _build_result(category_name, keyword, "high")

    return _build_result(DEFAULT_CATEGORY, None, "low")


def _build_result(category_name: str, matched_keyword: str | None, confidence: str) -> dict:
    try:
        category_id = get_category_id(category_name)
    except RuntimeError:
        # Supabase not configured yet — still useful for local testing without DB
        category_id = None

    return {
        "category_name": category_name,
        "category_id": category_id,
        "matched_keyword": matched_keyword,
        "confidence": confidence,
    }

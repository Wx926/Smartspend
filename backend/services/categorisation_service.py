"""
Rule-based keyword categorisation — shared by both:
  - OCR module (matches vendor name from receipt)
  - Voice module (matches transcribed expense description)

Categories here MUST match the seeded `categories` table exactly:
Food & Dining, Transport, Shopping, Entertainment, Health, Utilities, Others
"""

import re

from utils.supabase_client import get_category_id

# Keyword -> category name. Add more keywords as you test with real receipts/voice.
CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Food & Dining": [
        "restaurant", "cafe", "cuisine", "kopitiam", "mamak", "nasi", "food",
        "mcdonald", "kfc", "starbucks", "pizza", "burger",
        # "char" (char kway teow, char siew) is handled via
        # WORD_BOUNDARY_KEYWORDS below since it's also a substring of
        # unrelated words like "Charges" ("Service Charges" on an invoice).
        "char",
        "kopi", "makan", "lunch", "dinner", "breakfast", "bakery",
        "teh", "tarik", "roti", "canai", "lemak", "mee", "laksa",
        "curry", "rice", "ayam", "ikan", "sup", "bihun", "kuey",
        "dim sum", "wonton", "sushi", "tom yam", "satay", "rendang",
        # Chinese-language menu/vendor terms (Malaysian Chinese-medium
        # receipts print item names with no romanisation at all, e.g.
        # "冬菇肉碎老鼠粉（小）" / "加鸡蛋" — none of the romanised keywords
        # above ever match that text).
        "鸡蛋", "老鼠粉", "冬菇", "餐厅", "茶餐厅", "小炒", "煮炒", "海鲜",
        "点心",
        # Japanese-cuisine menu terms (e.g. "Salmon Teriyaki Don")
        "salmon", "teriyaki", "teryaki", "sashimi", "tempura", "udon",
        "ramen", "bento", "katsu", "yakitori", "onigiri",
        # Meat/seafood menu terms not already covered by "ayam"/"ikan"/
        # "chicken" above (e.g. "Smoked Duck Don"). "crab" is handled via
        # WORD_BOUNDARY_KEYWORDS below since it's also a substring of
        # unrelated words like "scrabble".
        "duck", "beef", "pork", "mutton", "lamb", "prawn", "squid", "crab",
        # F&B chain brand names (same pattern as mcdonald/kfc/starbucks above)
        "nando", "chic", "chicken", "grill", "chargrill", "coleslaw",
        "wingstop", "subway", "domino", "texas chicken",
        # Groceries & everyday food/drink items (so a receipt full of
        # produce/snacks correctly out-votes a generic "mart"/"store"
        # vendor name during majority-category selection).
        "banana", "apple", "orange", "grape", "mango", "avocado",
        "fruit", "vegetable", "tomato", "onion", "potato", "salami",
        "cheese", "milk", "egg", "bread", "cereal", "yogurt", "butter",
        "snack", "chip", "biscuit", "cookie", "chocolate", "candy",
        "coffee", "frap", "frappe", "frappuccino", "latte", "mocha",
        "cappuccino", "espresso", "juice", "soda", "beverage", "drink",
        "grocery", "groceries",
    ],
    "Transport": [
        "grab", "petrol", "shell", "petronas", "caltex", "parking",
        "toll", "lrt", "mrt", "touch n go", "touch and go", "taxi",
        "bus fare", "train", "ride",
    ],
    "Shopping": [
        # Clothing, accessories, and general retail/apparel — NOT grocery
        # stores/supermarkets, which are matched by item content instead
        # (a "mart" sells both food and non-food, so its name alone isn't
        # a reliable signal — see Food & Dining's grocery keywords above).
        "shopee", "lazada", "mall", "uniqlo", "shopping",
        "shoe", "shoes", "footwear", "boot", "boots", "sneaker",
        "sneakers", "sandal", "apparel", "clothing", "clothes", "fashion",
        "garment", "scarf", "hat", "cap", "sock", "socks", "bag",
        "handbag", "wallet", "jewellery", "jewelry", "accessory",
        "accessories",
    ],
    "Entertainment": [
        "cinema", "gsc", "tgv", "netflix", "spotify", "movie",
        "concert", "game", "steam", "karaoke",
    ],
    "Health": [
        "pharmacy", "clinic", "hospital", "medicine", "doctor",
        "dental", "checkup", "vitamin", "watson", "guardian",
    ],
    "Utilities": [
        "tnb", "water bill", "unifi", "maxis", "celcom", "digi",
        "electric", "wifi", "internet bill", "telco", "astro",
    ],
}

# Keywords matched as a whole word only, not a substring — most keywords above
# are deliberately matched as substrings so glued menu abbreviations like
# "GrilChicBgr" still hit "chic"/"grill", but a few short common keywords are
# also plain English word fragments that show up constantly inside unrelated
# receipt text (e.g. "mall" inside the size "Small" — "Small Cone"/"Small
# Fries" would otherwise be miscategorised as Shopping on almost every fast-
# food receipt) and must require real word boundaries instead.
WORD_BOUNDARY_KEYWORDS = {"mall", "crab", "char"}

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
            if keyword in WORD_BOUNDARY_KEYWORDS:
                matched = re.search(rf"\b{re.escape(keyword)}\b", normalised)
            else:
                matched = keyword in normalised
            if matched:
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

"""Unit tests for backend/services/categorisation_service.py."""
from services.categorisation_service import categorise_text, majority_category


class TestKeywordMatching:
    def test_grocery_abbreviations(self):
        cases = {
            "18CT EGGS": "Food & Dining",
            "GRAPE TOMATO": "Food & Dining",
            "CHPD ONION": "Food & Dining",
        }
        for item_name, expected in cases.items():
            assert categorise_text(item_name)["category_name"] == expected

    def test_confirmed_gaps_still_others(self):
        """Documents current known gaps -- abbreviated/glued grocery names
        with no matching keyword. Not a defect, just the honest ceiling of
        pure keyword matching; these fall back to manual category
        correction in the UI."""
        cases = ["FF BS BREAST", "KS DICED TOM", "JACKORGSALSA", "MONT JACK 2 #"]
        for item_name in cases:
            assert categorise_text(item_name)["category_name"] == "Others"

    def test_oden_and_tom_yum_spelling_variant(self):
        """"tom yam" and "tom yum" are both common transliterations of the
        same dish -- both spellings must independently match, since
        substring matching means neither implies the other."""
        assert categorise_text("Oden Set")["category_name"] == "Food & Dining"
        assert categorise_text("Tom Yum XL White Fish")["category_name"] == "Food & Dining"
        assert categorise_text("Tom Yam Soup")["category_name"] == "Food & Dining"

    def test_underwear_is_shopping_not_food(self):
        assert categorise_text("ALAIN DELON BRIEF -")["category_name"] == "Shopping"

    def test_department_store_vendor_names(self):
        assert categorise_text("PARKSON DEPT STORE")["category_name"] == "Shopping"

    def test_aeon_deliberately_not_a_shopping_keyword(self):
        """AEON is primarily a grocery hypermarket -- unlike Parkson/Isetan,
        it must NOT be a blanket Shopping keyword, or a routine grocery
        run there would get mislabeled. Relies on item-content matching
        instead, same as any other "mart"-style mixed-use store."""
        result = categorise_text("AEON SUPERMARKET")
        assert result["category_name"] != "Shopping"

    def test_empty_text_is_low_confidence_others(self):
        result = categorise_text("")
        assert result["category_name"] == "Others"
        assert result["confidence"] == "low"


class TestMajorityCategory:
    def test_clear_majority_wins(self):
        assert majority_category(
            ["Food & Dining", "Food & Dining", "Entertainment"]
        ) == "Food & Dining"

    def test_tie_is_deterministic(self):
        """Regression guard for a real non-determinism bug: the original
        implementation (`max(set(item_cats), key=item_cats.count)`) relied
        on Python's per-process-randomised set iteration order to break
        ties, so the exact same tied input returned a DIFFERENT category
        across separate process runs (confirmed directly: 3 runs, 3
        different answers). Must now always resolve to the same category,
        deterministically, regardless of process/restart."""
        tied_input = ["Food & Dining", "Entertainment", "Shopping"]
        results = {majority_category(list(tied_input)) for _ in range(20)}
        assert len(results) == 1, f"tie-break was non-deterministic: got {results}"

    def test_tie_break_priority_order(self):
        """The deterministic tie-break follows CATEGORY_KEYWORDS' own
        declared order (Food & Dining first)."""
        assert majority_category(["Entertainment", "Shopping", "Food & Dining"]) == "Food & Dining"
        assert majority_category(["Utilities", "Transport"]) == "Transport"

    def test_empty_list_returns_none(self):
        assert majority_category([]) is None

    def test_single_category(self):
        assert majority_category(["Health"]) == "Health"

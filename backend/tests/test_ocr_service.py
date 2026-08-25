"""
Unit tests for backend/services/ocr_service.py.

These are regression guards for real bugs found and fixed against real
receipt photos during development (see each test's docstring for the
specific case) -- not synthetic edge cases invented for coverage's sake.
Run with: pytest (from the backend/ directory).
"""
from datetime import date

from services.ocr_service import (
    parse_receipt_fields,
    items_confidence,
    _extract_line_items,
    _extract_vendor,
)


class TestDateExtraction:
    def test_yyyy_mm_dd_not_misread_as_dd_mm_yy(self):
        """"2018-03-23" contains "18-03-23" as a substring, which the
        DD-MM-YY pattern happily matched on its own before boundary guards
        were added -- misreading a real 2018 date as one in 2023."""
        text = "SOME STORE\nDate: 2018-03-23\nTOTAL 12.00"
        result = parse_receipt_fields(text)
        assert result["date"] == "2018-03-23"

    def test_genuine_dd_mm_yy_still_parses(self):
        text = "SOME STORE\nDate: 27-06-26\nTOTAL 12.00"
        result = parse_receipt_fields(text)
        assert result["date"] == "2026-06-27"


class TestLineItemExtraction:
    def test_ted_heng_numbers_row_then_bulleted_name(self):
        """Malaysian tax-invoice layout: barcode+qty+price row, item's own
        description on a separate bulleted line below it."""
        raw = (
            "TED HENG HARDWARE\n"
            "NO 12 JALAN SS2/24, PETALING JAYA\n"
            "TEL: 03-1234 5678\n"
            "QTY ITEM DESCRIPTION TOTAL\n"
            "9557546953990 2 5.50 0.00 11.00*\n"
            "-STAINLESS STEEL SCREW\n"
            "9557546953991 1 3.20 0.00 3.20*\n"
            "-ALUMINIUM BRACKET\n"
            "SUBTOTAL 14.20\n"
            "TOTAL 14.20\n"
        )
        items = _extract_line_items(raw)
        assert len(items) == 2
        assert items[0]["quantity"] == 2  # not defaulted to 1
        assert items[0]["price"] == 11.00
        assert "SCREW" in items[0]["item_name"].upper()
        assert items[1]["price"] == 3.20

    def test_ted_heng_misread_qty_letter_does_not_shift_prices(self):
        """A numbers-row whose qty digit was OCR-misread as a letter ("f")
        previously caused the barcode-prefix regex to wrongly fire on it,
        corrupting the row and cascading a price shift onto every item
        after it."""
        raw = (
            "TED HENG HARDWARE\n"
            "NO 12 JALAN SS2/24, PETALING JAYA\n"
            "TEL: 03-1234 5678\n"
            "QTY ITEM DESCRIPTION TOTAL\n"
            "9557369305006 f 3.96 4.09 3.80*\n"
            "-WOODEN HANDLE HAMMER\n"
            "SUBTOTAL 3.80\n"
            "TOTAL 3.80\n"
        )
        items = _extract_line_items(raw)
        assert len(items) == 1
        assert items[0]["price"] == 3.80

    def test_parkson_barcode_prefix_name_price_next_line(self):
        raw = (
            "PARKSON DEPT STORE\n"
            "438049 ALAIN DELON BRIEF -\n"
            "49.90\n"
            "SUBTOTAL 49.90\n"
            "TOTAL 49.90\n"
        )
        items = _extract_line_items(raw)
        assert len(items) == 1
        assert items[0]["price"] == 49.90


class TestVendorExtraction:
    def test_brand_disclosed_via_recurrence(self):
        """"Nando's" repeats inside "Nando's Chickenland Malaysia Sdn Bhd",
        so it must win over an unrelated ALL-CAPS tagline printed between
        the two lines."""
        lines = [
            "Nando's",
            "PERI-PERI CHICKEN",
            "Nando's Chickenland Malaysia Sdn Bhd",
            "Some Address Line, Kuala Lumpur",
        ]
        assert _extract_vendor(lines) == "Nando's"

    def test_brand_disclosed_via_position_when_no_recurrence(self):
        """"FARM TO PLATE" never repeats elsewhere on the receipt and has
        no "trading as" disclosure phrase either -- previously fell all
        the way through to the legal entity name ("MALAYSIA FOOD
        CORPORATION SDN BHD"). Fixed by preferring whichever clean
        candidate line sits immediately above the Sdn Bhd line."""
        lines = [
            "FARM TO PLATE",
            "MALAYSIA FOOD CORPORATION SDN BHD",
            "4 , JALAN SS20/10 , DAMANSARA KIM",
            "47400 PETALING JAYA , SELANGOR",
            "COMPANY REG. NO : 389252-A",
            "GUEST CHECK",
        ]
        assert _extract_vendor(lines) == "FARM TO PLATE"


class TestItemsConfidence:
    def test_tax_inflated_total_still_high(self):
        """total > items sum is normal (tax) -- must not read as broken."""
        result = items_confidence(
            [{"item_name": "A", "price": 10.00, "quantity": 1},
             {"item_name": "B", "price": 5.00, "quantity": 1}],
            amount=15.90,
        )
        assert result == "high"

    def test_discounted_total_still_high(self):
        """Real FamilyMart case: items summed to 15.80, printed TOTAL was
        14.55 after a -RM1.23 discount (ratio 1.086) -- a completely
        correct extraction that an earlier, tighter ceiling wrongly
        flagged as broken."""
        result = items_confidence(
            [{"item_name": "Burrito Wrap", "price": 15.80, "quantity": 1}],
            amount=14.55,
        )
        assert result == "high"

    def test_badly_under_extracted_total_flagged_low(self):
        result = items_confidence(
            [{"item_name": "Only one item caught", "price": 2.00, "quantity": 1}],
            amount=45.00,
        )
        assert result == "low"

    def test_moderate_overcount_flagged_low(self):
        """Regression guard for the confidence-ceiling regression: an
        earlier fix (ceiling 1.05 -> 1.5) accidentally let a ~35%
        overcount (e.g. a duplicated/phantom item) through as "high",
        which silently skipped the Gemini fallback that exists
        specifically to catch cases like this. Ceiling was corrected to
        1.2 -- tight enough to still catch this, wide enough to still
        clear the confirmed 1.086 discount case above with margin."""
        result = items_confidence(
            [{"item_name": "Real item", "price": 10.00, "quantity": 1},
             {"item_name": "Phantom duplicate", "price": 3.50, "quantity": 1}],
            amount=10.00,  # ratio 1.35
        )
        assert result == "low"

    def test_no_items_or_amount_is_low(self):
        """Voice's "Hello!" nonsense-input case: no expense content should
        never be treated as a trustworthy result just because nothing
        crashed."""
        assert items_confidence([], amount=None) == "low"

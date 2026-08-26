"""
Unit tests for backend/services/ocr_service.py.

These are regression guards for real bugs found and fixed against real
receipt photos during development (see each test's docstring for the
specific case) -- not synthetic edge cases invented for coverage's sake.
Run with: pytest (from the backend/ directory).
"""
import io
import json
from datetime import date
from unittest.mock import patch, MagicMock

import pytest

from services.ocr_service import (
    parse_receipt_fields,
    items_confidence,
    _extract_line_items,
    _extract_vendor,
    _extract_date,
    _gemini_fallback_extract,
    _looks_like_non_receipt_report,
    process_receipt,
    validate_image,
    OcrValidationError,
    OcrExtractionError,
    MAX_FILE_SIZE_MB,
)


def _tiny_png() -> bytes:
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (4, 4)).save(buf, format="PNG")
    return buf.getvalue()


class TestDateExtraction:
    def test_yyyy_mm_dd_not_misread_as_dd_mm_yy(self):
        """"2018-03-23" contains "18-03-23" as a substring, which the
        DD-MM-YY pattern happily matched on its own before boundary guards
        were added -- misreading a real 2018 date as one in 2023."""
        text = "SOME STORE\nDate: 2018-03-23\nTOTAL 12.00"
        result = parse_receipt_fields(text)
        assert result["date"] == "2018-03-23"

    def test_day_month_name_year_order(self):
        """"07 Jun 2026" (day-month-year, the convention most Malaysian
        receipts actually use) previously matched NEITHER the numeric
        DATE_PATTERNS (no month name involved) NOR _MONTH_NAME_DATE (which
        only expects the opposite, "Month Day, Year" order) -- silently
        fell through to defaulting the whole receipt to today's date, with
        no indication anything had gone wrong."""
        assert _extract_date("Order No. : ONL3191   07 Jun 2026") == date(2026, 6, 7)

    def test_day_month_name_year_with_ordinal_suffix(self):
        assert _extract_date("Receipt dated 7th Jun 2026") == date(2026, 6, 7)

    def test_month_name_day_year_order_still_works(self):
        """Regression guard: the day-month-year fix must not break the
        opposite (American) word order it coexists with."""
        assert _extract_date("Mar 30,2026") == date(2026, 3, 30)

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


class TestFileValidation:
    """Stage 1 validation (validate_image): file format and size gating,
    run before anything is sent to Vision/Gemini. Never directly exercised
    before -- this was reported as untested during manual QA, so covering
    it now rather than assuming it works from having "seemed fine" on a
    handful of real-device scans."""

    def test_accepts_png(self):
        validate_image("receipt.png", 1_000_000)  # no exception raised

    def test_accepts_jpg(self):
        validate_image("receipt.jpg", 1_000_000)

    def test_accepts_jpeg(self):
        validate_image("receipt.jpeg", 1_000_000)

    def test_accepts_pdf(self):
        validate_image("receipt.pdf", 1_000_000)

    def test_accepts_uppercase_extension(self):
        """Android gallery/camera exports sometimes use "IMG_1234.JPG" --
        the check must not be case-sensitive."""
        validate_image("IMG_1234.JPG", 1_000_000)

    def test_rejects_unsupported_format(self):
        with pytest.raises(OcrValidationError):
            validate_image("receipt.heic", 1_000_000)

    def test_rejects_missing_extension(self):
        with pytest.raises(OcrValidationError):
            validate_image("receipt", 1_000_000)

    def test_accepts_file_just_under_the_size_cap(self):
        just_under = int((MAX_FILE_SIZE_MB - 0.1) * 1024 * 1024)
        validate_image("receipt.png", just_under)

    def test_rejects_file_over_the_size_cap(self):
        """A high-resolution phone camera photo can realistically exceed
        this -- confirming the cap actually triggers, not just that the
        constant exists."""
        over = int((MAX_FILE_SIZE_MB + 1) * 1024 * 1024)
        with pytest.raises(OcrValidationError):
            validate_image("receipt.jpg", over)

    def test_zero_byte_file_passes_size_check(self):
        """A 0-byte file passes validate_image's size gate (0 <= max) --
        its real failure mode is downstream, when extract_text finds no
        usable text at all. Documenting that boundary instead of asserting
        a rejection validate_image was never meant to perform."""
        validate_image("receipt.png", 0)


def _mock_gemini_response(json_body: dict) -> MagicMock:
    """Fakes the urllib.request.urlopen(...) context manager with Gemini's
    real response shape -- candidates[0].content.parts[0].text is itself a
    JSON string, since the call sets responseMimeType: application/json."""
    outer = json.dumps({
        "candidates": [{"content": {"parts": [{"text": json.dumps(json_body)}]}}]
    }).encode()
    mock_resp = MagicMock()
    mock_resp.read.return_value = outer
    mock_resp.__enter__.return_value = mock_resp
    mock_resp.__exit__.return_value = False
    return mock_resp


class TestGeminiFallbackPlausibilityGuard:
    """Regression guard for a real, intermittently-reproducing bug: on a
    hard-to-read (stained/creased) receipt, Gemini would sometimes return a
    single-letter placeholder ("Y") for the vendor name AND the item name
    instead of failing outright. Nothing checked plausibility before this
    fix, so that garbage silently overwrote a perfectly usable regex
    extraction on some scan attempts but not others -- making the app look
    randomly broken on the exact same receipt photo."""

    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_single_letter_vendor_and_item_placeholder_rejected_entirely(self, mock_urlopen):
        mock_urlopen.return_value = _mock_gemini_response({
            "vendor_name": "Y",
            "date": "2026-07-23",
            "total": 290.0,
            "line_items": [{"item_name": "Y", "quantity": 1, "price": 290.0}],
        })
        result = _gemini_fallback_extract(b"fake-image-bytes")
        # The only item was a garbage placeholder -- nothing plausible
        # survives, so the whole fallback is treated as unusable and the
        # caller keeps the original regex result untouched.
        assert result is None

    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_bad_vendor_name_alone_does_not_discard_good_items(self, mock_urlopen):
        mock_urlopen.return_value = _mock_gemini_response({
            "vendor_name": "Y",
            "date": "2026-07-23",
            "total": 290.0,
            "line_items": [
                {"item_name": "1.56 Zeiss Blue Lens", "quantity": 2, "price": 290.0},
            ],
        })
        result = _gemini_fallback_extract(b"fake-image-bytes")
        assert result is not None
        # vendor_name is nulled out (not passed through as "Y") so the
        # caller's `fallback.get("vendor_name") or parsed["vendor_name"]`
        # falls through to the regex parser's own vendor guess instead of
        # overwriting a plausible guess with an implausible one.
        assert result["vendor_name"] is None
        assert result["line_items"][0]["item_name"] == "1.56 Zeiss Blue Lens"

    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_plausible_full_response_passes_through_unchanged(self, mock_urlopen):
        mock_urlopen.return_value = _mock_gemini_response({
            "vendor_name": "TOMO VISION SETAPAK",
            "date": "2026-07-23",
            "total": 290.0,
            "line_items": [
                {"item_name": "1.56 Zeiss Blue Lens", "quantity": 2, "price": 290.0, "category": "Shopping"},
                {"item_name": "Plastic Frame TR1360-52 C14", "quantity": 1, "price": 50.0, "category": "Shopping"},
            ],
        })
        result = _gemini_fallback_extract(b"fake-image-bytes")
        assert result["vendor_name"] == "TOMO VISION SETAPAK"
        assert len(result["line_items"]) == 2


class TestNonReceiptReportDetection:
    """_looks_like_non_receipt_report on its own -- the bracketed reference-
    range signature ("[52.9 - 64.7]", "[70%]") that gym/lab/health reports
    print next to a measured value, which a real purchase receipt never
    does."""

    def test_flags_bracketed_reference_ranges(self):
        text = (
            "1. LEAN BODY MASS KG/LBS\n"
            "59.0 / Optimal [52.9 - 64.7]\n"
            "6. BODY FAT MASS KG/LBS\n"
            "12.6 / Optimal [10.0 - 15.0]\n"
        )
        assert _looks_like_non_receipt_report(text) is True

    def test_a_single_bracket_alone_is_not_enough(self):
        """One incidental bracket (e.g. a promo code in brackets) shouldn't
        alone condemn a real receipt -- only the repeated pattern does."""
        text = "SOME STORE\n[PROMO50] applied\nTOTAL 45.00\n"
        assert _looks_like_non_receipt_report(text) is False

    def test_normal_receipt_text_not_flagged(self):
        text = "TOMO VISION SETAPAK\n23/07/2026\nTotal 290.00\nE-PAY 290.00\n"
        assert _looks_like_non_receipt_report(text) is False


class TestNonReceiptRejectionEndToEnd:
    """Regression guard for a real false-accept: Anytime Fitness's Evolt 360
    body-composition scan printout has a genuine printed date and enough
    2-decimal numbers in its measurement columns (e.g. "25.17", "8.90")
    that the old date-or-items check, combined with _extract_amount's blind
    "largest number anywhere" fallback, let it sail through to the Receipt
    Review screen as if it were a real receipt -- merchant name garbled to
    a single letter and all. process_receipt must now reject it outright."""

    @patch("services.ocr_service.extract_text")
    def test_body_scan_report_is_rejected(self, mock_extract_text):
        mock_extract_text.return_value = (
            "YOUR EVOLT 360 BODY SCAN\n"
            "DATE 16-08-2026 18:42\n"
            "NAME Zack\n"
            "1. LEAN BODY MASS KG/LBS\n"
            "59.0 / Optimal [52.9 - 64.7]\n"
            "6. BODY FAT MASS KG/LBS\n"
            "12.6 / Optimal [10.0 - 15.0]\n"
            "TORSO\n"
            "LEAN MASS 25.17 / Optimal [21.68 - 26.50]\n"
            "FAT MASS 7.12 / High [4.67 - 7.00]\n"
        )
        png = _tiny_png()
        with pytest.raises(OcrExtractionError):
            process_receipt("scan.jpg", len(png), png)

    @patch("services.ocr_service.extract_text")
    def test_real_receipt_with_date_and_reliable_total_still_accepted(self, mock_extract_text):
        """Regression guard the other way -- a genuine receipt whose regex
        extraction found a date and a real 'Total' line but no line items
        (a plausible degraded case) must NOT get caught by the tightened
        check."""
        mock_extract_text.return_value = (
            "TOMO VISION SETAPAK\n"
            "23/07/2026\n"
            "Total 290.00\n"
        )
        png = _tiny_png()
        result = process_receipt("receipt.jpg", len(png), png)
        assert result["date"] == "2026-07-23"
        assert result["amount"] == 290.0

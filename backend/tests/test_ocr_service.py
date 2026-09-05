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
    def test_clearance_markdown_line_not_extracted_as_purchased_item(self):
        """Real bug, same FamilyMart receipt as TestItemsConfidence's
        test_discounted_total_still_high: "RTE Clearance 25% Timebase
        -1.23" is a discount adjustment, not a product -- it doesn't say
        "discount" anywhere, so it fell through SKIP_KEYWORDS entirely and
        was extracted as a fake item named "RTE Clearance 25" for a
        POSITIVE 1.23 (losing the discount's negative sign too). Confirmed
        on the real app screen: 2 real items became 4, and the displayed
        total went from the correct 14.55 to a nonsensical -2.48."""
        raw = (
            "FAMILYMART\n"
            "Salted Salmon Onigiri ea 4.90\n"
            "Chicken Burrito Wrap ea 10.90\n"
            "SUBTOTAL 15.80\n"
            "RTE Clearance 25% Timebase -1.23\n"
            "ROUNDING -0.02\n"
            "TOTAL 14.55\n"
        )
        items = _extract_line_items(raw)
        assert len(items) == 2
        names = [it["item_name"].lower() for it in items]
        assert not any("clearance" in n or "subtotal" in n for n in names)
        result = parse_receipt_fields(raw)
        assert result["amount"] == 14.55
        assert result["items_confidence"] == "high"

    def test_misread_qty_header_does_not_wrongly_trigger_totals_boundary(self):
        """Real bug (HON HWA HARDWARE): Vision misread this receipt's "Qty"
        column header as "Ofy", so _ITEM_TABLE_HEADER's strict "qty"-only
        check failed to recognise "Ofy Description Price Total ( RM )" as a
        header row at all. That let _TOTALS_BOUNDARY catch the SAME line's
        own "Total ( RM )" column label instead, wrongly marking everything
        after it as past-the-totals-section before the receipt's one (and
        only) item -- clearly printed and legible -- had been parsed,
        silently discarding it entirely (0 items extracted from a receipt
        with exactly 1). Fixed by accepting "price" as an alternative to
        "qty" in the header check."""
        raw = (
            "HON HWA HARDWARE TRADING\n"
            "TAX INVOICE\n"
            "Ofy Description Price Total ( RM )\n"
            "5 PVC WALLPLUG 1.00 5.00 SR\n"
            "( 50PCS )\n"
            "Total Inclusive GST : 5.00\n"
            "CASH 5.00\n"
        )
        items = _extract_line_items(raw)
        assert len(items) == 1
        assert items[0]["item_name"] == "PVC WALLPLUG"
        assert items[0]["price"] == 5.00
        assert items[0]["quantity"] == 5

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

    def test_farm_to_plate_folded_receipt_misread_qty_as_exclamation(self):
        """Real Render production log capture: a physical crease across the
        item table made Vision misread "1 PARMESAN TRUFFLE FRIES 29.00" as
        "! MESAN TRUFFLE FRIES 29.00" (the fold ate "PAR" too, which is
        unrecoverable -- the pixels themselves never reached Vision). The
        leading "!" isn't a digit, so the qty-prefix strip never fired, "!"
        failed every layout's name-start check, and the whole line --
        price included, not just its name -- silently vanished from an
        11-item receipt. Confirmed via this exact raw text pulled from the
        backend's own log output for the real failing scan."""
        raw = (
            "FARM TO PLATE\n"
            "1 FARM TO PLATE SALAD 29.00\n"
            "! MESAN TRUFFLE FRIES 29.00\n"
            "1 ITALIAN PORK SAUSAGE PIZZ 46.00\n"
            "TOTAL 537.90\n"
        )
        items = _extract_line_items(raw)
        names = [it["item_name"] for it in items]
        assert any("TRUFFLE FRIES" in n for n in names)
        fries = next(it for it in items if "TRUFFLE FRIES" in it["item_name"])
        assert fries["price"] == 29.00
        assert fries["quantity"] == 1


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

    def test_lowercase_person_name_above_sdn_bhd_line_rejected(self):
        """Regression guard for a real bug found testing FYP_IMAGES: two
        separate SROIE receipts print a person's name (cashier/customer,
        all-lowercase) directly above the "Sdn Bhd" legal-entity line, e.g.
        "tan woon yann" above "BOOK TA K (TAMAN DAYA) SDN BHD". The
        position-only immediately-prior-line heuristic (added for the
        "FARM TO PLATE" case above) wrongly took that person's name as the
        vendor purely for its position, since nothing previously checked
        whether the candidate actually looks like a business name. A real
        trading name is never printed all-lowercase, so this must fall
        through to the Sdn Bhd line's own name instead."""
        lines = [
            "tan woon yann",
            "BOOK TA K ( TAMAN DAYA ) SDN BHD",
            "789417 - W",
            "NO.5 55,57 & 59 , JALAN SAGU 18 ,",
        ]
        assert _extract_vendor(lines) == "BOOK TA K ( TAMAN DAYA ) SDN BHD"

    def test_lowercase_person_name_with_noise_line_between_still_rejected(self):
        """Same bug, second real receipt -- this one has a "*** COPY ***"
        stamp line (skipped for containing "*") between the person's name
        and the Sdn Bhd line, confirming the fix holds even when the
        rejected candidate isn't the line immediately adjacent to Sdn Bhd."""
        lines = [
            "tan chay yee",
            "*** COPY ***",
            "OJC MARKETING SDN BHD",
            "ROC NO : 538358 - H",
        ]
        assert _extract_vendor(lines) == "OJC MARKETING SDN BHD"


class TestTotalAmountExtraction:
    """Regression guards for real wrong-total bugs found testing FYP_IMAGES --
    each receipt's actual total line got scrambled/excluded for a different
    reason, silently returning some OTHER number on the receipt instead."""

    def test_total_items_count_not_mistaken_for_total_amount(self):
        """Real bug (RESTORAN HASSANBISTRO): reading-order reconstruction
        scrambled this receipt's real GST-inclusive total lines (all
        excluded for containing "gst"), leaving "Total Items = 1.00" -- a
        bare ITEM COUNT -- as the only unexcluded "total"-prefixed line.
        Previously returned 1.00 as the receipt's total; the real total
        (15.00) is recoverable from Strategy 3's blind max once this line is
        correctly excluded too."""
        raw = (
            "RESTORAN HASSANBISTRO\n"
            "MAKANAN\n"
            "1 15.00 0 15.00 ZR\n"
            "Total Items = 1.00\n"
            "Total Qty = 1.00\n"
            "Sub Total RM\n"
            "Total Excl.6 % GST RM 15.00\n"
        )
        result = parse_receipt_fields(raw)
        assert result["amount"] == 15.00

    def test_total_items_count_does_not_break_total_for_n_items_amount_line(self):
        """A real SPAR receipt legitimately prints its grand total ON the
        same line as an item count ("TOTAL FOR 14 ITEMS 338.16") -- "total"
        and "items" aren't adjacent here (unlike the HASSANBISTRO case
        above), so this must NOT be excluded the same way."""
        raw = "SPAR\nBANANAS 9.53\nTOTAL FOR 14 ITEMS 338.16\n"
        result = parse_receipt_fields(raw)
        assert result["amount"] == 338.16

    def test_total_inclusive_of_gst_accepted_when_no_cleaner_total_line_exists(self):
        """Real bug (LIM SENG THO HARDWARE): this receipt's ONLY total-
        bearing line is "Total Incl . of GST 7.00" -- the blanket "gst"
        exclusion (there to stop a bare tax figure like "GST Payable: 1.76"
        from being mistaken for the total) also wrongly excluded this
        legitimate grand-total line, since it happens to mention GST too.
        Previously fell through to an unrelated GST-summary sub-figure
        (6.60) instead of the real total (7.00). Uses the EXACT real raw
        text pulled from the backend's own debug log for this receipt
        (including its "10.00 NOS X 0.70 7.00 SR" item line and the stray
        space-dot-space Vision printed as "Incl . of") -- an earlier,
        hand-typed approximation of this same receipt used plain "Incl. of"
        and passed even while the carve-out regex itself was still broken
        against the real image's actual spacing, since a coincidentally
        correct Strategy-3 blind-max fallback masked the bug. This is the
        one test in this file that must be checked against the real photo's
        text, not a simplified hand-typed guess at its shape."""
        raw = (
            "3 1802 013 .\n"
            "LIM SENG THO HARDWARE TRADING\n"
            "No 7. Simpang Off Batu Village ,\n"
            "Jalan Ipoh Batu 5 , 51200 Kuala Lumpur .\n"
            "MALAYSIA\n"
            "Tel & Fax No : 03-6258 7191\n"
            "03-6258 7191\n"
            "Company Reg No. ( 002231061 - T )\n"
            "GST Reg No. 001269075968\n"
            "TAX INVOICE\n"
            "Invoice No CS 24146\n"
            "Date : 02/02/2018 10:06\n"
            "Cashier # LST\n"
            "RM Code\n"
            "BEG GUNI\n"
            "10.00 NOS X 0.70 7.00 SR\n"
            "Subtotal : 7.00\n"
            "Total Incl . of GST 7.00\n"
            "Payment : 7.00\n"
            "Change Due : 0.00\n"
            "Total Item ( s ) : 10\n"
            "GST Summary Amount ( RM ) Tax ( RM )\n"
            "SR 6 % 6.60 040\n"
        )
        result = parse_receipt_fields(raw)
        assert result["amount"] == 7.00

    def test_total_includes_gst_amount_not_mistaken_for_grand_total(self):
        """Regression guard for a real bug introduced by an earlier, looser
        version of the "inclusive of GST" carve-out above: a real McDonald's
        receipt has BOTH a clean grand total ("Total Rounded 25.40") AND a
        separate "TOTAL INCLUDES 6 % GST 1.44" line further down stating the
        GST component itself, not the total. "INCLUDES" contains "incl" the
        same as "Inclusive"/"Incl. of" do, but is never followed by "of" --
        the carve-out must not fire here, or it wrongly overwrites the
        already-correct 25.40 with the tax amount (1.44) instead."""
        raw = (
            "McDonald's\n"
            "1 M McChicken 9.50\n"
            "TakeOut Total ( incl GST ) 25.40\n"
            "Total Rounded 25.40\n"
            "Cash Tendered 26.00\n"
            "Change 0.60\n"
            "TOTAL INCLUDES 6 % GST 1.44\n"
        )
        result = parse_receipt_fields(raw)
        assert result["amount"] == 25.40

    def test_bare_gst_payable_line_still_excluded(self):
        """The carve-out above must stay narrow: a line stating the GST/tax
        amount itself ("GST Payable : 1.76", with no "incl"/"inclusive"
        qualifier tying it to "total") is NOT the grand total and must
        remain excluded, same as before this fix."""
        raw = (
            "SUSHI MENTAI\n"
            "Total ( Excluding GST ) : 26.60\n"
            "GST Payable : 1.76\n"
            "TOTAL : 31.00\n"
        )
        result = parse_receipt_fields(raw)
        assert result["amount"] == 31.00

    def test_comma_grouped_thousands_total_not_read_as_decimal(self):
        """Real bug (MOMI & TOY'S CRÊPERIE, an Indonesian Rupiah receipt):
        "TOTAL 175,000" uses a comma as a THOUSANDS separator (IDR has no
        minor decimal unit) -- the old pattern's `\\d{2}` was happy to match
        just the first 2 of the 3 trailing digits ("175,00" out of
        "175,000"), undercounting the real total by 1000x."""
        raw = "MOMI & TOY'S\nHam Cheese 74.000\nSUBTOTAL 175,000\nTOTAL 175,000\n"
        result = parse_receipt_fields(raw)
        assert result["amount"] == 175000.0

    def test_ordinary_decimal_comma_amount_still_correct(self):
        """The thousands-grouping fix above must not misfire on an ordinary
        comma-as-decimal-point amount (no 3-digit grouping involved)."""
        raw = "SOME STORE\nItem 5.00\nTOTAL 12,50\n"
        result = parse_receipt_fields(raw)
        assert result["amount"] == 12.50

    def test_comma_grouped_thousands_with_decimal_cents(self):
        """A combined format, e.g. "1,234.56" -- thousands-grouped AND with
        real decimal cents -- must keep the cents, not just strip to whole
        dollars."""
        raw = "SOME STORE\nItem 5.00\nTOTAL 1,234.56\n"
        result = parse_receipt_fields(raw)
        assert result["amount"] == 1234.56


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


def _http_error(code: int, body: str = "") -> "urllib.error.HTTPError":
    import urllib.error
    return urllib.error.HTTPError(
        url="https://generativelanguage.googleapis.com/fake",
        code=code, msg="error", hdrs=None, fp=io.BytesIO(body.encode()),
    )


class TestGeminiRetryAndQuotaHandling:
    """Regression guard for a real batch run over FYP_IMAGES: Gemini's free
    tier enforces a PER-DAY request cap (as low as 20/day for this model),
    not just a per-minute burst limit -- and both surface as the same HTTP
    429 status, distinguishable only by reading the error body. Retrying a
    genuine daily-quota exhaustion is pointless (it can't clear for hours)
    and was confirmed to make batch results WORSE by burning extra requests
    per receipt on calls that could never succeed -- so only a transient
    503 (or a non-daily 429) should be retried; a daily-quota 429 must fail
    fast and be remembered for the rest of the process. See
    _urlopen_with_retry's own docstring."""

    @patch("services.ocr_service._gemini_daily_quota_exhausted_until", None)
    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_transient_503_is_retried_and_recovers(self, mock_urlopen):
        mock_urlopen.side_effect = [
            _http_error(503, "temporarily unavailable"),
            _mock_gemini_response({
                "vendor_name": "TOMO VISION SETAPAK",
                "line_items": [{"item_name": "Lens", "quantity": 1, "price": 50.0}],
            }),
        ]
        with patch("services.ocr_service.time.sleep"):  # skip the real backoff delay
            result = _gemini_fallback_extract(b"fake-image-bytes")
        assert mock_urlopen.call_count == 2
        assert result is not None
        assert result["vendor_name"] == "TOMO VISION SETAPAK"

    @patch("services.ocr_service._gemini_daily_quota_exhausted_until", None)
    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_daily_quota_exhaustion_not_retried_and_remembered(self, mock_urlopen):
        daily_quota_body = json.dumps({
            "error": {
                "code": 429, "status": "RESOURCE_EXHAUSTED",
                "message": "Quota exceeded ... Please retry in 38s.",
                "details": [{
                    "@type": "type.googleapis.com/google.rpc.QuotaFailure",
                    "violations": [{
                        "quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
                    }],
                }],
            }
        })
        mock_urlopen.side_effect = _http_error(429, daily_quota_body)

        with patch("services.ocr_service.time.sleep") as mock_sleep:
            result = _gemini_fallback_extract(b"fake-image-bytes")
        # Exactly one attempt -- retrying a daily cap can't ever succeed
        assert mock_urlopen.call_count == 1
        mock_sleep.assert_not_called()
        assert result is None

        # A second receipt processed later in the same run must skip the
        # network call entirely rather than rediscovering the same 429.
        result2 = _gemini_fallback_extract(b"another-fake-image")
        assert mock_urlopen.call_count == 1  # unchanged -- short-circuited
        assert result2 is None

    @patch("services.ocr_service._gemini_daily_quota_exhausted_until", None)
    @patch("services.ocr_service.GEMINI_API_KEY", "fake-key-for-test")
    @patch("services.ocr_service.urllib.request.urlopen")
    def test_non_daily_429_is_still_retried(self, mock_urlopen):
        """A 429 whose body does NOT identify a PerDay quota (e.g. a short
        per-request burst limit) is a different failure mode from the daily
        cap above and should still get the short-backoff retry."""
        mock_urlopen.side_effect = [
            _http_error(429, '{"error": {"message": "please slow down"}}'),
            _mock_gemini_response({
                "vendor_name": "TOMO VISION SETAPAK",
                "line_items": [{"item_name": "Lens", "quantity": 1, "price": 50.0}],
            }),
        ]
        with patch("services.ocr_service.time.sleep"):
            result = _gemini_fallback_extract(b"fake-image-bytes")
        assert mock_urlopen.call_count == 2
        assert result is not None


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

    def test_flags_via_vocabulary_alone_when_brackets_are_lost(self):
        """Regression guard for a real crop of just this document's lower
        half: Vision's reading order interleaved unrelated text between
        each "[" and its numbers, so the bracket signal alone didn't fire.
        Section headings unique to this report type must catch it on
        their own even with the bracket punctuation stripped out entirely."""
        text = (
            "5. TOTAL BODY WATER KG/LBS\n"
            "42.5 / Optimal\n"
            "10. TOTAL BODY FAT PERCENTAGE\n"
            "17.6% / Optimal\n"
            "18. SEGMENTAL ANALYSIS\n"
            "ANYTIME FITNESS\n"
        )
        assert _looks_like_non_receipt_report(text) is True


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
    def test_cropped_lower_half_with_no_date_and_no_intact_brackets_is_rejected(self, mock_extract_text):
        """The exact real-world failure that got past the first version of
        this fix: a photo of just this document's lower half (no date/name
        header at all this time) whose OCR text also happened not to
        preserve clean bracket pairs -- only the section-heading vocabulary
        was left to catch it."""
        mock_extract_text.return_value = (
            "5. TOTAL BODY WATER KG/LBS\n"
            "42.5 / Optimal\n"
            "10. TOTAL BODY FAT PERCENTAGE\n"
            "17.6% / Optimal\n"
            "18. SEGMENTAL ANALYSIS\n"
            "ANYTIME FITNESS\n"
            "26.50\n"
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

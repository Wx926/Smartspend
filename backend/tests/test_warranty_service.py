"""Unit tests for backend/services/warranty_service.py."""
from datetime import date, timedelta

from services.warranty_service import detect_warranty


class TestWarrantyDetection:
    def test_numeric_duration(self):
        result = detect_warranty("5-Yrs LTD Wrty on this product", date(2026, 1, 1))
        assert result is not None
        assert result["duration_months"] == 60
        assert result["expiry_date"] == "2031-01-01"

    def test_descriptive_duration(self):
        result = detect_warranty("ONE YEAR WARRANTY included", date(2026, 1, 1))
        assert result is not None
        assert result["duration_months"] == 12

    def test_no_warranty_keyword_returns_none(self):
        assert detect_warranty("Thank you for shopping with us", date(2026, 1, 1)) is None

    def test_implausible_duration_does_not_crash(self):
        """A garbled OCR number (e.g. a misread serial number landing next
        to "yrs") must not overflow date()'s valid range and crash the
        request -- confirmed possible with large enough bogus values."""
        result = detect_warranty("15502 yrs warranty", date(2026, 1, 1))
        # Either safely unparsed (None) or flagged unknown -- must not raise.
        assert result is None or result["status"] in ("unknown", "green", "yellow", "red")


class TestClaimDeadlineDetection:
    def test_claim_within_n_days(self):
        """Custom-order receipts (e.g. an optical shop) often use "must be
        claimed within N days" phrasing instead of "X months warranty" --
        invisible to the warranty-keyword path, needs its own detection."""
        receipt_date = date(2026, 1, 1)
        result = detect_warranty(
            "Please note: item must be claimed within 14 days of purchase with receipt.",
            receipt_date,
        )
        assert result is not None
        assert result["expiry_date"] == (receipt_date + timedelta(days=14)).isoformat()

    def test_collect_within_n_days_variant(self):
        receipt_date = date(2026, 3, 1)
        result = detect_warranty(
            "All products must be collected within 90 days from the date above.",
            receipt_date,
        )
        assert result is not None
        assert result["expiry_date"] == (receipt_date + timedelta(days=90)).isoformat()

    def test_no_claim_keyword_no_false_positive(self):
        """A bare day-count with neither warranty nor claim-deadline
        wording nearby must not be mistaken for a claim deadline."""
        result = detect_warranty("Valid for 30 days from purchase, no strings attached", date(2026, 1, 1))
        assert result is None

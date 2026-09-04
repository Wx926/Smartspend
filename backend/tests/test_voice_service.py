"""Unit tests for backend/services/voice_service.py."""
import pytest

from services.voice_service import parse_voice_expense, VoiceParseError


class TestSingleExpense:
    def test_amount_vendor_description(self):
        result = parse_voice_expense("I spent RM 25 on lunch at KFC")
        assert result["amount"] == 25.0
        assert result["vendor_name"] == "KFC"
        assert len(result["line_items"]) == 1

    def test_bare_number_no_currency_word(self):
        """Last-resort fallback for a dropped currency word."""
        result = parse_voice_expense("movie tickets 45")
        assert result["amount"] == 45.0

    def test_spoken_ringgit_and_cents(self):
        """Real bug found close to submission: "7 ringgit 90 cent" was
        parsed as 7.00, silently dropping the "90 cent" -- _AMOUNT_PATTERN
        alone only captures the number immediately before "ringgit"."""
        result = parse_voice_expense("ice cream 7 ringgit 90 cent")
        assert result["amount"] == 7.90

    def test_spoken_ringgit_and_sen(self):
        """"Sen" is the actual Malay word for cents -- must work the same
        as the English "cent" Whisper sometimes transcribes it as."""
        result = parse_voice_expense("roti canai 2 ringgit 90 sen")
        assert result["amount"] == 2.90


class TestMultiExpenseSegmentation:
    def test_splits_on_sentence_boundaries(self):
        """Real transcript from testing: two distinct purchases spoken in
        one recording, separated by a period -- must become two separate
        line items whose prices sum to the total, not one clumped item."""
        transcript = "GSC Cinema 2350 Family Mark 8. JAD Sports 9520."
        result = parse_voice_expense(transcript)
        assert len(result["line_items"]) == 2
        assert result["amount"] == pytest.approx(
            sum(li["price"] for li in result["line_items"])
        )

    def test_decimal_amount_not_split_by_period(self):
        """"RM 12.50" must not be misread as a sentence boundary between
        "RM 12" and "50 for Grab..." -- the period-not-followed-by-digit
        guard exists specifically for this."""
        result = parse_voice_expense("RM 12.50 for Grab to KLCC today")
        assert result["amount"] == 12.50
        assert len(result["line_items"]) == 1


class TestConfidenceSharing:
    """voice_service shares ocr_service.items_confidence rather than having
    its own copy -- these guard that the wiring actually reaches the
    field, since a missing items_confidence previously defaulted to
    looking "trustworthy" on the Flutter side even when it wasn't."""

    def test_nonsense_input_flagged_low_not_missing(self):
        result = parse_voice_expense("Hello there how are you")
        assert result["items_confidence"] == "low"

    def test_real_expense_flagged_high(self):
        result = parse_voice_expense("RM 25 on lunch at KFC")
        assert result["items_confidence"] == "high"


class TestEmptyInput:
    def test_empty_transcript_raises(self):
        with pytest.raises(VoiceParseError):
            parse_voice_expense("")

    def test_whitespace_only_raises(self):
        with pytest.raises(VoiceParseError):
            parse_voice_expense("   ")

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

    def test_spoken_ringgit_and_cents_with_real_whisper_comma(self):
        """Real transcript, verified against the actual app screen: Whisper
        transcribed a natural speech pause as a comma ("7 ringgit, 90
        cent"), which the first version of this fix didn't tolerate (it
        only matched a plain space) -- silently reproducing the exact bug
        it was meant to fix. Two full multi-item segments, matching what
        was actually seen broken: item names were "90 cent" / "Ice cream 95
        cent" at RM7.00 / RM5.00 (total RM12.00) instead of the correct
        RM7.90 / RM5.95 (total RM13.85)."""
        result = parse_voice_expense(
            "McDonald's, 7 ringgit, 90 cent. Ice cream, 5 ringgit, 95 cent."
        )
        assert len(result["line_items"]) == 2
        prices = sorted(it["price"] for it in result["line_items"])
        assert prices == [5.95, 7.90]
        assert round(result["amount"], 2) == 13.85
        ice_cream = next(it for it in result["line_items"] if it["price"] == 5.95)
        assert "cent" not in ice_cream["item_name"].lower()


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

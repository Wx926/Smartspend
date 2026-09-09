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

    def test_spoken_cents_without_the_word_cent(self):
        """Real transcript: Whisper rendered the same spoken phrase as
        "7 ringgit 95" -- no "cent" word at all -- where the time before it
        produced "7 ringgit, 90 cent". Without accepting the wordless form,
        the amount came out as 7.00 and the orphaned "95" became the item's
        NAME."""
        result = parse_voice_expense("ice cream 7 ringgit 95")
        assert result["amount"] == 7.95
        assert "95" != result["line_items"][0]["item_name"]

    def test_trailing_count_not_swallowed_as_cents(self):
        """Guard for the fix above: the wordless cents form is only accepted
        at the end of a segment, so a trailing number that is really a
        separate count must not be read as cents."""
        result = parse_voice_expense("5 ringgit 2 packets nasi lemak")
        assert result["amount"] == 5.00

    def test_vendor_not_lost_when_spoken_before_a_pause(self):
        """Real bug: "Nando's for Dinner. 45 ringgit." split on the period
        into an amount-less name and a nameless amount. _parse_segment drops
        any segment with no amount, so the vendor was thrown away entirely --
        the entry came back with no merchant and "45 ringgit" as its own
        item description."""
        result = parse_voice_expense("Nando's for Dinner. 45 ringgit.")
        assert result["vendor_name"] == "Nando's"
        assert result["amount"] == 45.00
        assert "ringgit" not in result["line_items"][0]["item_name"].lower()

    def test_comma_separated_names_keep_their_own_amounts(self):
        """Same orphaning on a comma-separated multi-item recording: every
        name was split away from its own price and discarded, leaving items
        named after the leftover cents digits ("95", "45")."""
        result = parse_voice_expense(
            "McDonald's, 7 ringgit 95, Ice Cream, 5 ringgit 45."
        )
        assert result["vendor_name"] == "McDonald's"
        assert len(result["line_items"]) == 2
        assert sorted(i["price"] for i in result["line_items"]) == [5.45, 7.95]

    def test_chinese_fullwidth_comma_splits_multi_item_recording(self):
        """Real bug: real Whisper transcriptions of Chinese speech use the
        full-width comma "，", not ASCII ",". Splitting only on ASCII left
        two complete item+price pairs stuck in one un-split sentence, and
        _extract_amount -- which checks the Chinese kuai-decimal pattern
        before the plain ringgit pattern -- matched whichever pattern type
        it saw first rather than whichever amount actually came first in the
        text, silently discarding "麻辣烫"'s own 15令吉 and merging both
        names into one garbled item worth only the second price."""
        result = parse_voice_expense("麻辣烫15令吉，辣椒板面9块9")
        assert len(result["line_items"]) == 2
        assert round(result["amount"], 2) == 24.90
        names = [i["item_name"] for i in result["line_items"]]
        assert "麻辣烫" in names
        assert "辣椒板面" in names

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


class TestSpokenQuantityWithPerUnitAmount:
    """Demo-day bug: "2 Uniqlo T-shirt, thirty ringgit each" — a spoken
    quantity in front of a spelled-out per-unit amount. The amount regexes
    only see digits, so "thirty" has to be normalised first; "each" then
    makes it a per-unit rate that scales by the quantity."""

    def test_spelled_out_per_unit_amount_scales_by_quantity(self):
        result = parse_voice_expense("2 Uniqlo T-shirt, thirty ringgit each")
        assert result["vendor_name"] == "Uniqlo"
        assert len(result["line_items"]) == 1
        item = result["line_items"][0]
        assert item["quantity"] == 2
        assert item["price"] == 60.0          # 30 each x 2
        assert result["amount"] == 60.0
        assert "ringgit" not in item["item_name"].lower()

    def test_digit_per_unit_amount_still_scales(self):
        result = parse_voice_expense("3 notebooks at Popular, RM 12 each")
        item = result["line_items"][0]
        assert item["quantity"] == 3
        assert item["price"] == 36.0
        assert result["amount"] == 36.0

    def test_compound_number_word_amount(self):
        result = parse_voice_expense("lunch at KFC, twenty five ringgit")
        assert result["amount"] == 25.0
        assert result["vendor_name"] == "KFC"

    def test_quantity_spoken_at_the_end_bare(self):
        result = parse_voice_expense("Uniqlo T-shirt, RM 80 each, 5")
        item = result["line_items"][0]
        assert item["quantity"] == 5
        assert item["price"] == 400.0
        assert result["amount"] == 400.0
        assert "5" not in item["item_name"]

    def test_quantity_spoken_at_the_end_with_unit_word(self):
        result = parse_voice_expense("Uniqlo T-shirt, RM 80 each, 5 pieces")
        item = result["line_items"][0]
        assert item["quantity"] == 5
        assert item["price"] == 400.0
        assert "piece" not in item["item_name"].lower()

    def test_quantity_spoken_at_the_end_times_shorthand(self):
        result = parse_voice_expense("nasi lemak 5 ringgit each x3")
        item = result["line_items"][0]
        assert item["quantity"] == 3
        assert item["price"] == 15.0

    def test_trailing_bare_number_without_qty_shape_is_not_a_quantity(self):
        """A trailing number with no each/times/unit word must stay out of
        the quantity slot — guards the cents-style "7 ringgit 95" shape."""
        result = parse_voice_expense("ice cream 7 ringgit 95")
        assert result["amount"] == 7.95
        assert result["line_items"][0]["quantity"] == 1

    def test_all_spelled_out_quantity_and_amount(self):
        result = parse_voice_expense("five uniqlo t shirt eighty ringgit each")
        item = result["line_items"][0]
        assert item["quantity"] == 5
        assert item["price"] == 400.0
        assert result["vendor_name"] == "Uniqlo"

    def test_spelled_out_leading_quantity_before_plain_noun(self):
        result = parse_voice_expense("three nasi lemak, five ringgit each")
        item = result["line_items"][0]
        assert item["quantity"] == 3
        assert item["price"] == 15.0

    def test_lone_number_word_in_prose_is_not_a_quantity(self):
        """Guard for the leading-count heuristic: "one" as an article-like
        word must not become a quantity."""
        result = parse_voice_expense("one of the coffees at Starbucks, RM 12")
        assert result["amount"] == 12.0
        assert result["line_items"][0]["quantity"] == 1


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

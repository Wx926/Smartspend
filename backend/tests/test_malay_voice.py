# -*- coding: utf-8 -*-
"""Malay (Bahasa Malaysia) spoken-money parsing.

Every case here returned "no amount found" before Malay support existed: the
amount regexes only ever see ASCII digits, and "tujuh ringgit lima puluh sen"
contains none. Confirmed against the real app screen, which showed
"Nasi Goreng, RM 7,50" parsed as RM 7.00 with a stranded "50" in the item
name, and "Sepuloh ringgit" producing nothing at all.
"""

import pytest

from services.text_normalisation import (
    normalise_decimal_comma,
    normalise_malay_money,
)
from services.voice_service import parse_voice_expense
from services.whisper_service import _clean_transcript


class TestMalayNumberWords:
    @pytest.mark.parametrize("spoken,expected", [
        ("Nasi Goreng tujuh ringgit lima puluh sen", "Nasi Goreng 7 ringgit 50 sen"),
        ("Nasi Lemak sepuluh ringgit", "Nasi Lemak 10 ringgit"),
        ("dua puluh lima ringgit", "25 ringgit"),
        ("satu ratus lima puluh ringgit", "150 ringgit"),
        ("sembilan ringgit lima puluh sen", "9 ringgit 50 sen"),
        ("dua belas ringgit", "12 ringgit"),
        ("sebelas ringgit", "11 ringgit"),
    ])
    def test_number_words_become_digits(self, spoken, expected):
        assert normalise_malay_money(spoken).strip() == expected

    def test_whisper_misspellings_folded(self):
        """"Sepuloh"/"sambilan" are spellings Whisper actually produced."""
        assert normalise_malay_money("Sepuloh ringgit").strip() == "10 ringgit"
        assert normalise_malay_money("sambilan ringgit").strip() == "9 ringgit"

    def test_place_name_not_treated_as_a_number(self):
        """"Negeri Sembilan" is a state, not the number nine."""
        assert normalise_malay_money("Negeri Sembilan trip") == "Negeri Sembilan trip"

    def test_number_word_without_currency_context_untouched(self):
        assert normalise_malay_money("satu hari nanti") == "satu hari nanti"


class TestDecimalComma:
    def test_comma_decimal_becomes_a_point(self):
        """Whisper writes spoken "tujuh ringgit lima puluh" as "RM 7,50"."""
        assert normalise_decimal_comma("Nasi Goreng, RM 7,50.") == "Nasi Goreng, RM 7.50."

    def test_thousands_separator_left_alone(self):
        assert normalise_decimal_comma("RM 1,500") == "RM 1,500"

    def test_spaced_list_left_alone(self):
        assert normalise_decimal_comma("RM 5, 10") == "RM 5, 10"


class TestMalayAmounts:
    @pytest.mark.parametrize("transcript,expected", [
        ("Nasi Goreng tujuh ringgit lima puluh sen", 7.50),
        ("Nasi Lemak Ayam Rendang sepuluh ringgit", 10.00),
        ("Nasi Lemak, Ayam Rendang, Sepuloh ringgit.", 10.00),
        ("Nasi Goreng, RM 7,50.", 7.50),
        ("dua puluh lima ringgit teh tarik", 25.00),
    ])
    def test_amount(self, transcript, expected):
        result = parse_voice_expense(_clean_transcript(transcript))
        assert result["amount"] == pytest.approx(expected)

    def test_item_name_and_category(self):
        result = parse_voice_expense(
            _clean_transcript("Nasi Lemak Ayam Rendang sepuluh ringgit")
        )
        item = result["line_items"][0]
        assert item["item_name"] == "Nasi Lemak Ayam Rendang"
        assert item["price"] == 10.00
        assert result["suggested_category_name"] == "Food & Dining"

    def test_decimal_comma_no_longer_strands_the_cents(self):
        """The exact screen bug: RM 7.00 with "50" left in the item name."""
        result = parse_voice_expense(_clean_transcript("Nasi Goreng, RM 7,50."))
        item = result["line_items"][0]
        assert item["price"] == 7.50
        assert item["item_name"] == "Nasi Goreng"

    def test_two_malay_items_split_into_two_rows(self):
        result = parse_voice_expense(
            _clean_transcript(
                "Nasi Goreng RM 7,50. Mee Goreng sembilan ringgit lima puluh sen."
            )
        )
        assert len(result["line_items"]) == 2
        assert sorted(i["price"] for i in result["line_items"]) == [7.50, 9.50]
        assert result["amount"] == pytest.approx(17.00)


class TestMalayQuantity:
    def test_count_spoken_after_the_price_is_per_unit(self):
        """"Maggi Goreng Double lima ringgit lima puluh sen DUA" = 2 of them
        at RM 5.50 = RM 11.00. A count spoken after a complete price means
        that price was per unit."""
        result = parse_voice_expense(
            _clean_transcript("Maggie Goreng Double lima ringgit lima puluh sen dua")
        )
        item = result["line_items"][0]
        assert item["quantity"] == 2
        assert item["price"] == 11.00
        assert item["item_name"] == "Maggie Goreng Double"

    def test_double_in_the_dish_name_is_not_a_quantity(self):
        """"Double" means a double portion — part of the name, not a count."""
        result = parse_voice_expense(_clean_transcript("Maggi Goreng Double RM 5,50"))
        item = result["line_items"][0]
        assert item["quantity"] == 1
        assert item["price"] == 5.50
        assert "Double" in item["item_name"]

    def test_count_spoken_first_is_the_line_total(self):
        """Front-position count with no "setiap": the price is the total."""
        result = parse_voice_expense(_clean_transcript("dua nasi lemak lima ringgit"))
        item = result["line_items"][0]
        assert item["quantity"] == 2
        assert item["price"] == 5.00

    def test_malay_measure_word_quantity(self):
        """"tiga bungkus" = 3 packets; the measure word must not survive into
        the item name."""
        result = parse_voice_expense(
            _clean_transcript("tiga bungkus nasi lemak lima ringgit setiap satu")
        )
        item = result["line_items"][0]
        assert item["quantity"] == 3
        assert item["price"] == 15.00
        assert item["item_name"] == "nasi lemak"

    def test_setiap_scales_like_each(self):
        result = parse_voice_expense(
            _clean_transcript("lima biji roti canai satu ringgit setiap satu")
        )
        item = result["line_items"][0]
        assert item["quantity"] == 5
        assert item["price"] == 5.00


class TestBareAmountGuard:
    """The trailing-count rule only fires when a currency word was actually
    spoken — otherwise a stray number at the end of a name would be eaten."""

    def test_trailing_digit_after_a_bare_number_is_not_a_count(self):
        result = parse_voice_expense("GSC Cinema 2350 Family Mark 8. JAD Sports 9520.")
        assert len(result["line_items"]) == 2
        assert result["amount"] == pytest.approx(
            sum(li["price"] for li in result["line_items"])
        )


class TestMalayTrailingPunctuation:
    """Whisper ends the sentence with a period and puts a comma at the pause
    before the count: "Maggi Goreng Double 5 ringgit 50 sen, dua." The count
    word arrived glued to the period ("dua.") and stopped being recognised."""

    def test_count_after_price_with_comma_and_period(self):
        result = parse_voice_expense(
            _clean_transcript("Maggi Goreng Double 5 ringgit 50 sen, dua.")
        )
        item = result["line_items"][0]
        assert item["quantity"] == 2
        assert item["price"] == 11.00
        assert item["item_name"] == "Maggi Goreng Double"

    def test_word_form_count_after_price_with_punctuation(self):
        result = parse_voice_expense(
            _clean_transcript(
                "Maggi Goreng Double lima ringgit lima puluh sen, dua."
            )
        )
        assert result["line_items"][0]["quantity"] == 2
        assert result["line_items"][0]["price"] == 11.00

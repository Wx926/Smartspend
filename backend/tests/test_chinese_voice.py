# -*- coding: utf-8 -*-
"""Chinese (Mandarin) spoken-money parsing — the shapes a Malaysian-Chinese
speaker actually uses. Every case here returned "no amount found" before the
Chinese support was added: the amount regexes only ever saw ASCII digits, and
`\b` is broken after a CJK character (Python treats 吉/块 as word characters,
so "20令吉10仙" had no boundary for the pattern to anchor on)."""

import pytest

from services.text_normalisation import normalise_chinese_money
from services.voice_service import parse_voice_expense
from services.whisper_service import _clean_transcript


class TestChineseNumeralNormalisation:
    @pytest.mark.parametrize("spoken,expected", [
        ("炒饭九块", "炒饭9块"),
        ("冰淇淋两块二", "冰淇淋2块2"),
        ("麻辣烫二十令吉十仙", "麻辣烫20令吉10仙"),
        ("10块一毛", "10块1毛"),
        ("10块一", "10块1"),
        ("奶茶三块五", "奶茶3块5"),
        ("两个冰淇淋", "2个冰淇淋"),
        ("十块钱", "10块钱"),
    ])
    def test_numerals_become_digits(self, spoken, expected):
        assert normalise_chinese_money(spoken) == expected

    def test_traditional_folded_to_simplified(self):
        assert normalise_chinese_money("炒飯九塊") == "炒飯9块"
        assert normalise_chinese_money("兩塊二") == "2块2"

    def test_lingjit_misheard_repaired(self):
        assert normalise_chinese_money("肉骨茶15零吉") == "肉骨茶15令吉"

    def test_ordinary_words_untouched(self):
        """A numeral character inside a normal word must never be converted."""
        assert normalise_chinese_money("三明治") == "三明治"
        assert normalise_chinese_money("一起吃饭") == "一起吃饭"


class TestChineseAmounts:
    @pytest.mark.parametrize("transcript,expected", [
        ("10令吉", 10.00),
        ("10块", 10.00),
        ("10块一", 10.10),        # bare trailing 1 digit = jiao
        ("10块一毛", 10.10),       # explicit 毛/角 = 1/10
        ("麻辣烫20令吉10仙", 20.10),  # 仙/分 = 1/100
        ("麻辣烫二十令吉十仙", 20.10),
        ("冰淇淋两块二", 2.20),
        ("炒饭九块", 9.00),
        ("9块9", 9.90),
        ("9块95", 9.95),
        ("奶茶三块五", 3.50),
    ])
    def test_amount(self, transcript, expected):
        result = parse_voice_expense(_clean_transcript(transcript))
        assert result["amount"] == pytest.approx(expected)

    def test_real_transcript_with_whisper_space(self):
        """Confirmed on the actual app screen: Whisper wrote the speech pause
        in "冰淇淋两块二" as a SPACE plus a full stop ("冰淇淋, 2块 2."), which
        the old digits-only pattern couldn't match — it fell through and
        returned RM 2.00 with "2" stranded in the item name."""
        result = parse_voice_expense(_clean_transcript("冰淇淋, 2块 2."))
        assert result["amount"] == 2.20
        item = result["line_items"][0]
        assert item["item_name"] == "冰淇淋"
        assert item["price"] == 2.20

    def test_item_name_and_category(self):
        result = parse_voice_expense(_clean_transcript("麻辣烫20令吉10仙"))
        assert result["line_items"][0]["item_name"] == "麻辣烫"
        assert result["suggested_category_name"] == "Food & Dining"

    def test_multi_item_still_splits(self):
        """Guard the amount-counting change: two Chinese amounts in one
        sentence must still become two line items."""
        result = parse_voice_expense("麻辣烫15令吉，辣椒板面9块9")
        assert len(result["line_items"]) == 2
        assert round(result["amount"], 2) == 24.90


class TestChineseQuantity:
    def test_measure_word_quantity(self):
        """"两个冰淇淋" is a count of 2 — Chinese has no spaces, so the ASCII
        quantity pattern (which needs whitespace after the digits) missed it."""
        result = parse_voice_expense(_clean_transcript("两个冰淇淋，两块二"))
        item = result["line_items"][0]
        assert item["quantity"] == 2
        assert item["item_name"] == "冰淇淋"

    def test_chinese_per_unit_marker_scales_the_amount(self):
        """"每个" / "每杯" means "each", exactly like the English marker."""
        result = parse_voice_expense(_clean_transcript("三杯奶茶，每杯四令吉"))
        item = result["line_items"][0]
        assert item["quantity"] == 3
        assert item["price"] == 12.00


class TestChineseMultiItem:
    """Multiple dishes in one spoken sentence must become one row each —
    confirmed broken on the real app screen: "麻辣烫2块2。冰淇淋5块2毛。" came
    back as a SINGLE line item worth only RM 2.20, its name the whole rest of
    the string ("麻辣烫。冰淇淋5块2毛"). _SENTENCE_SPLIT only knew the ASCII
    ".!?", not the full-width "。！？" Whisper actually emits for Chinese."""

    def test_fullwidth_period_separates_items(self):
        result = parse_voice_expense(_clean_transcript("麻辣烫2块2。冰淇淋5块2毛。"))
        assert len(result["line_items"]) == 2
        by_name = {i["item_name"]: i["price"] for i in result["line_items"]}
        assert by_name == {"麻辣烫": 2.20, "冰淇淋": 5.20}
        assert result["amount"] == pytest.approx(7.40)

    def test_fullwidth_period_with_chinese_numerals(self):
        result = parse_voice_expense(_clean_transcript("麻辣烫二块二。冰淇淋五块二毛。"))
        assert len(result["line_items"]) == 2
        assert result["amount"] == pytest.approx(7.40)

    def test_run_together_no_separator(self):
        """Chinese speech is often transcribed with no separator at all."""
        result = parse_voice_expense(_clean_transcript("麻辣烫2块2冰淇淋5块2毛"))
        assert len(result["line_items"]) == 2
        assert sorted(i["price"] for i in result["line_items"]) == [2.20, 5.20]

    def test_three_items_enumeration_comma(self):
        result = parse_voice_expense(_clean_transcript("炒饭九块、奶茶三块五、云吞面八块"))
        assert len(result["line_items"]) == 3
        assert result["amount"] == pytest.approx(20.50)
        assert {i["item_name"] for i in result["line_items"]} == {"炒饭", "奶茶", "云吞面"}

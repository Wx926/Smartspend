"""Unit tests for backend/services/text_normalisation.py and the
whisper_service transcript-cleanup that builds on it."""

from services.text_normalisation import words_to_digits
from services.whisper_service import _clean_transcript


class TestWordsToDigits:
    def test_single_tens_word(self):
        assert words_to_digits("thirty ringgit each") == "30 ringgit each"

    def test_compound_tens_and_units(self):
        assert words_to_digits("twenty five ringgit") == "25 ringgit"

    def test_hyphenated_compound(self):
        assert words_to_digits("twenty-five ringgit") == "25 ringgit"

    def test_hundreds_with_and(self):
        assert words_to_digits("one hundred and fifty ringgit") == "150 ringgit"

    def test_leaves_unknown_runs_untouched(self):
        # "of" is not a number word -> the whole run is left as spoken.
        assert words_to_digits("one of the coffees") == "one of the coffees"

    def test_no_number_words_is_identity(self):
        assert words_to_digits("I spent RM 25 on lunch at KFC") == \
            "I spent RM 25 on lunch at KFC"

    def test_does_not_touch_chinese(self):
        assert words_to_digits("麻辣烫15令吉，辣椒板面9块9") == "麻辣烫15令吉，辣椒板面9块9"


class TestCleanTranscript:
    """The exact failures seen on the demo clips — a quantity spoken before
    the amount derailing the number+currency decode on the hosted `tiny`
    model."""

    def test_turing_gat_each(self):
        # Image 1: "2 Uniqlo T-shirt, thirty ringgit each"
        out = _clean_transcript("2 Uniqlo T-shirt, Turing Gat Each.")
        assert "30 ringgit each" in out.lower()

    def test_thierry_and_each(self):
        # Image 2: same phrase, different mangling.
        out = _clean_transcript("2 Uniqlo T-shirt for Thierry and Each.")
        assert "30 ringgit" in out.lower()

    def test_plain_ringgit_misspelling_still_fixed(self):
        assert "ringgit" in _clean_transcript("chicken rice 15 ringit").lower()

    def test_unrelated_thierry_not_clobbered(self):
        # No currency/per-unit context after the name -> left alone.
        out = _clean_transcript("Dinner with Thierry at Nando's, RM 45")
        assert "Thierry" in out

    def test_clean_phrase_passes_through(self):
        out = _clean_transcript("I spent RM 25 on lunch at KFC")
        assert out == "I spent RM 25 on lunch at KFC"

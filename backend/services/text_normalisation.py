"""Shared text-normalisation helpers for the voice pipeline.

Kept in its own module (no `faster_whisper` import) so both
`whisper_service` (cleaning raw model output) and `voice_service` (cleaning
a transcript that may have been hand-edited in the app's transcript box)
can use the exact same spoken-number handling without one pulling the
other's heavy dependencies into the parser's import graph.
"""

import re

# Spoken whole-number words 0-99 plus the multipliers "hundred"/"thousand".
# Common misspellings Whisper actually emits are folded in ("fourty").
_UNITS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12,
}
_TEENS_AND_TENS = {
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19,
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
_NUM_WORDS = {**_UNITS, **_TEENS_AND_TENS}

# Money / quantity context that makes a *lone* small-number word ("two",
# "twelve") unambiguously a number rather than ordinary prose ("two of us").
# A tens/teen word ("thirty", "fifteen") or a multiplier needs no such
# context — it is virtually never prose in a short expense note.
_MONEY_CONTEXT = re.compile(
    r"(?:ringgit|rm|dollars?|bucks?|cents?|sen|each|per|piece|apiece|kuai|"
    r"令吉|块|pcs?|packets?|pieces?)\b",
    re.IGNORECASE,
)

# Function words that a leading lone units word ("one", "two") is NOT counting
# when one of them follows it — "one of the...", "two or three", "another one".
_QTY_STOPWORDS = {
    "of", "or", "and", "more", "another", "other", "the", "a", "an", "to",
    "for", "by", "as", "is", "was", "than", "then", "time", "times", "day",
    "days", "week", "weeks", "month", "months", "year", "years", "hour",
    "hours", "minute", "minutes", "o'clock", "am", "pm",
}
# The lone units word must sit at the very start of the segment, optionally
# after a purchase verb ("bought two shirts"), to be read as a leading
# quantity rather than prose.
_LEADING_BUY_PREFIX = re.compile(
    r"^\s*(?:i\s+)?(?:just\s+)?(?:bought|got|grabbed|ordered|purchased|had|"
    r"picked\s+up|paid\s+for)?\s*$",
    re.IGNORECASE,
)

# Longest-first: Python's `|` is ordered and first-match-wins, so "eight"
# listed before "eighty" would eat the "eight" of "eighty" and leave "y"
# stranded (same for six/sixty, seven/seventy, nine/nineteen, ...).
_NUM_WORD_ALT = "|".join(
    sorted((*_NUM_WORDS, "hundred", "thousand"), key=len, reverse=True)
)
_NUM_WORD_RUN = re.compile(
    r"\b(?:(?:" + _NUM_WORD_ALT + r")\b"
    r"(?:[\s,-]+(?:and[\s-]+)?)?)+",
    re.IGNORECASE,
)


def words_to_digits(text: str) -> str:
    """Rewrites runs of spoken number words as digit strings:
      "thirty ringgit"            -> "30 ringgit"
      "twenty five ringgit each"  -> "25 ringgit each"
      "one hundred and fifty"     -> "150"

    Conservative by design:
      * a run containing any token this can't resolve is returned exactly as
        spoken ("one of the coffees" is untouched);
      * a lone units word (one-twelve) is only converted when a money /
        quantity context word follows it ("two ringgit"), OR it opens the
        segment as a purchase count in front of an item noun ("three nasi
        lemak", "bought two shirts") — never in the middle of prose.
    """

    def _convert(match: re.Match) -> str:
        raw = match.group(0)
        tokens = [
            t for t in re.split(r"[\s,-]+", raw.strip().lower())
            if t and t != "and"
        ]
        if not tokens:
            return raw
        if not all(t in _NUM_WORDS or t in ("hundred", "thousand") for t in tokens):
            return raw

        has_strong = any(
            t in ("hundred", "thousand") or t in _TEENS_AND_TENS for t in tokens
        )
        if not has_strong:
            rest = match.string[match.end():].lstrip(" ,.-")
            next_word = re.match(r"([A-Za-z']+)", rest)
            leads_segment = bool(_LEADING_BUY_PREFIX.match(match.string[:match.start()]))
            is_leading_count = (
                leads_segment
                and next_word is not None
                and next_word.group(1).lower() not in _QTY_STOPWORDS
            )
            if not _MONEY_CONTEXT.match(rest) and not is_leading_count:
                return raw  # lone "two"/"twelve" in prose — leave it alone

        total = current = 0
        for tok in tokens:
            if tok in _NUM_WORDS:
                current += _NUM_WORDS[tok]
            elif tok == "hundred":
                current = (current or 1) * 100
            elif tok == "thousand":
                total += (current or 1) * 1000
                current = 0
        value = total + current
        # Keep whatever trailing whitespace the run had so the next word
        # doesn't get glued on ("thirty ringgit" not "30ringgit").
        trailing = raw[len(raw.rstrip()):] or " "
        return f"{value}{trailing}"

    return _NUM_WORD_RUN.sub(_convert, text)

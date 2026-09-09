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


# ══════════════════════════════════════════════════════════════════════════
# Chinese (Mandarin) spoken money
# ══════════════════════════════════════════════════════════════════════════
#
# Malaysian-Chinese speakers say amounts as "麻辣烫二十令吉十仙",
# "冰淇淋两块二", "炒饭九块" — Chinese NUMERALS plus a currency unit, with the
# jiao/fen (毛/角 = 0.1, 分/仙 = 0.01) sub-units spoken as bare trailing
# numbers. voice_service's amount regexes only ever see ASCII digits, so
# every one of those parsed as "no amount found" before this existed.

# Traditional -> Simplified, restricted to the characters that carry MEANING
# for amount parsing (plus the common measure words). Deliberately NOT a
# general T2S conversion — no opencc dependency, and an item's name stays
# exactly as Whisper wrote it; only the number/currency characters the parser
# keys off are folded, so 塊/兩/圓 parse identically to 块/两/圆.
_T2S = str.maketrans({
    "塊": "块", "兩": "两", "圓": "圆", "錢": "钱", "萬": "万",
    "個": "个", "隻": "只", "條": "条", "張": "张", "雙": "双",
    "盤": "盘", "貳": "二", "參": "三", "陸": "六", "拾": "十",
    "佰": "百", "仟": "千",
})

# Whisper's near-misses for 令吉 (the Chinese transliteration of "ringgit").
# All are the same "lìng jí" sound with a wrong first character — confirmed
# shapes seen in real transcripts plus their obvious phonetic neighbours.
_CJK_RINGGIT_MISHEARDS = re.compile(r"(?:零|灵|伶|苓|铃|凌|领|龄|玲)吉")

_CJK_DIGITS = {
    "〇": 0, "零": 0, "一": 1, "壹": 1, "二": 2, "两": 2, "贰": 2,
    "三": 3, "叁": 3, "四": 4, "肆": 4, "五": 5, "伍": 5,
    "六": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9,
}
_CJK_MULTIPLIERS = {"十": 10, "百": 100, "千": 1000}
_CJK_NUM_CHARS = "".join(_CJK_DIGITS) + "".join(_CJK_MULTIPLIERS) + "万"

# Whole-currency units (a number in front of one of these is the ringgit/yuan
# figure) vs the sub-units 毛/角 (jiao, 1/10) and 分/仙 (fen/sen, 1/100).
_CJK_WHOLE_UNIT = "块钱|块|令吉|元|圆"
_CJK_SUB_UNIT = "毛|角|分|仙"
# Chinese measure words — "两个冰淇淋" is a QUANTITY of 2, so a numeral in
# front of one of these must become a digit too for the quantity rules.
_CJK_MEASURE = "个|杯|份|件|双|瓶|包|碗|盘|碟|只|条|张|支|片|粒|串|盒|袋|罐|碗"


def _cjk_number_to_int(s: str) -> int | None:
    """"九" -> 9, "十五" -> 15, "二十" -> 20, "两百" -> 200. Returns None if
    the run contains anything that isn't a Chinese numeral character."""
    total = section = number = 0
    seen = False
    for ch in s:
        if ch in _CJK_DIGITS:
            number = _CJK_DIGITS[ch]
            seen = True
        elif ch in _CJK_MULTIPLIERS:
            # "十五" (no leading digit) is 15, not 5 — a bare multiplier
            # implies a leading 1.
            section += (number or 1) * _CJK_MULTIPLIERS[ch]
            number = 0
            seen = True
        elif ch == "万":
            section = (section + number) * 10000
            total += section
            section = number = 0
            seen = True
        else:
            return None
    return (total + section + number) if seen else None


# A Chinese numeral run is only converted when it sits directly in front of a
# currency unit or measure word ("九块", "十仙", "两个"), or directly AFTER a
# whole-currency unit ("两块二" — the trailing 二 is 2 jiao). Anywhere else it
# is left alone, so ordinary words that happen to contain a numeral character
# (三明治 "sandwich", 一起 "together") are never mangled.
_CJK_NUM_BEFORE_UNIT = re.compile(
    rf"([{_CJK_NUM_CHARS}]{{1,4}})(?=\s*(?:{_CJK_WHOLE_UNIT}|{_CJK_SUB_UNIT}|{_CJK_MEASURE}))"
)
_CJK_NUM_AFTER_UNIT = re.compile(
    rf"(?P<unit>{_CJK_WHOLE_UNIT})\s*(?P<num>[{_CJK_NUM_CHARS}]{{1,2}})"
    rf"(?!\s*(?:{_CJK_WHOLE_UNIT}))"
)


def _sub_cjk_number(match: re.Match) -> str:
    value = _cjk_number_to_int(match.group(1))
    return match.group(1) if value is None else str(value)


def _sub_cjk_number_after_unit(match: re.Match) -> str:
    value = _cjk_number_to_int(match.group("num"))
    if value is None:
        return match.group(0)
    return f"{match.group('unit')}{value}"


def normalise_chinese_money(text: str) -> str:
    """Folds traditional characters, repairs Whisper's 令吉 near-misses, and
    turns Chinese numerals adjacent to a currency/measure word into digits:

      "炒饭九块"           -> "炒饭9块"
      "冰淇淋两块二"        -> "冰淇淋2块2"
      "麻辣烫二十令吉十仙"   -> "麻辣烫20令吉10仙"
      "10块一毛"           -> "10块1毛"
      "两个冰淇淋"          -> "2个冰淇淋"

    Leaves everything else untouched — "三明治" stays "三明治".
    """
    text = text.translate(_T2S)
    text = _CJK_RINGGIT_MISHEARDS.sub("令吉", text)
    text = _CJK_NUM_BEFORE_UNIT.sub(_sub_cjk_number, text)
    return _CJK_NUM_AFTER_UNIT.sub(_sub_cjk_number_after_unit, text)

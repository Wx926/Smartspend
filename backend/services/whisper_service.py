"""
Speech-to-Text via local WhisperAI model — Stage 2 of the Voice-Assisted
Expense Categorisation Pipeline (FYP report Chapter 3.1.3).

Runs OpenAI's Whisper model locally via the `faster-whisper` (CTranslate2)
implementation, rather than OpenAI's paid hosted API — same underlying
Whisper model and zero-shot multilingual performance, at zero per-request
cost and fully offline after the one-time model download. Model size is
configurable via WHISPER_MODEL_SIZE (default "small") to trade accuracy for
speed on machines without a GPU.
"""

import io
import os
import re
import threading

from faster_whisper import WhisperModel

from services.text_normalisation import normalise_chinese_money, words_to_digits

_model: WhisperModel | None = None
_model_lock = threading.Lock()

# Same RENDER-var check app.py already uses to distinguish the hosted free
# tier from local dev. Only the hosted tier gets the memory-constrained
# settings below -- local dev has its own "medium" model and ample RAM, and
# gains nothing from trading accuracy away.
_IS_HOSTED = os.environ.get("RENDER") is not None


class WhisperTranscriptionError(Exception):
    """Raised when the local model fails to transcribe the recording."""
    pass


def _load_model() -> WhisperModel:
    size = os.environ.get("WHISPER_MODEL_SIZE", "small")
    # int8 quantization keeps CPU inference fast with minimal accuracy loss.
    # cpu_threads left at CTranslate2's own default (0 = auto-detect and
    # use every available core) for local dev, but pinned to 1 on Render:
    # a confirmed OOM crash (used over 512MB) happened 2 minutes after
    # this model was deployed, and CTranslate2's default of spinning up
    # a thread per detected core inflates per-thread working-memory
    # overhead rather than actually speeding things up on a shared,
    # already-thin vCPU -- it doesn't have the dedicated cores that
    # default assumes.
    cpu_threads = 1 if _IS_HOSTED else 0
    return WhisperModel(
        size, device="cpu", compute_type="int8", cpu_threads=cpu_threads
    )


def _get_model() -> WhisperModel:
    global _model
    if _model is None:
        # The lock matters here specifically because of preload_model_async
        # below: without it, a real request landing WHILE the background
        # thread is mid-load would start a SECOND, fully independent model
        # load of its own (both racing to set the same global), doubling
        # memory use on a machine that already OOM'd once at normal usage
        # (see _load_model's own comment) -- rather than the second caller
        # correctly waiting for the first load already in flight.
        with _model_lock:
            if _model is None:  # re-check: another thread may have finished
                _model = _load_model()
    return _model


def preload_model_async() -> None:
    """Starts loading the Whisper model in a background thread immediately,
    rather than waiting for the first real transcription request to trigger
    it lazily.

    Confirmed on a real device: the FIRST voice recording after Render's
    free-tier instance goes idle failed outright with an empty/malformed
    response (Dart's jsonDecode throwing "Unexpected end of input" -- Render's
    own gateway timing out and cutting the connection with nothing in it),
    even with a generous 150s client-side timeout. OCR never has this problem
    on the very same cold instance, because Vision is a remote API call with
    nothing local to load -- voice uniquely also pays for loading the entire
    Whisper model from disk into memory, every time the container restarts
    (the previous load doesn't survive Render's own idle shutdown), stacked
    on top of the container's own cold-boot time, all inside one request's
    budget.
    Calling this at import time moves that load into the same window Render
    is already spending waking the container up and running its own health
    check -- by the time a real user request actually arrives, the model may
    already be sitting in memory instead of adding its own load time on top.
    Never raises: a failure here should surface on the actual request instead
    (via the normal _get_model() path), not crash the server at import time.
    """
    def _run():
        try:
            _get_model()
        except Exception as e:
            print(f"WARNING: Whisper model preload failed (will retry on "
                  f"first real request): {e}")

    threading.Thread(target=_run, daemon=True).start()


# Nudges the model's vocabulary toward the domain this app actually records —
# Malaysian expense phrases — since a general-purpose small model otherwise
# tends to mishear "ringgit" as "ringit"/"ring get"/"ring gate" (confirmed
# empirically: without this prompt the same clip transcribes as "ringit").
# Chinese currency terms are included too so a code-switched "40 kuai KFC" has
# a chance of coming back with the correct characters.
# The "N item(s), RM X each" examples are deliberate: on the hosted `tiny`
# model a spoken quantity in front of the amount ("2 Uniqlo T-shirt, thirty
# ringgit each") was derailing the decode of the number+currency that
# followed, coming back as "Turing Gat Each" / "for Thierry and Each".
# Seeding the prompt with that exact sentence shape (and with the amounts
# written as DIGITS, so the model is biased to emit "30" not "thirty") gives
# the decoder an anchor for it.
_INITIAL_PROMPT = (
    "Malaysian expense note, amounts in ringgit (RM). "
    "Example: I spent RM 40 on lunch at KFC. Bought groceries at Aeon, RM 68. "
    "RM 80 shoes at Uniqlo. RM 15 for Bak Kut Teh. "
    "2 Uniqlo T-shirts, RM 30 each. 3 Nasi Lemak, RM 5 each. "
    "5 notebooks at Popular, RM 12 each. Bought 4 coffees, RM 8 each. "
    "Also: 令吉, 块, Grab, McDonald's, Nando's, Uniqlo, Shopee, Lazada, Mydin, "
    "Watsons, Petronas, Tealive, Chagee, Popular, Bak Kut Teh, Char Kway Teow, "
    "Nasi Lemak, Roti Canai, Teh Tarik."
)

# The Chinese counterpart. An initial_prompt works by being fed to the decoder
# as "text that came just before" — so a prompt in the WRONG language actively
# hurts, biasing a Mandarin clip toward English tokens. That is why Chinese
# voice entry was so much worse than English: it was being decoded against an
# English-only prompt. Written in simplified Chinese with the exact amount
# shapes this app has to understand — whole 令吉/块, the 毛/角 (1/10) and
# 仙/分 (1/100) sub-units, and the bare-trailing-digit shorthand ("两块二").
_CHINESE_PROMPT = (
    "马来西亚记账语音，金额用令吉、块、毛、仙。"
    "例如：麻辣烫20令吉10仙。冰淇淋两块二。炒饭九块。"
    "肉骨茶15令吉。奶茶三块五。杂菜饭10块一毛。椰浆饭5块。"
    "两个冰淇淋，每个2令吉50仙。三杯奶茶，每杯4令吉。"
    "常见词：麻辣烫、肉骨茶、椰浆饭、杂菜饭、板面、奶茶、咖啡、"
    "冰淇淋、雪糕、炒饭、炒面、鸡饭、云吞面、罗惹、沙爹、"
    "Grab、KFC、麦当劳、Uniqlo、Aeon、Shopee。"
)

# Short bilingual prompt for "Auto-detect" — the user hasn't told us which
# language to expect, so neither monolingual prompt is safe to commit to.
# Kept deliberately brief: a long prompt in the language NOT being spoken is
# exactly the problem described above, so this only carries the currency
# vocabulary both halves need.
_BILINGUAL_PROMPT = (
    "Malaysian expense note, amounts in ringgit (RM). "
    "I spent RM 25 on lunch at KFC. 2 T-shirts, RM 30 each. "
    "马来西亚记账语音：麻辣烫20令吉10仙。冰淇淋两块二。炒饭九块。"
)


def _prompt_for(language: str | None) -> str:
    """Picks the initial_prompt that matches the language actually being
    spoken — see _CHINESE_PROMPT's comment for why this matters so much."""
    if language and language.lower().startswith("zh"):
        return _CHINESE_PROMPT
    if language:
        return _INITIAL_PROMPT
    return _BILINGUAL_PROMPT  # "Auto-detect" — commit to neither

# Belt-and-suspenders: fixes the common near-miss spellings of "ringgit" that
# slip through even with the prompt above, so downstream amount parsing (which
# matches the literal word "ringgit") still recognises it.
#
# The second half of the alternation covers the harder case seen on the demo
# clips: with a quantity spoken first, "thirty ringgit each" came back with
# "ringgit" collapsed into junk syllables ("gat", "gut", "got", "gart",
# "and") — recognisable ONLY by their position, wedged between a number (word
# or digit) and a per-unit marker ("each"/"per"/"a piece"). Anchored on both
# sides so a stray "got"/"and" anywhere else in a sentence is left alone.
_RINGGIT_MISHEARDS = re.compile(
    r"\bring\s*g?it\b|\bring\s*g?ate\b|\bring\s*g?et\b|\bwring\s*g?ate\b"
    r"|\bring\s*guard\b|\bring\s*gut\b|\brii?ng\s*g?i?t\b",
    re.IGNORECASE,
)

# The positional recovery described above: "<number> <junk> each" -> insert a
# literal "ringgit" so voice_service's amount parser (which keys off the word
# "ringgit") can see it. The leading group is a digit run OR a spelled-out
# number word, because this runs BEFORE words_to_digits (words_to_digits
# would otherwise swallow a trailing "and" as run punctuation before this
# pattern gets to see it).
_MISHEARD_CURRENCY_BEFORE_EACH = re.compile(
    r"\b(\d+(?:\.\d{1,2})?|zero|one|two|three|four|five|six|seven|eight|nine|"
    r"ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|"
    r"nineteen|twenty|thirty|forty|fourty|fifty|sixty|seventy|eighty|ninety)"
    r"\s+(?:gat|gut|got|gart|gad|gaht|guard|and|had)\s+"
    r"(?=each\b|per\b|a\s*piece\b|apiece\b)",
    re.IGNORECASE,
)

# "thirty" spoken quickly in front of "ringgit each" is what actually broke on
# the demo clips — the small model rendered it as "Turing", "Thierry",
# "thereby", "dirty", "thurty". Only rewritten when a currency/per-unit
# context word follows within a couple of tokens, so an unrelated proper noun
# ("dinner with Thierry") isn't clobbered.
_THIRTY_MISHEARDS = re.compile(
    r"\b(?:turing|thierry|thereby|thurty|dirty|thirsty)\b"
    r"(?=\s+(?:\w+\s+)?(?:ringgit|rm|gat|gut|got|gart|and|each|per)\b)",
    re.IGNORECASE,
)

# Same belt-and-suspenders treatment for "Bak Kut Teh" — a rare, non-English
# dish name with no real anchor in Whisper's training data, so even with the
# prompt hint above it can still come back as a different phonetically-
# similar guess (confirmed empirically: "bag kut teh", "bakuteh", "good teh").
_BAK_KUT_TEH_MISHEARDS = re.compile(
    r"\b(?:bak|bag|back|bar)\s*kut\s*teh\b|\bbakuteh\b|\bgood\s*teh\b",
    re.IGNORECASE,
)

# Spoken whole-number words -> digits lives in text_normalisation.words_to_digits
# (shared with voice_service). Needed because voice_service's amount parser
# only matches `\d+` before a currency word — without this, even a PERFECTLY
# transcribed "thirty ringgit each" parsed the amount as the quantity ("2").


def _clean_transcript(text: str) -> str:
    """All the domain-specific post-processing applied to Whisper's raw
    output, in order. Split out from transcribe_audio so it can be unit
    tested without loading the model.

    Order matters: fix the mangled "thirty", then re-insert the dropped
    "ringgit" while the sentence still has its number words and connective
    "and", THEN collapse number words to digits, then mop up any remaining
    near-miss "ringgit" spellings.
    """
    text = _THIRTY_MISHEARDS.sub("thirty", text)
    text = _MISHEARD_CURRENCY_BEFORE_EACH.sub(r"\1 ringgit ", text)
    text = words_to_digits(text)
    text = _RINGGIT_MISHEARDS.sub("ringgit", text)
    text = _BAK_KUT_TEH_MISHEARDS.sub("Bak Kut Teh", text)
    text = normalise_chinese_money(text)
    # Collapse any doubled spaces the substitutions above may have left.
    return re.sub(r"[ \t]{2,}", " ", text).strip()


def transcribe_audio(
    audio_bytes: bytes, filename: str, language: str | None = None
) -> str:
    """Returns the transcribed text for a recorded voice message.

    `filename` is unused here (kept for interface parity with the previous
    API-based implementation) — faster-whisper decodes the audio via PyAV's
    bundled FFmpeg libraries directly from the in-memory buffer, with no
    format hint needed.

    `language` is an optional ISO 639-1 hint ('en', 'ms', 'zh') matching the
    Profile screen's "Voice input language" setting — biases decoding toward
    that language's phonetics/vocabulary for better accuracy on short clips.
    None (the default, "Auto-detect" in the UI) lets Whisper infer it from
    the audio itself, same as before this setting existed. This is only a
    HINT, not a validation: passing the wrong language for what was actually
    spoken never raises an error — Whisper still returns its best-effort
    transcription, just a less accurate one (it tries to force-fit the
    audio's actual phonetics into the hinted language's vocabulary).
    """
    model = _get_model()
    audio_io = io.BytesIO(audio_bytes)

    try:
        segments, _info = model.transcribe(
            audio_io,
            # Beam search keeps this many candidate hypotheses in memory
            # simultaneously. It used to drop to greedy (1) when hosted to
            # save memory, but that was the single biggest cause of the
            # garbled number+currency transcriptions this pipeline was
            # failing on ("thirty ringgit each" -> "Turing Gat Each"): on
            # the `tiny` model, greedy decoding has no fallback hypothesis
            # when the acoustics are ambiguous. 5 beams on `tiny`/`base`
            # int8 is a few MB, nowhere near the earlier OOM (that was a
            # much larger model plus a thread-per-core default) — accuracy
            # here is worth far more than that.
            beam_size=5,
            # Greedy temperature only; no temperature-fallback ladder that
            # can wander off into a hallucinated re-decode of a short clip.
            temperature=0,
            # THE fix for "it only breaks when I say the quantity first":
            # with this on (faster-whisper's default), the words already
            # decoded ("2 Uniqlo T-shirt") are fed back in as context and
            # bias what comes next, derailing the number+currency that
            # follows. Each short expense phrase is independent — there is
            # no cross-sentence context worth keeping here.
            condition_on_previous_text=False,
            initial_prompt=_prompt_for(language),
            language=language,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
    except Exception as e:
        raise WhisperTranscriptionError(f"Whisper transcription failed: {e}")

    if not text:
        raise WhisperTranscriptionError(
            "No speech detected — please try recording again."
        )
    return _clean_transcript(text)

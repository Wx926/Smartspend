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

from faster_whisper import WhisperModel

_model: WhisperModel | None = None

# Same RENDER-var check app.py already uses to distinguish the hosted free
# tier from local dev. Only the hosted tier gets the memory-constrained
# settings below -- local dev has its own "medium" model and ample RAM, and
# gains nothing from trading accuracy away.
_IS_HOSTED = os.environ.get("RENDER") is not None


class WhisperTranscriptionError(Exception):
    """Raised when the local model fails to transcribe the recording."""
    pass


def _get_model() -> WhisperModel:
    global _model
    if _model is None:
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
        _model = WhisperModel(
            size, device="cpu", compute_type="int8", cpu_threads=cpu_threads
        )
    return _model


# Nudges the model's vocabulary toward the domain this app actually records —
# Malaysian expense phrases — since a general-purpose small model otherwise
# tends to mishear "ringgit" as "ringit"/"ring get"/"ring gate" (confirmed
# empirically: without this prompt the same clip transcribes as "ringit").
# Chinese currency terms are included too so a code-switched "40 kuai KFC" has
# a chance of coming back with the correct characters.
_INITIAL_PROMPT = (
    "Malaysian expense note, amounts in ringgit (RM). "
    "Example: I spent RM 40 on lunch at KFC. Bought groceries at Aeon, RM 68. "
    "RM 80 shoes at Uniqlo. RM 15 for Bak Kut Teh. "
    "Also: 令吉, 块, Grab, McDonald's, Nando's, Uniqlo, Shopee, Lazada, Mydin, "
    "Watsons, Petronas, Tealive, Chagee, Bak Kut Teh, Char Kway Teow, Nasi Lemak, "
    "Roti Canai, Teh Tarik."
)

# Belt-and-suspenders: fixes the common near-miss spellings of "ringgit" that
# slip through even with the prompt above, so downstream amount parsing (which
# matches the literal word "ringgit") still recognises it.
_RINGGIT_MISHEARDS = re.compile(
    r"\bring\s*g?it\b|\bring\s*g?ate\b|\bring\s*get\b|\bwring\s*g?ate\b",
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
            # simultaneously -- a real multiplier against Render's 512MB
            # cap, and part of what's suspected to have caused the OOM
            # crash above. Dropped to greedy decoding (1) only when hosted;
            # local dev keeps the original 5 since it isn't memory-bound.
            # Also cuts inference time, which matters more here than the
            # marginal accuracy loss, now that the model itself is already
            # sized down to "tiny" for speed on this same free tier.
            beam_size=1 if _IS_HOSTED else 5,
            initial_prompt=_INITIAL_PROMPT,
            language=language,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
    except Exception as e:
        raise WhisperTranscriptionError(f"Whisper transcription failed: {e}")

    if not text:
        raise WhisperTranscriptionError(
            "No speech detected — please try recording again."
        )
    text = _RINGGIT_MISHEARDS.sub("ringgit", text)
    return _BAK_KUT_TEH_MISHEARDS.sub("Bak Kut Teh", text)

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


class WhisperTranscriptionError(Exception):
    """Raised when the local model fails to transcribe the recording."""
    pass


def _get_model() -> WhisperModel:
    global _model
    if _model is None:
        size = os.environ.get("WHISPER_MODEL_SIZE", "small")
        # int8 quantization keeps CPU inference fast with minimal accuracy loss.
        _model = WhisperModel(size, device="cpu", compute_type="int8")
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
    "RM 80 shoes at Uniqlo. "
    "Also: 令吉, 块, Grab, McDonald's, Nando's, Uniqlo, Shopee, Lazada, Mydin, "
    "Watsons, Petronas, Tealive, Chagee."
)

# Belt-and-suspenders: fixes the common near-miss spellings of "ringgit" that
# slip through even with the prompt above, so downstream amount parsing (which
# matches the literal word "ringgit") still recognises it.
_RINGGIT_MISHEARDS = re.compile(
    r"\bring\s*g?it\b|\bring\s*g?ate\b|\bring\s*get\b|\bwring\s*g?ate\b",
    re.IGNORECASE,
)


def transcribe_audio(audio_bytes: bytes, filename: str) -> str:
    """Returns the transcribed text for a recorded voice message.

    `filename` is unused here (kept for interface parity with the previous
    API-based implementation) — faster-whisper decodes the audio via PyAV's
    bundled FFmpeg libraries directly from the in-memory buffer, with no
    format hint needed.
    """
    model = _get_model()
    audio_io = io.BytesIO(audio_bytes)

    try:
        segments, _info = model.transcribe(
            audio_io, beam_size=5, initial_prompt=_INITIAL_PROMPT
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
    except Exception as e:
        raise WhisperTranscriptionError(f"Whisper transcription failed: {e}")

    if not text:
        raise WhisperTranscriptionError(
            "No speech detected — please try recording again."
        )
    return _RINGGIT_MISHEARDS.sub("ringgit", text)

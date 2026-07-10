from flask import Blueprint, request, jsonify

from services.voice_service import parse_voice_expense, VoiceParseError
from services.whisper_service import transcribe_audio, WhisperTranscriptionError

voice_bp = Blueprint("voice", __name__)


@voice_bp.route("/transcribe-voice", methods=["POST"])
def transcribe_voice():
    if "audio" not in request.files:
        return jsonify({"error": "No audio file provided. Use form field name 'audio'."}), 400

    file = request.files["audio"]
    if file.filename == "":
        return jsonify({"error": "Empty filename."}), 400

    audio_bytes = file.read()
    if not audio_bytes:
        return jsonify({"error": "Empty audio recording."}), 400

    try:
        transcript = transcribe_audio(audio_bytes, file.filename)
        return jsonify({"transcript": transcript}), 200

    except WhisperTranscriptionError as e:
        return jsonify({"error": str(e)}), 422

    except Exception as e:
        return jsonify({"error": f"Unexpected server error: {str(e)}"}), 500


@voice_bp.route("/parse-voice", methods=["POST"])
def parse_voice():
    data = request.get_json(silent=True) or {}
    transcript = (data.get("transcript") or "").strip()
    if not transcript:
        return jsonify({"error": "No transcript provided. Use JSON field 'transcript'."}), 400

    try:
        result = parse_voice_expense(transcript)
        return jsonify(result), 200

    except VoiceParseError as e:
        return jsonify({"error": str(e)}), 422

    except Exception as e:
        return jsonify({"error": f"Unexpected server error: {str(e)}"}), 500

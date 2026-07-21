import sys

from flask import Flask
from flask_cors import CORS
from dotenv import load_dotenv

from routes.ocr_routes import ocr_bp

# Windows' console defaults to cp1252, which can't encode arbitrary Unicode
# (e.g. receipt text with accented characters, or debug-log arrows) — that
# would otherwise crash print() calls and surface as a 500 error.
# line_buffering=True so debug prints (raw OCR text, extracted items) are
# flushed to the log immediately instead of sitting in an internal buffer
# until it fills up — otherwise they're invisible when stdout is redirected
# to a file rather than an interactive terminal.
sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
sys.stderr.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)

load_dotenv()

app = Flask(__name__)
CORS(app)

app.register_blueprint(ocr_bp, url_prefix="/api")

# The voice feature's faster-whisper -> av dependency chain loads a compiled
# .pyd that some machines' security policy (e.g. Windows Smart App Control)
# refuses to load, since it isn't signed to the level that policy demands.
# That's an environment problem, not a code bug, and must not take down the
# rest of the backend (OCR, warranty, etc.) — voice endpoints just won't be
# registered on a machine where this import fails.
try:
    from routes.voice_routes import voice_bp
    app.register_blueprint(voice_bp, url_prefix="/api")
except Exception as e:
    print(f"WARNING: voice routes disabled, failed to load: {e}")


@app.route("/health", methods=["GET"])
def health_check():
    return {"status": "ok", "message": "SmartSpend backend is running"}


if __name__ == "__main__":
    # host="0.0.0.0" so your physical phone (on same wifi) or emulator can hit it
    app.run(host="0.0.0.0", port=5000, debug=True)

import os
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
    from services.whisper_service import preload_model_async
    app.register_blueprint(voice_bp, url_prefix="/api")
    # Start loading the Whisper model now instead of on the first real
    # request -- see preload_model_async's own docstring for why this
    # specifically matters on Render's free tier (a cold start already pays
    # for container wake-up; without this, the first voice request ALSO
    # pays for the entire model load on top, in the same request budget).
    preload_model_async()
except Exception as e:
    print(f"WARNING: voice routes disabled, failed to load: {e}")


@app.route("/health", methods=["GET"])
def health_check():
    return {"status": "ok", "message": "SmartSpend backend is running"}


if __name__ == "__main__":
    # host="0.0.0.0" so your physical phone (on same wifi) or emulator can hit
    # it locally. PORT is read from the environment because a hosted platform
    # (e.g. Render) assigns its own port at runtime rather than letting the
    # app pick one — falls back to 5000 for local dev, unchanged from before.
    # Flask's debug mode (auto-reloader + interactive in-browser debugger) is
    # fine on your own machine but must be off once this is reachable from
    # the public internet — RENDER is a variable Render itself sets in every
    # deployed service's environment, so this only flips for that case; local
    # `python app.py` behaves exactly as it always has.
    port = int(os.environ.get("PORT", 5000))
    is_hosted = os.environ.get("RENDER") is not None
    app.run(host="0.0.0.0", port=port, debug=not is_hosted)

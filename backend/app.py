from flask import Flask
from flask_cors import CORS
from dotenv import load_dotenv

from routes.ocr_routes import ocr_bp

load_dotenv()

app = Flask(__name__)
CORS(app)

app.register_blueprint(ocr_bp, url_prefix="/api")


@app.route("/health", methods=["GET"])
def health_check():
    return {"status": "ok", "message": "SmartSpend backend is running"}


if __name__ == "__main__":
    # host="0.0.0.0" so your physical phone (on same wifi) or emulator can hit it
    app.run(host="0.0.0.0", port=5000, debug=True)

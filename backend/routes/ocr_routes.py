from flask import Blueprint, request, jsonify

from services.ocr_service import (
    process_receipt,
    OcrValidationError,
    OcrExtractionError,
)

ocr_bp = Blueprint("ocr", __name__)


@ocr_bp.route("/scan-receipt", methods=["POST"])
def scan_receipt():
    if "image" not in request.files:
        return jsonify({"error": "No image file provided. Use form field name 'image'."}), 400

    file = request.files["image"]
    if file.filename == "":
        return jsonify({"error": "Empty filename."}), 400

    image_bytes = file.read()
    file_size_bytes = len(image_bytes)

    try:
        result = process_receipt(file.filename, file_size_bytes, image_bytes)
        return jsonify(result), 200

    except OcrValidationError as e:
        return jsonify({"error": str(e)}), 400

    except OcrExtractionError as e:
        return jsonify({"error": str(e)}), 422

    except Exception as e:
        # Catch-all so the phone always gets a JSON response, never a raw 500 crash
        return jsonify({"error": f"Unexpected server error: {str(e)}"}), 500

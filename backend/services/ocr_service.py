"""
OCR-Based Receipt Digitisation Pipeline (FYP report Chapter 3.1.2 / Algorithm 1).

Stage 1: Image Input and Validation
Stage 2: Image Preprocessing via OpenCV
Stage 3: Text Extraction via Tesseract OCR
Stage 4: Post-Processing and Data Structure (regex for vendor/date/amount + warranty scan)
Stage 5: Warranty Validity Assessment  (delegated to warranty_service)
"""

import re
import cv2
import numpy as np
import pytesseract
from datetime import datetime, date

from services.categorisation_service import categorise_text
from services.warranty_service import detect_warranty

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "pdf"}
MAX_FILE_SIZE_MB = 10

AMOUNT_PATTERN = re.compile(r"(?:RM|MYR)?\s*(\d+[.,]\d{2})", re.IGNORECASE)
DATE_PATTERNS = [
    r"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})",   # 27/06/2026 or 27-06-26
    r"(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})",     # 2026-06-27
]


class OcrValidationError(Exception):
    """Raised when the uploaded file fails Stage 1 validation."""
    pass


class OcrExtractionError(Exception):
    """Raised when Tesseract fails to extract usable text (Stage 3)."""
    pass


# ─── Stage 1: Image Input and Validation ────────────────────────────────────
def validate_image(filename: str, file_size_bytes: int) -> None:
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise OcrValidationError(
            f"Unsupported file format '.{extension}'. Use PNG, JPG, JPEG, or PDF."
        )

    size_mb = file_size_bytes / (1024 * 1024)
    if size_mb > MAX_FILE_SIZE_MB:
        raise OcrValidationError(
            f"File too large ({size_mb:.1f}MB). Max allowed is {MAX_FILE_SIZE_MB}MB."
        )


# ─── Stage 2: Image Preprocessing via OpenCV ────────────────────────────────
def preprocess_image(image_bytes: bytes) -> np.ndarray:
    np_array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(np_array, cv2.IMREAD_COLOR)

    if image is None:
        raise OcrValidationError("Could not decode image — file may be corrupted.")

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    thresholded = cv2.adaptiveThreshold(
        blurred, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 10
    )

    # Skew correction
    coords = np.column_stack(np.where(thresholded > 0))
    if len(coords) > 0:
        angle = cv2.minAreaRect(coords)[-1]
        angle = -(90 + angle) if angle < -45 else -angle
        (h, w) = thresholded.shape
        center = (w // 2, h // 2)
        rotation_matrix = cv2.getRotationMatrix2D(center, angle, 1.0)
        thresholded = cv2.warpAffine(
            thresholded, rotation_matrix, (w, h),
            flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE,
        )

    return thresholded


# ─── Stage 3: Text Extraction via Tesseract OCR ─────────────────────────────
def extract_text(preprocessed_image: np.ndarray) -> str:
    raw_text = pytesseract.image_to_string(preprocessed_image)

    if not raw_text or not raw_text.strip():
        raise OcrExtractionError(
            "No text detected — image may be too blurry, faded, or crumpled. "
            "Please retake the photo."
        )

    return raw_text


# ─── Stage 4: Post-Processing and Data Structure ────────────────────────────
def parse_receipt_fields(raw_text: str) -> dict:
    lines = [line.strip() for line in raw_text.splitlines() if line.strip()]

    amount = _extract_amount(raw_text)
    receipt_date = _extract_date(raw_text)
    vendor_name = _extract_vendor(lines)

    return {
        "vendor_name": vendor_name,
        "amount": amount,
        "date": receipt_date.isoformat() if receipt_date else None,
        "_date_obj": receipt_date,  # internal use for warranty calc, stripped before response
    }


def _extract_amount(raw_text: str) -> float | None:
    """
    Picks the largest matched amount, since receipts usually list several
    smaller line-item amounts plus one larger total near the bottom.
    """
    matches = AMOUNT_PATTERN.findall(raw_text)
    if not matches:
        return None
    amounts = [float(m.replace(",", ".")) for m in matches]
    return max(amounts)


def _extract_date(raw_text: str) -> date | None:
    for pattern in DATE_PATTERNS:
        match = re.search(pattern, raw_text)
        if match:
            date_str = match.group(1)
            for fmt in ("%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d-%m-%y",
                        "%Y/%m/%d", "%Y-%m-%d"):
                try:
                    return datetime.strptime(date_str, fmt).date()
                except ValueError:
                    continue
    return None


def _extract_vendor(lines: list[str]) -> str | None:
    """
    Heuristic: vendor name is usually one of the first 1-3 non-empty lines,
    before any address/amount lines appear. Refine this once you test with
    real receipts from your phone.
    """
    for line in lines[:3]:
        if not re.search(r"\d{3,}", line):  # skip lines that look like addresses/phone numbers
            return line
    return lines[0] if lines else None


# ─── Orchestration: runs all 5 stages ───────────────────────────────────────
def process_receipt(filename: str, file_size_bytes: int, image_bytes: bytes) -> dict:
    validate_image(filename, file_size_bytes)

    preprocessed = preprocess_image(image_bytes)
    raw_text = extract_text(preprocessed)
    parsed = parse_receipt_fields(raw_text)

    receipt_date = parsed.pop("_date_obj") or date.today()
    warranty_info = detect_warranty(raw_text, receipt_date)

    category_result = categorise_text(parsed["vendor_name"] or "")

    return {
        "vendor_name": parsed["vendor_name"],
        "amount": parsed["amount"],
        "date": parsed["date"],
        "raw_text": raw_text,
        "suggested_category_id": category_result["category_id"],
        "suggested_category_name": category_result["category_name"],
        "warranty": warranty_info,  # None if no warranty detected
    }

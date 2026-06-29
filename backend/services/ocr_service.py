"""
OCR-Based Receipt Digitisation Pipeline (FYP report Chapter 3.1.2 / Algorithm 1).

Stage 1: Image Input and Validation
Stage 2: Image Preprocessing via OpenCV
Stage 3: Text Extraction via Tesseract OCR (LSTM engine --oem 1 --psm 6)
Stage 4: Post-Processing and Data Structure (regex for vendor/date/amount + line items + warranty scan)
Stage 5: Warranty Validity Assessment  (delegated to warranty_service)
"""

import io
import re
import cv2
import numpy as np
import pytesseract
from datetime import datetime, date

pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

from services.categorisation_service import categorise_text
from services.warranty_service import detect_warranty

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "pdf"}
MAX_FILE_SIZE_MB = 10

AMOUNT_PATTERN = re.compile(
    r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*(\d+[.,]\d{2})",
    re.IGNORECASE,
)
DATE_PATTERNS = [
    r"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})",   # 27/06/2026 or 27-06-26
    r"(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})",     # 2026-06-27
]

# FR 4.6: matches "Item Name    5.00" or "Item Name  RM5.00" or "Item  $5.00" (2+ spaces before price)
_CURRENCY = r"(?:RM|MYR|USD|SGD|GBP|\$|£|€|¥)?\s*"
LINE_ITEM_PATTERN = re.compile(
    rf"^([\w][\w\s\-&'\/\(\)]*?)\s{{2,}}{_CURRENCY}(\d+[.,]\d{{2}})\s*$",
    re.IGNORECASE,
)

# Lines containing these words are totals/summaries, not individual items
SKIP_KEYWORDS = re.compile(
    r"\b(total|subtotal|sub-total|tax|gst|sst|service\s*charge|discount|"
    r"change|cash|rounding|amount\s*due|balance|tip|gratuity|receipt|invoice)\b",
    re.IGNORECASE,
)


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


# ─── PDF → image conversion (FR 4.2) ────────────────────────────────────────
def _pdf_to_image_bytes(pdf_bytes: bytes) -> bytes:
    from pdf2image import convert_from_bytes
    images = convert_from_bytes(pdf_bytes, first_page=1, last_page=1, dpi=200)
    if not images:
        raise OcrValidationError("Could not extract a page from the PDF.")
    buf = io.BytesIO()
    images[0].save(buf, format="PNG")
    return buf.getvalue()


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
    # --oem 1: LSTM-only engine (per report Sections 2.2.3, 2.2.4, 3.1.2, 4.8.1)
    # --psm 6: treat image as a uniform block of text — appropriate for receipts
    raw_text = pytesseract.image_to_string(
        preprocessed_image, config="--oem 1 --psm 6"
    )

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
    line_items = _extract_line_items(raw_text)  # FR 4.6

    return {
        "vendor_name": vendor_name,
        "amount": amount,
        "date": receipt_date.isoformat() if receipt_date else None,
        "line_items": line_items,
        "_date_obj": receipt_date,  # internal use for warranty calc, stripped before response
    }


def _extract_amount(raw_text: str) -> float | None:
    """
    Picks the largest matched amount — receipts list smaller line-item amounts
    plus one larger total, so max() reliably selects the total (FR 4.10).
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
    before any address/amount lines appear.
    """
    for line in lines[:3]:
        if not re.search(r"\d{3,}", line):  # skip lines that look like addresses/phone numbers
            return line
    return lines[0] if lines else None


def _extract_line_items(raw_text: str) -> list[dict]:
    """
    FR 4.6: Extracts individual line items (item name + price) from receipt text.
    Skips total, tax, discount, and other summary lines.
    Each item has two or more spaces before the price, which is how
    receipt printers align item names and prices in columns.
    """
    items = []
    for line in raw_text.splitlines():
        line = line.strip()
        if not line or SKIP_KEYWORDS.search(line):
            continue
        match = LINE_ITEM_PATTERN.match(line)
        if match:
            item_name = match.group(1).strip()
            price = float(match.group(2).replace(",", "."))
            if item_name and price > 0:
                items.append({"item_name": item_name, "price": price})
    return items


# ─── Orchestration: runs all 5 stages ───────────────────────────────────────
def process_receipt(filename: str, file_size_bytes: int, image_bytes: bytes) -> dict:
    validate_image(filename, file_size_bytes)

    # FR 4.2: convert PDF to a raster image before preprocessing
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if extension == "pdf":
        image_bytes = _pdf_to_image_bytes(image_bytes)

    preprocessed = preprocess_image(image_bytes)
    raw_text = extract_text(preprocessed)
    parsed = parse_receipt_fields(raw_text)

    receipt_date = parsed.pop("_date_obj") or date.today()
    warranty_info = detect_warranty(raw_text, receipt_date)

    # FR 4.8: assign a category to each line item based on its description
    line_items_with_categories = [
        {
            "item_name": item["item_name"],
            "price": item["price"],
            "category_id": (cat := categorise_text(item["item_name"]))["category_id"],
            "category_name": cat["category_name"],
        }
        for item in parsed["line_items"]
    ]

    # Receipt-level category derived from vendor name (fallback when no line items)
    receipt_category = categorise_text(parsed["vendor_name"] or "")

    return {
        "vendor_name": parsed["vendor_name"],
        "amount": parsed["amount"],                     # FR 4.10: receipt total summary
        "date": parsed["date"],
        "raw_text": raw_text,
        "line_items": line_items_with_categories,       # FR 4.6, 4.7, 4.8, 4.9
        "suggested_category_id": receipt_category["category_id"],
        "suggested_category_name": receipt_category["category_name"],
        "warranty": warranty_info,
    }

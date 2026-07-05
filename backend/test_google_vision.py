"""
Test Google Cloud Vision API on a receipt image.
Run: python test_google_vision.py YOUR_API_KEY path/to/receipt.jpg
"""
import sys
import base64
import json
import urllib.request


def test_google_vision(api_key: str, image_path: str):
    with open(image_path, "rb") as f:
        image_b64 = base64.b64encode(f.read()).decode()

    payload = json.dumps({
        "requests": [{
            "image": {"content": image_b64},
            "features": [{"type": "DOCUMENT_TEXT_DETECTION"}]
        }]
    }).encode()

    url = f"https://vision.googleapis.com/v1/images:annotate?key={api_key}"
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())

    text = result["responses"][0].get("fullTextAnnotation", {}).get("text", "")
    print("\n===== GOOGLE VISION RAW TEXT =====")
    print(text)
    print("==================================")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python test_google_vision.py <API_KEY> <image_path>")
        sys.exit(1)

    api_key = sys.argv[1]
    image_path = sys.argv[2]

    print(f"Testing on: {image_path}")
    test_google_vision(api_key, image_path)

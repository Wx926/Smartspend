// Tests for OcrResult/OcrLineItem JSON parsing -- this is the exact
// contract between the Python backend and the Flutter app, so a silent
// mismatch here (a renamed field, a type that stops matching) would break
// every OCR/voice result without necessarily throwing anywhere obvious.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/ocr/models/ocr_result.dart';

void main() {
  group('OcrResult.fromJson', () {
    test('parses a full regex-extraction response', () {
      final result = OcrResult.fromJson({
        'vendor_name': 'KFC',
        'amount': 25.0,
        'date': '2026-08-25',
        'raw_text': 'raw ocr text here',
        'line_items': [
          {
            'item_name': 'Zinger Burger',
            'price': 25.0,
            'quantity': 1,
            'category_id': 'cat-1',
            'category_name': 'Food & Dining',
          }
        ],
        'suggested_category_id': 'cat-1',
        'suggested_category_name': 'Food & Dining',
        'suggested_category_confidence': 'high',
        'date_confidence': 'high',
        'items_confidence': 'high',
        'extraction_method': 'regex',
        'warranty': null,
      });

      expect(result.vendorName, 'KFC');
      expect(result.amount, 25.0);
      expect(result.lineItems, hasLength(1));
      expect(result.lineItems.first.itemName, 'Zinger Burger');
      expect(result.extractionMethod, 'regex');
      expect(result.warranty, isNull);
    });

    test('parses a gemini_fallback response with warranty attached', () {
      final result = OcrResult.fromJson({
        'vendor_name': 'TMT Thunder Match Technology',
        'amount': 539.0,
        'date': '2024-07-14',
        'raw_text': 'raw text',
        'line_items': [
          {'item_name': 'SSD Samsung 1TB', 'price': 499.0, 'quantity': 1, 'category_name': 'Shopping'},
          {'item_name': 'Service Charges', 'price': 40.0, 'quantity': 1, 'category_name': 'Others'},
        ],
        'suggested_category_id': null,
        'suggested_category_name': 'Shopping',
        'suggested_category_confidence': 'high',
        'date_confidence': 'high',
        'items_confidence': 'high',
        'extraction_method': 'gemini_fallback',
        'warranty': {
          'has_warranty': true,
          'duration_months': 60,
          'expiry_date': '2029-07-14',
          'status': 'green',
          'days_remaining': 1000,
        },
      });

      expect(result.extractionMethod, 'gemini_fallback');
      expect(result.lineItems, hasLength(2));
      expect(result.warranty, isNotNull);
      expect(result.warranty!.durationMonths, 60);
      expect(result.warranty!.status, 'green');
    });

    test('missing optional fields default safely instead of throwing', () {
      // A minimal, mostly-empty response (e.g. a photo that barely
      // qualified as a receipt) must not crash the review screen.
      final result = OcrResult.fromJson({
        'raw_text': null,
        'line_items': null,
      });

      expect(result.rawText, ''); // null coalesces to empty, not a crash
      expect(result.lineItems, isEmpty);
      expect(result.vendorName, isNull);
      expect(result.itemsConfidence, isNull);
      expect(result.warranty, isNull);
    });

    test('a missing items_confidence is null, not a false "high"', () {
      // Regression guard: the Flutter side must treat a MISSING
      // items_confidence as untrustworthy, not silently green-light it --
      // confirmed real bug where voice_service originally never set this
      // field at all, and the UI defaulted to trusting it.
      final result = OcrResult.fromJson({
        'raw_text': 'x',
        'line_items': [],
      });
      expect(result.itemsConfidence, isNull);
    });
  });

  group('OcrLineItem.fromJson', () {
    test('quantity defaults to 1 when absent', () {
      final item = OcrLineItem.fromJson({'item_name': 'Item', 'price': 5.0});
      expect(item.quantity, 1);
    });

    test('category_name defaults to Others when absent', () {
      final item = OcrLineItem.fromJson({'item_name': 'Item', 'price': 5.0});
      expect(item.categoryName, 'Others');
    });

    test('integer price in JSON still parses as a double', () {
      // Backends can legally send a whole-number amount as a JSON integer
      // (e.g. `"price": 5` not `5.0`) -- must not throw a type cast error.
      final item = OcrLineItem.fromJson({'item_name': 'Item', 'price': 5});
      expect(item.price, 5.0);
    });
  });
}

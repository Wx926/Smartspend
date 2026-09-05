import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../models/ocr_result.dart';
import '../../../shared/services/backend_connection.dart';

class OcrApiException implements Exception {
  final String message;
  const OcrApiException(this.message);

  @override
  String toString() => message;
}

class OcrApiService {
  OcrApiService._();
  static final OcrApiService instance = OcrApiService._();

  final _picker = ImagePicker();

  Future<XFile?> pickFromCamera() =>
      _picker.pickImage(source: ImageSource.camera, imageQuality: 90);

  Future<OcrResult> scanReceipt(XFile file) async {
    final http.StreamedResponse streamed;
    try {
      streamed = await BackendConnection.instance.send(
        (baseUrl) async {
          final uri = Uri.parse('$baseUrl/api/scan-receipt');
          return http.MultipartRequest('POST', uri)
            ..files.add(await http.MultipartFile.fromPath(
              'image',
              file.path,
              filename: file.name,
            ));
        },
        // 150s, not 90 — confirmed by real testing close to submission: the
        // first scan after the backend goes idle consistently FAILED
        // outright at 90s, not just felt slow, then succeeded immediately on
        // a second attempt once the instance was warm. 90s budgeted "50s
        // wake + the rest for OCR/Gemini work", but that only leaves ~40s for
        // Vision + (when confidence is low) a second Gemini call on top —
        // not enough margin when the actual cold-start time runs past
        // Render's own "50+ seconds" estimate, which real testing shows it
        // regularly does. 150s keeps a real cold start a first-try success
        // instead of a guaranteed-fail-then-retry, matching what the README
        // promises users ("first request is slow, not broken").
        timeout: const Duration(seconds: 150),
      );
    } on BackendUnreachableException catch (e) {
      throw OcrApiException(e.message);
    }

    final body = await streamed.stream.bytesToString();
    final json = jsonDecode(body) as Map<String, dynamic>;

    if (streamed.statusCode != 200) {
      throw OcrApiException(json['error'] as String? ?? 'Scan failed.');
    }

    return OcrResult.fromJson(json);
  }
}

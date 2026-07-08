import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../ocr/models/ocr_result.dart';
import '../../../shared/constants/app_constants.dart';

class VoiceApiException implements Exception {
  final String message;
  const VoiceApiException(this.message);

  @override
  String toString() => message;
}

class VoiceApiService {
  VoiceApiService._();
  static final VoiceApiService instance = VoiceApiService._();

  /// Stage 2 (FYP report Ch. 3.1.3): uploads the recorded voice message to
  /// the backend, which transcribes it via the WhisperAI API, and returns
  /// the resulting text.
  Future<String> transcribeAudio(File audioFile) async {
    final uri = Uri.parse('${AppConstants.ocrBackendUrl}/api/transcribe-voice');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('audio', audioFile.path));

    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final body = await streamed.stream.bytesToString();
    final json = jsonDecode(body) as Map<String, dynamic>;

    if (streamed.statusCode != 200) {
      throw VoiceApiException(
          json['error'] as String? ?? 'Could not transcribe the recording.');
    }

    return json['transcript'] as String? ?? '';
  }

  /// Stage 3/4 (FYP report Ch. 3.1.3): sends the transcript to the backend's
  /// rule-based NLP parser and gets back the same shape scan-receipt
  /// returns (vendor/amount/date/category/line items), so the result can be
  /// reviewed in the same ReceiptReviewScreen.
  Future<OcrResult> parseTranscript(String transcript) async {
    final uri = Uri.parse('${AppConstants.ocrBackendUrl}/api/parse-voice');
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'transcript': transcript}),
        )
        .timeout(const Duration(seconds: 15));

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw VoiceApiException(json['error'] as String? ?? 'Could not understand that.');
    }

    return OcrResult.fromJson(json);
  }
}

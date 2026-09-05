import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../ocr/models/ocr_result.dart';
import '../../../shared/services/backend_connection.dart';

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
  /// [language] is an optional ISO 639-1 hint ('en', 'ms', 'zh') from the
  /// Profile screen's "Voice input language" setting, or 'auto'/null to let
  /// Whisper auto-detect — see whisper_service.transcribe_audio's docstring
  /// for why a mismatched hint degrades accuracy but never errors.
  Future<String> transcribeAudio(File audioFile, {String? language}) async {
    final http.StreamedResponse streamed;
    try {
      streamed = await BackendConnection.instance.send(
        (baseUrl) async {
          final uri = Uri.parse('$baseUrl/api/transcribe-voice');
          return http.MultipartRequest('POST', uri)
            ..fields['language'] = language ?? 'auto'
            ..files.add(
                await http.MultipartFile.fromPath('audio', audioFile.path));
        },
        // 150s — same real-world evidence as ocr_api_service.dart's
        // scanReceipt (see its comment): 90s consistently failed the first
        // recording after the backend went idle, succeeding immediately on
        // retry once warm. Voice has LESS margin than OCR at the same
        // timeout, not more: on top of the shared container cold-start,
        // whisper_service.py lazy-loads the actual Whisper model on its
        // first call ever (`_model is None` check) rather than at server
        // startup, so the very first transcription pays for model
        // load AND cold start AND transcription, all inside one budget.
        timeout: const Duration(seconds: 150),
      );
    } on BackendUnreachableException catch (e) {
      throw VoiceApiException(e.message);
    }

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
    final http.StreamedResponse streamed;
    try {
      streamed = await BackendConnection.instance.send(
        (baseUrl) async {
          final uri = Uri.parse('$baseUrl/api/parse-voice');
          final request = http.Request('POST', uri);
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode({'transcript': transcript});
          return request;
        },
        // 90s, not 60 — this call can still land on a cold instance if it's
        // the first request of a session (e.g. a manually-typed transcript
        // submitted without a prior transcribeAudio call to warm it up).
        // Raised alongside the other two timeouts in this file/scanReceipt
        // after 90s (this call's old budget was 60s) proved to consistently
        // fail a genuine cold start rather than just run slow.
        timeout: const Duration(seconds: 90),
      );
    } on BackendUnreachableException catch (e) {
      throw VoiceApiException(e.message);
    }

    final body = await streamed.stream.bytesToString();
    final json = jsonDecode(body) as Map<String, dynamic>;

    if (streamed.statusCode != 200) {
      throw VoiceApiException(json['error'] as String? ?? 'Could not understand that.');
    }

    return OcrResult.fromJson(json);
  }
}

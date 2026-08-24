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
        timeout: const Duration(seconds: 30),
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

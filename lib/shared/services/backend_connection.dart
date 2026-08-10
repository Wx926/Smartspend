import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';

/// Thrown when none of the candidate backend addresses could be reached —
/// callers should catch this alongside their own domain exception type and
/// re-wrap it, since [BackendConnection] is shared across features and
/// deliberately doesn't know about OcrApiException/VoiceApiException.
class BackendUnreachableException implements Exception {
  final String message;
  const BackendUnreachableException(this.message);

  @override
  String toString() => message;
}

/// Tries several candidate backend addresses in order rather than trusting
/// a single hardcoded OCR_BACKEND_URL. A local dev backend is genuinely
/// reachable through more than one path depending on the moment — USB with
/// `adb reverse tcp:5000 tcp:5000` set up, or the same-WiFi LAN IP — and
/// campus/public WiFi in particular can silently block the LAN-IP path via
/// firewall or AP isolation with no way to detect that in advance from the
/// app alone. Remembers whichever address last worked so later calls in the
/// same session go straight to it instead of re-probing the dead ones.
class BackendConnection {
  BackendConnection._();
  static final instance = BackendConnection._();

  String? _lastWorkingBaseUrl;

  List<String> get _candidates {
    final ordered = <String>[
      if (_lastWorkingBaseUrl != null) _lastWorkingBaseUrl!,
      // Works when the phone is on USB with `adb reverse` set up —
      // bypasses WiFi/firewall/AP-isolation entirely.
      'http://localhost:5000',
      // Whatever's configured in .env — typically the PC's LAN IP, works
      // when phone and PC are genuinely reachable over the same WiFi.
      AppConstants.ocrBackendUrl,
      // Android emulator's alias for the host machine's own localhost —
      // harmless to include on a real device (it just won't resolve
      // there), useful when testing on an emulator with no .env override.
      'http://10.0.2.2:5000',
    ];
    final seen = <String>{};
    return ordered.where((u) => seen.add(u)).toList();
  }

  /// [buildRequest] must build a FRESH request each call — a request whose
  /// body reads from a file (e.g. MultipartRequest) can only be sent once,
  /// so it can't be reused across fallback attempts.
  Future<http.StreamedResponse> send(
    Future<http.BaseRequest> Function(String baseUrl) buildRequest, {
    required Duration timeout,
  }) async {
    final candidates = _candidates;
    Object? lastError;

    for (var i = 0; i < candidates.length; i++) {
      final baseUrl = candidates[i];
      final isLast = i == candidates.length - 1;
      // A candidate we have positive evidence for — the USB/`adb reverse`
      // tunnel (reliable whenever it's set up at all; it fails instantly
      // with ECONNREFUSED rather than hanging when it isn't) or whichever
      // address actually worked last call — gets the FULL requested timeout
      // too, not just the last one in the list. Without this, a slow-but-
      // genuinely-working request (e.g. OCR that trips the Gemini vision
      // fallback on top of the Vision API call, easily >6s combined) gets
      // its correct candidate abandoned mid-flight by the short defensive
      // cap below, wasting the rest of the budget on candidates that were
      // never going to work anyway (confirmed: a scan that needed the
      // Gemini fallback timed out on `localhost:5000` at 6s and reported
      // "tried 3", even though the backend log showed that exact request
      // completing successfully a moment later).
      final trusted = baseUrl == 'http://localhost:5000' || baseUrl == _lastWorkingBaseUrl;
      // Only a genuinely unproven candidate (typically the WiFi LAN-IP
      // fallback, or the emulator-only 10.0.2.2 alias) gets bounded short —
      // long enough to tell "dead" from "slow but working" before moving on,
      // so a broken WiFi path (which, under AP isolation, can hang rather
      // than fail fast) can't eat most of the operation's time budget before
      // ever reaching the path that works.
      final attemptTimeout = isLast || trusted || timeout <= const Duration(seconds: 6)
          ? timeout
          : const Duration(seconds: 6);
      try {
        final request = await buildRequest(baseUrl);
        final response = await request.send().timeout(attemptTimeout);
        _lastWorkingBaseUrl = baseUrl;
        return response;
      } on TimeoutException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      }
    }

    // The remembered address just failed too (if it was even in the list) —
    // don't keep steering future calls toward a dead host.
    _lastWorkingBaseUrl = null;
    throw BackendUnreachableException(
      'Could not reach the backend on any known address (tried '
      '${candidates.length}). Make sure the Flask server is running, and '
      'that your phone is either on the same WiFi as your PC or connected '
      'via USB with `adb reverse` set up.'
      '${lastError != null ? '\n\nLast error: $lastError' : ''}',
    );
  }
}

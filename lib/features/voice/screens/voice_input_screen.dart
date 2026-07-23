import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../ocr/screens/receipt_review_screen.dart';
import '../services/voice_api_service.dart';

/// A few canned phrases the "Demo" button cycles through — lets the feature
/// be shown end-to-end when the mic/network isn't available (e.g. during a
/// live demo), and doubles as the FR 5.12/5.13 fallback path.
const _demoPhrases = [
  'I spent RM 25 on lunch at KFC',
  'RM 12.50 for Grab to KLCC today',
  'Bought groceries at Aeon, RM 68',
];

/// Voice-Assisted Expense Categorisation — Stage 1 (FYP report Ch. 3.1.3):
/// records a voice message, uploads it for WhisperAI transcription, then
/// hands the transcript to the backend's rule-based NLP parser before
/// landing on the same review/confirm screen OCR scans use.
class VoiceInputScreen extends StatefulWidget {
  const VoiceInputScreen({super.key});

  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends State<VoiceInputScreen>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _transcriptCtrl = TextEditingController();
  late final AnimationController _pulseCtrl;

  bool _recording = false;
  bool _transcribing = false;
  bool _processing = false;
  int _demoIndex = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _transcriptCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  bool get _busy => _recording || _transcribing || _processing;

  /// FR 5.1: tapping the mic immediately starts recording a voice message.
  /// Tapping again stops it and kicks off transcription (Stage 2).
  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopAndTranscribe();
      return;
    }

    setState(() => _error = null);

    if (!await _recorder.hasPermission()) {
      setState(() => _error =
          'Microphone permission was denied — try the Demo button instead, or type in the box below.');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_input_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _recording = true;
      _transcriptCtrl.clear();
    });
  }

  Future<void> _stopAndTranscribe() async {
    // Flip to "transcribing" the instant the user asks to stop, rather than
    // waiting on the native stop() call to resolve first — on some devices/
    // emulators the underlying MediaRecorder can stall for several seconds
    // (or, rarely, hang indefinitely), which would otherwise leave the UI
    // stuck showing "Recording…" with no feedback and no way to recover.
    setState(() {
      _recording = false;
      _transcribing = true;
    });

    String? path;
    try {
      // A hung native stop() must not be able to strand the user here
      // forever (FR 5.12/5.13) — give up after 10s and surface it as a
      // failed recording so they can immediately retry or use Demo.
      path = await _recorder.stop().timeout(const Duration(seconds: 10));
    } catch (_) {
      path = null;
    }

    // FR 5.12: a clear error message if the recording/transcription fails.
    if (path == null) {
      setState(() {
        _transcribing = false;
        _error =
            'Recording failed — try the Demo button instead, or type in the box below.';
      });
      return;
    }

    try {
      final transcript = await VoiceApiService.instance.transcribeAudio(File(path));
      if (!mounted) return;
      setState(() => _transcriptCtrl.text = transcript);
    } on VoiceApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error =
          'Could not reach the server. Make sure the Flask backend is running.');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  void _runDemo() {
    setState(() {
      _transcriptCtrl.text = _demoPhrases[_demoIndex % _demoPhrases.length];
      _demoIndex++;
      _error = null;
    });
    _submit();
  }

  /// Stage 3/4 + 5: parses the transcript (description/amount/category) and
  /// opens the pre-filled confirmation screen.
  Future<void> _submit() async {
    final transcript = _transcriptCtrl.text.trim();
    if (transcript.isEmpty || _processing) return;

    if (_recording) {
      try {
        await _recorder.stop().timeout(const Duration(seconds: 10));
      } catch (_) {
        // Ignore — we're discarding the recording in favour of the typed/
        // demo transcript anyway, so a stuck or failed stop() is harmless.
      }
    }
    setState(() {
      _recording = false;
      _processing = true;
      _error = null;
    });

    try {
      final result = await VoiceApiService.instance.parseTranscript(transcript);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReceiptReviewScreen(result: result, source: 'voice'),
        ),
      );
      // On return from review (saved or backed out), clear so the screen is
      // ready for another voice entry rather than showing stale text.
      if (mounted) setState(() => _transcriptCtrl.clear());
    } on VoiceApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error =
          'Could not reach the server. Make sure the Flask backend is running.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTranscript = _transcriptCtrl.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        title: const Text('Voice Input',
            style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('AI Powered',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            // The two Spacers below need a bounded height to distribute —
            // impossible inside a plain SingleChildScrollView (unbounded),
            // so this forces the Column to be at least as tall as the
            // visible area (letting Spacer behave exactly as before with
            // room to spare) while still allowing it to grow taller and
            // scroll on the rare occasion it doesn't fit (e.g. the on-screen
            // keyboard opening and eating a big chunk of the vertical space).
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    _tipCard(),
                    const SizedBox(height: 12),
                    if (_error != null) _errorBanner(),
                    const Spacer(),
                    _micButton(),
                    const SizedBox(height: 20),
                    Text(
                      _recording
                          ? 'Recording… tap to stop'
                          : _transcribing
                              ? 'Transcribing…'
                              : 'Tap to speak',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppColors.primaryDark),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap the mic and describe your expense',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                    const Spacer(),
                    _transcriptBox(),
                    const SizedBox(height: 16),
                    _bottomButtons(hasTranscript),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tipCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primarySurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(
              children: [
                Text('💡', style: TextStyle(fontSize: 14)),
                SizedBox(width: 6),
                Text('Try saying:',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.primaryDark)),
              ],
            ),
            SizedBox(height: 6),
            Text('"I spent RM 25 on lunch at KFC"',
                style: TextStyle(fontSize: 12, color: AppColors.primaryDark)),
            Text('"RM 12.50 for Grab to KLCC today"',
                style: TextStyle(fontSize: 12, color: AppColors.primaryDark)),
            Text('"Bought groceries at Aeon, RM 68"',
                style: TextStyle(fontSize: 12, color: AppColors.primaryDark)),
          ],
        ),
      );

  Widget _errorBanner() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.alertRedBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.budgetRed, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!,
                  style: const TextStyle(
                      color: AppColors.budgetRed, fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _micButton() {
    return GestureDetector(
      onTap: (_transcribing || _processing) ? null : _toggleRecording,
      child: SizedBox(
        width: 160,
        height: 160,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_recording) ...[
              _ripple(delay: 0),
              _ripple(delay: 0.33),
              _ripple(delay: 0.66),
            ],
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: _transcribing
                  ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: Colors.white),
                    )
                  : Icon(
                      _recording ? Icons.mic : Icons.mic_none_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ripple({required double delay}) {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, child) {
        final t = (_pulseCtrl.value + delay) % 1.0;
        return Opacity(
          opacity: (1 - t) * 0.35,
          child: Transform.scale(
            scale: 0.6 + t * 0.7,
            child: child,
          ),
        );
      },
      child: Container(
        width: 160,
        height: 160,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _transcriptBox() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('TRANSCRIPT',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.5)),
            const SizedBox(height: 8),
            TextField(
              controller: _transcriptCtrl,
              maxLines: 3,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Your speech will appear here…',
                hintStyle: TextStyle(color: Color(0xFFAAAAAA)),
              ),
            ),
          ],
        ),
      );

  Widget _bottomButtons(bool hasTranscript) => Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryDark,
                side: const BorderSide(color: AppColors.primaryDark),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('← Back'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _busy
                  ? null
                  : hasTranscript
                      ? _submit
                      : _runDemo,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryDark,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _processing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(hasTranscript ? 'Continue' : '▶ Demo'),
            ),
          ),
        ],
      );
}

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../shared/theme/app_colors.dart';
import '../services/ocr_api_service.dart';
import '../models/ocr_result.dart';
import 'receipt_review_screen.dart';

class ScanReceiptScreen extends StatefulWidget {
  const ScanReceiptScreen({super.key});

  @override
  State<ScanReceiptScreen> createState() => _ScanReceiptScreenState();
}

class _ScanReceiptScreenState extends State<ScanReceiptScreen> {
  bool _scanning = false;

  Future<void> _scan(XFile? file) async {
    if (file == null) return;
    setState(() => _scanning = true);

    try {
      final result = await OcrApiService.instance.scanReceipt(file);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReceiptReviewScreen(result: result, imageFile: file),
        ),
      );
    } on OcrApiException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Could not reach the server. Make sure the Flask backend is running.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Scan Failed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: AppColors.textWhite,
        title: const Text('Scan Receipt'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 32),
                _illustration(),
                const SizedBox(height: 40),
                const Text(
                  'Choose how to add your receipt',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                _PickerButton(
                  icon: Icons.camera_alt_rounded,
                  label: 'Take Photo',
                  subtitle: 'Use your camera to capture a receipt',
                  onTap: () async {
                    final file = await OcrApiService.instance.pickFromCamera();
                    await _scan(file);
                  },
                ),
                const SizedBox(height: 16),
                _PickerButton(
                  icon: Icons.photo_library_rounded,
                  label: 'Choose from Gallery',
                  subtitle: 'Select an image or PDF from your device',
                  onTap: () async {
                    final file = await OcrApiService.instance.pickFromGallery();
                    await _scan(file);
                  },
                ),
                const Spacer(),
                const Text(
                  'Supports PNG, JPG, JPEG and PDF · Max 10 MB',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (_scanning) _loadingOverlay(),
        ],
      ),
    );
  }

  Widget _illustration() => Container(
        height: 160,
        decoration: BoxDecoration(
          color: AppColors.primarySurface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Center(
          child: Icon(Icons.receipt_long_rounded,
              size: 80, color: AppColors.primary),
        ),
      );

  Widget _loadingOverlay() => Container(
        color: Colors.black45,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primaryLight),
              SizedBox(height: 16),
              Text('Reading receipt…',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        ),
      );
}

class _PickerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _PickerButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.primary, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

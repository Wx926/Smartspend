import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/theme/app_colors.dart';

/// Forgot-passcode recovery: sends a 6-digit code to the account's email
/// (the user is still logged in — the passcode only locks the *app*, not
/// the account — so we already know which address to use) and verifies it.
/// Pops with `true` on success, letting the caller move on to setting a new
/// passcode without needing to sign out and back in with a password.
class PasscodeOtpVerifyScreen extends StatefulWidget {
  const PasscodeOtpVerifyScreen({super.key});

  @override
  State<PasscodeOtpVerifyScreen> createState() =>
      _PasscodeOtpVerifyScreenState();
}

class _PasscodeOtpVerifyScreenState extends State<PasscodeOtpVerifyScreen> {
  final _otpCtrl = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.requestPasswordReset(auth.email);
    if (!mounted) return;
    if (ok) {
      setState(() => _sent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verification code sent — check your email'),
          backgroundColor: AppColors.budgetGreen,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(auth.errorMessage ?? 'Could not send code'),
          backgroundColor: AppColors.budgetRed,
        ),
      );
    }
  }

  Future<void> _verify() async {
    final code = _otpCtrl.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the code from your email')),
      );
      return;
    }
    final auth = context.read<AuthProvider>();
    final ok = await auth.verifyRecoveryOtp(email: auth.email, otp: code);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(auth.errorMessage ?? 'Incorrect or expired code'),
          backgroundColor: AppColors.budgetRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Verify Your Email')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "We'll send a verification code to ${auth.email} to confirm "
              "it's really you before resetting your passcode.",
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            if (!_sent)
              ElevatedButton(
                onPressed: auth.isLoading ? null : _sendCode,
                child: auth.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Send Code'),
              ),
            if (_sent) ...[
              TextField(
                controller: _otpCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: auth.isLoading ? null : _sendCode,
                  child: const Text('Resend code'),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: auth.isLoading ? null : _verify,
                child: auth.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Verify'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

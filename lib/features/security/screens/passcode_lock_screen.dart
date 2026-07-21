import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../util/passcode_hash.dart';
import '../widgets/passcode_keypad.dart';
import 'passcode_otp_verify_screen.dart';
import 'passcode_setup_screen.dart';

/// Shown at app launch (and again after the configured background timeout)
/// when the passcode lock is on. [onUnlocked] flips the app back to its
/// normal content — this screen has no navigation of its own besides that.
class PasscodeLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const PasscodeLockScreen({super.key, required this.onUnlocked});

  @override
  State<PasscodeLockScreen> createState() => _PasscodeLockScreenState();
}

class _PasscodeLockScreenState extends State<PasscodeLockScreen> {
  String _entered = '';
  String? _error;

  void _onDigit(String d) {
    if (_entered.length >= 4) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == 4) {
      if (hashPasscode(_entered) == LocalStorageService.instance.passcodeHash) {
        LocalStorageService.instance.setPasscodeLastUnlockedAt(DateTime.now());
        widget.onUnlocked();
      } else {
        setState(() {
          _error = 'Incorrect passcode';
          _entered = '';
        });
      }
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _forgotPasscode() async {
    final authProvider = context.read<AuthProvider>();

    // Defensive fallback — passcode setup now requires being logged in, so
    // this shouldn't normally happen, but handle a guest session gracefully
    // if it somehow does (no email to verify against).
    if (!authProvider.isLoggedIn) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Forgot Passcode?'),
          content: const Text(
            'This turns off your passcode lock. You can set a new one '
            'anytime from Profile.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Turn Off Passcode'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final store = LocalStorageService.instance;
      await store.setPasscodeEnabled(false);
      await store.setPasscodeHash(null);
      widget.onUnlocked();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forgot Passcode?'),
        content: Text(
          "We'll verify it's really you with a code sent to "
          '${authProvider.email}, then let you set a new passcode.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PasscodeOtpVerifyScreen()),
    );
    if (verified != true || !mounted) return;

    final reset = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PasscodeSetupScreen(isReset: true),
      ),
    );
    if (reset == true) {
      widget.onUnlocked();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: Colors.white, size: 40),
              const SizedBox(height: 16),
              const Text(
                'Enter Passcode',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ],
              const SizedBox(height: 28),
              PasscodeKeypad(
                enteredLength: _entered.length,
                onDigit: _onDigit,
                onBackspace: _onBackspace,
                dotColor: Colors.white,
                keyColor: Colors.white,
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: _forgotPasscode,
                child: const Text(
                  'Forgot Passcode?',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

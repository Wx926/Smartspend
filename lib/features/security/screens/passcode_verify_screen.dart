import 'package:flutter/material.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../util/passcode_hash.dart';
import '../widgets/passcode_keypad.dart';

/// Confirms the user still knows the *current* passcode before letting them
/// pick a new one — otherwise anyone holding an already-unlocked phone could
/// silently change the passcode and lock the real owner out.
/// Pops with `true` once the correct passcode is entered.
class PasscodeVerifyScreen extends StatefulWidget {
  const PasscodeVerifyScreen({super.key});

  @override
  State<PasscodeVerifyScreen> createState() => _PasscodeVerifyScreenState();
}

class _PasscodeVerifyScreenState extends State<PasscodeVerifyScreen> {
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
        Navigator.of(context).pop(true);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter Current Passcode')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Confirm your current passcode to continue',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.budgetRed,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 28),
            PasscodeKeypad(
              enteredLength: _entered.length,
              onDigit: _onDigit,
              onBackspace: _onBackspace,
            ),
          ],
        ),
      ),
    );
  }
}

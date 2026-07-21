import 'package:flutter/material.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../util/passcode_hash.dart';
import '../widgets/passcode_keypad.dart';

enum _Step { enter, confirm }

/// Two-step "enter, then confirm" passcode creation flow, used both for
/// turning the lock on for the first time and for resetting an existing
/// passcode (after [PasscodeVerifyScreen] confirms the old one).
/// Pops with `true` on success — callers decide what to do next rather than
/// this screen navigating on their behalf.
class PasscodeSetupScreen extends StatefulWidget {
  final bool isReset;
  const PasscodeSetupScreen({super.key, this.isReset = false});

  @override
  State<PasscodeSetupScreen> createState() => _PasscodeSetupScreenState();
}

class _PasscodeSetupScreenState extends State<PasscodeSetupScreen> {
  _Step _step = _Step.enter;
  String _first = '';
  String _entered = '';
  String? _error;

  void _onDigit(String d) {
    if (_entered.length >= 4) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == 4) {
      Future.delayed(const Duration(milliseconds: 120), _advance);
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _advance() async {
    if (_step == _Step.enter) {
      setState(() {
        _first = _entered;
        _entered = '';
        _step = _Step.confirm;
      });
      return;
    }
    if (_entered == _first) {
      final store = LocalStorageService.instance;
      await store.setPasscodeHash(hashPasscode(_entered));
      await store.setPasscodeEnabled(true);
      await store.setPasscodeLastUnlockedAt(DateTime.now());
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = "Passcodes didn't match — try again";
        _first = '';
        _entered = '';
        _step = _Step.enter;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _step == _Step.enter
        ? (widget.isReset ? 'Enter a new passcode' : 'Set a passcode')
        : 'Confirm passcode';
    final subtitle = _step == _Step.enter
        ? 'Choose a 4-digit passcode'
        : 'Enter it again to confirm';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReset ? 'Reset Passcode' : 'Set Up Passcode'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
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

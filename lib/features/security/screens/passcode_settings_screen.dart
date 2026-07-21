import 'package:flutter/material.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import 'passcode_setup_screen.dart';
import 'passcode_verify_screen.dart';

const _timeoutOptions = <(int, String)>[
  (0, 'Immediately'),
  (1, 'After 1 minute'),
  (5, 'After 5 minutes'),
  (15, 'After 15 minutes'),
  (30, 'After 30 minutes'),
  (60, 'After 1 hour'),
];

/// The "Passcode" settings page: on/off toggle, reset, and how long the app
/// can sit in the background before it re-locks.
class PasscodeSettingsScreen extends StatefulWidget {
  const PasscodeSettingsScreen({super.key});

  @override
  State<PasscodeSettingsScreen> createState() => _PasscodeSettingsScreenState();
}

class _PasscodeSettingsScreenState extends State<PasscodeSettingsScreen> {
  late bool _enabled;
  late int _timeoutMinutes;

  @override
  void initState() {
    super.initState();
    final store = LocalStorageService.instance;
    _enabled = store.passcodeEnabled;
    _timeoutMinutes = store.passcodeTimeoutMinutes;
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const PasscodeSetupScreen()),
      );
      if (ok == true && mounted) setState(() => _enabled = true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn Off Passcode?'),
        content: const Text(
          "You won't need a passcode to open SmartSpend anymore.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Turn Off'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final store = LocalStorageService.instance;
      await store.setPasscodeEnabled(false);
      await store.setPasscodeHash(null);
      if (mounted) setState(() => _enabled = false);
    }
  }

  Future<void> _resetPasscode() async {
    final verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PasscodeVerifyScreen()),
    );
    if (verified != true || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PasscodeSetupScreen(isReset: true),
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Passcode updated')));
    }
  }

  Future<void> _pickTimeout() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _timeoutOptions
              .map(
                (opt) => ListTile(
                  title: Text(opt.$2),
                  trailing: _timeoutMinutes == opt.$1
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, opt.$1),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (picked != null) {
      await LocalStorageService.instance.setPasscodeTimeoutMinutes(picked);
      setState(() => _timeoutMinutes = picked);
    }
  }

  String get _timeoutLabel => _timeoutOptions
      .firstWhere(
        (o) => o.$1 == _timeoutMinutes,
        orElse: () => _timeoutOptions.first,
      )
      .$2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Passcode')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text('Passcode Lock'),
                subtitle: const Text('Require a passcode to open SmartSpend'),
                value: _enabled,
                onChanged: _onToggle,
                activeThumbColor: AppColors.primary,
              ),
            ),
          ),
          if (_enabled) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('Reset Passcode'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _resetPasscode,
                    ),
                    const Divider(height: 1, indent: 16),
                    ListTile(
                      title: const Text('Request Passcode'),
                      subtitle: Text(_timeoutLabel),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _pickTimeout,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

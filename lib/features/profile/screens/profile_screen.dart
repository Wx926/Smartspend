import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../ocr/screens/warranty_records_screen.dart';
import '../../ocr/screens/receipt_history_screen.dart';
import '../../ocr/screens/scan_receipt_screen.dart';
import '../../expenses/providers/expense_provider.dart';
import '../../security/screens/passcode_setup_screen.dart';
import '../../security/screens/passcode_settings_screen.dart';
import '../../security/screens/passcode_verify_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _locationAlerts = true;
  bool _pushNotifications = true;
  bool _aiCategorisation = true;
  int _warrantyCount = 0;
  int _expiringCount = 0;

  @override
  void initState() {
    super.initState();
    _loadWarranties();
    _pushNotifications = LocalStorageService.instance.notificationsEnabled;
    _aiCategorisation = LocalStorageService.instance.aiCategorisationEnabled;
  }

  Future<void> _loadWarranties() async {
    try {
      final data = await SupabaseService.instance.getWarranties();
      if (mounted) {
        setState(() {
          _warrantyCount = data.length;
          _expiringCount = data.where((w) => w['status'] == 'yellow').length;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final receiptCount = context
        .watch<ExpenseProvider>()
        .expenses
        .where((e) => e.source == 'ocr' || e.source == 'voice')
        .map((e) => e.batchId ?? e.id)
        .toSet()
        .length;
    final name = auth.isLoggedIn
        ? (auth.displayName.isEmpty ? 'User' : auth.displayName)
        : 'Guest User';
    final initials = name
        .trim()
        .split(' ')
        .where((e) => e.isNotEmpty)
        .map((e) => e[0])
        .take(2)
        .join()
        .toUpperCase();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // ── Green header ──────────────────────────────────────────
          Container(
            color: AppColors.primaryDark,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                child: Column(
                  children: [
                    if (Navigator.canPop(context))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ),
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFD4AF37),
                          width: 3,
                        ),
                        color: AppColors.primary,
                      ),
                      child: Center(
                        child: Text(
                          initials.isEmpty ? '?' : initials,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (auth.isLoggedIn) ...[
                      const SizedBox(height: 4),
                      Text(
                        auth.email,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Smart Receipts & Voice ────────────────────────────────
          _sectionLabel('SMART RECEIPTS & VOICE'),
          _card([
            _tile(
              icon: Icons.receipt_long_outlined,
              iconColor: AppColors.primary,
              iconBg: AppColors.primarySurface,
              title: 'Scanned Receipt History',
              subtitle: receiptCount == 0
                  ? 'No receipts yet'
                  : '$receiptCount receipts',
              trailingBadge: receiptCount > 0 ? '$receiptCount' : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReceiptHistoryScreen()),
              ),
            ),
            _divider(),
            _tile(
              icon: Icons.camera_alt_outlined,
              iconColor: const Color(0xFFFF8C42),
              iconBg: const Color(0xFFFFF0E6),
              title: 'Scan a new receipt',
              subtitle: 'Camera, gallery or voice input',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ScanReceiptScreen()),
              ),
            ),
            _divider(),
            _tile(
              icon: Icons.language_outlined,
              iconColor: const Color(0xFF8B5CF6),
              iconBg: const Color(0xFFF5F3FF),
              title: 'Voice input language',
              subtitle: 'English (Malaysia)',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Voice input — coming soon')),
              ),
            ),
            _divider(),
            _toggleTile(
              icon: Icons.auto_awesome_outlined,
              iconColor: const Color(0xFF3B82F6),
              iconBg: const Color(0xFFEFF6FF),
              title: 'AI auto-categorisation',
              subtitle: 'Suggest category from receipt content',
              value: _aiCategorisation,
              onChanged: (v) {
                setState(() => _aiCategorisation = v);
                LocalStorageService.instance.setAiCategorisationEnabled(v);
              },
            ),
          ]),

          const SizedBox(height: 20),

          // ── Budget & Goals ────────────────────────────────────────
          _sectionLabel('BUDGET & GOALS'),
          _card([
            _tile(
              icon: Icons.list_alt_outlined,
              iconColor: const Color(0xFFFF8C42),
              iconBg: const Color(0xFFFFF0E6),
              title: 'Manage categories',
              subtitle: 'Food, Shopping, Transport, Electronics',
              onTap: () => Navigator.pushNamed(context, '/manage-categories'),
            ),
            _divider(),
            _tile(
              icon: Icons.account_balance_wallet_outlined,
              iconColor: const Color(0xFF27AE60),
              iconBg: const Color(0xFFE8F8EF),
              title: 'Set monthly budgets',
              subtitle: 'Adjust limits for each category',
              onTap: () => Navigator.pushNamed(context, '/budget'),
            ),
            _divider(),
            _tile(
              icon: Icons.track_changes_outlined,
              iconColor: const Color(0xFFE74C3C),
              iconBg: const Color(0xFFFDECEA),
              title: 'Savings goals',
              subtitle: 'Tap to manage your goals',
              onTap: () => Navigator.pushNamed(context, '/savings-goals'),
            ),
            _divider(),
            _tile(
              icon: Icons.verified_user_outlined,
              iconColor: const Color(0xFF3B82F6),
              iconBg: const Color(0xFFEFF6FF),
              title: 'Warranty records',
              subtitle: _warrantyCount == 0
                  ? 'No warranties recorded'
                  : '$_warrantyCount item${_warrantyCount != 1 ? 's' : ''}'
                        '${_expiringCount > 0 ? ' · $_expiringCount expiring soon' : ''}',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const WarrantyRecordsScreen(),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 20),

          // ── Location & Alerts ─────────────────────────────────────
          _sectionLabel('LOCATION & ALERTS'),
          _card([
            _toggleTile(
              icon: Icons.location_on_outlined,
              iconColor: const Color(0xFFE74C3C),
              iconBg: const Color(0xFFFDECEA),
              title: 'Location alerts',
              subtitle: 'Detect nearby spending areas',
              value: _locationAlerts,
              onChanged: (v) => setState(() => _locationAlerts = v),
            ),
            _divider(),
            _toggleTile(
              icon: Icons.notifications_outlined,
              iconColor: const Color(0xFFF59E0B),
              iconBg: const Color(0xFFFFFBEB),
              title: 'Push notifications',
              subtitle: 'Budget warnings and AI insights',
              value: _pushNotifications,
              onChanged: (v) {
                setState(() => _pushNotifications = v);
                LocalStorageService.instance.setNotificationsEnabled(v);
              },
            ),
            _divider(),
            _tile(
              icon: Icons.timer_outlined,
              iconColor: const Color(0xFF8B5CF6),
              iconBg: const Color(0xFFF5F3FF),
              title: 'Alerts',
              subtitle: 'View your budget and location alert history',
              onTap: () => Navigator.pushNamed(context, '/alerts'),
            ),
          ]),

          const SizedBox(height: 20),

          // ── Account ───────────────────────────────────────────────
          _sectionLabel('ACCOUNT'),
          _card([
            _tile(
              icon: Icons.edit_outlined,
              iconColor: const Color(0xFF27AE60),
              iconBg: const Color(0xFFE8F8EF),
              title: 'Edit username',
              subtitle: name,
              onTap: () => _showEditNameDialog(context, name),
            ),
            _divider(),
            _tile(
              icon: Icons.lock_outlined,
              iconColor: const Color(0xFF8B5CF6),
              iconBg: const Color(0xFFF5F3FF),
              title: 'Passcode',
              subtitle: !auth.isLoggedIn
                  ? 'Sign in to use a passcode lock'
                  : LocalStorageService.instance.passcodeEnabled
                  ? 'Enabled'
                  : 'Lock SmartSpend with a 4-digit passcode',
              onTap: () async {
                // Recovering a forgotten passcode relies on your account
                // login (password/Google) — a guest has no way to prove
                // ownership, so passcode setup isn't offered here at all.
                if (!auth.isLoggedIn) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sign in to use a passcode lock'),
                    ),
                  );
                  return;
                }
                if (LocalStorageService.instance.passcodeEnabled) {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PasscodeSettingsScreen(),
                    ),
                  );
                } else {
                  final ok = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PasscodeSetupScreen(),
                    ),
                  );
                  if (ok == true && context.mounted) {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PasscodeSettingsScreen(),
                      ),
                    );
                  }
                }
                if (mounted) setState(() {});
              },
            ),
            if (auth.isLoggedIn) ...[
              _divider(),
              _tile(
                icon: Icons.logout,
                iconColor: const Color(0xFFE74C3C),
                iconBg: const Color(0xFFFDECEA),
                title: 'Sign out',
                titleColor: const Color(0xFFE74C3C),
                subtitle: auth.email,
                onTap: () async {
                  if (LocalStorageService.instance.passcodeEnabled) {
                    final verified = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PasscodeVerifyScreen(),
                      ),
                    );
                    if (verified != true || !context.mounted) return;
                  }
                  await context.read<AuthProvider>().signOut();
                },
              ),
            ],
          ]),

          // ── Guest Mode ────────────────────────────────────────────
          if (!auth.isLoggedIn) ...[
            const SizedBox(height: 20),
            _sectionLabel('GUEST MODE'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Using SmartSpend without an account?',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Sign in to sync your data across devices and enable cloud backup. Signing in is optional.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pushNamed(context, '/login'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryDark,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Sign In / Create Account'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Center(
            child: Text(
              'SmartSpend v1.0.0 · TAR UMT 2025/26',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showEditNameDialog(BuildContext context, String currentName) {
    final ctrl = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit Username'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final ok = await context.read<AuthProvider>().updateName(name);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok ? 'Name updated!' : 'Update failed'),
                    backgroundColor: ok
                        ? AppColors.budgetGreen
                        : AppColors.budgetRed,
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(
      label,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _card(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    ),
  );

  Widget _divider() => const Divider(height: 1, indent: 56);

  Widget _tile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    String? subtitle,
    Color? titleColor,
    String? trailingBadge,
    VoidCallback? onTap,
  }) => ListTile(
    leading: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: iconBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: iconColor, size: 20),
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: titleColor,
      ),
    ),
    subtitle: subtitle != null
        ? Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          )
        : null,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trailingBadge != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              trailingBadge,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        const Icon(
          Icons.chevron_right,
          color: AppColors.textSecondary,
          size: 18,
        ),
      ],
    ),
    onTap: onTap,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
  );

  Widget _toggleTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => ListTile(
    leading: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: iconBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: iconColor, size: 20),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    subtitle: subtitle != null
        ? Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          )
        : null,
    trailing: Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: AppColors.primary,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
  );
}

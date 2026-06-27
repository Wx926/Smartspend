import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/wallet_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/theme/app_colors.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExpenseProvider>().load();
    });
  }

  String _mask(String value, bool hidden) => hidden ? 'RM ****' : value;

  @override
  Widget build(BuildContext context) {
    final wp = context.watch<WalletProvider>();
    final ep = context.watch<ExpenseProvider>();
    final all = ep.expenses;
    final fmt = NumberFormat('#,##0.00', 'en_MY');
    final net = wp.netAsset(all);
    final asset = wp.totalAsset(all);
    final debt = wp.totalDebt(all);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // ── Header ──────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 210,
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            automaticallyImplyLeading: false,
            actions: const [SizedBox.shrink()],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primaryDark, AppColors.primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            GestureDetector(
                              onTap: wp.toggleHidden,
                              child: Icon(
                                wp.hidden
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: Colors.white70,
                                size: 22,
                              ),
                            ),
                            const Icon(Icons.account_balance_wallet_outlined,
                                color: Colors.white70, size: 22),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text('Wallet',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 2),
                        const Text('Net Asset',
                            style: TextStyle(
                                color: Colors.white60, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          wp.hidden
                              ? 'RM ****'
                              : 'RM ${fmt.format(net)}',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          _HeaderStat(
                              label: 'Asset',
                              value: _mask('RM ${fmt.format(asset)}',
                                  wp.hidden)),
                          const SizedBox(width: 24),
                          _HeaderStat(
                              label: 'Debt',
                              value:
                                  _mask('RM ${fmt.format(debt)}', wp.hidden)),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Wallet cards ────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final wallet = wp.wallets[i];
                  final balance = wp.walletBalance(wallet.id, all);
                  final color =
                      Color(int.parse('FF${wallet.colorHex}', radix: 16));
                  return Dismissible(
                    key: Key(wallet.id),
                    direction: wallet.isDefault
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppColors.budgetRed,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    confirmDismiss: (_) => showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Delete Wallet'),
                        content: Text(
                            'Delete "${wallet.name}"? All transactions will be moved to Default Account.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Delete',
                                  style:
                                      TextStyle(color: AppColors.budgetRed))),
                        ],
                      ),
                    ),
                    onDismissed: (_) =>
                        context.read<WalletProvider>().deleteWallet(wallet.id),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 6,
                              offset: const Offset(0, 2))
                        ],
                      ),
                      child: Row(children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(wallet.icon,
                                style: const TextStyle(fontSize: 22)),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(wallet.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15)),
                              Text(
                                wallet.isDefault ? 'Default' : 'MYR',
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              wp.hidden
                                  ? 'RM ****'
                                  : 'RM ${fmt.format(balance)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: balance >= 0
                                    ? AppColors.textPrimary
                                    : AppColors.budgetRed,
                              ),
                            ),
                            Text('MYR (1.0000)',
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 11)),
                          ],
                        ),
                      ]),
                    ),
                  );
                },
                childCount: wp.wallets.length,
              ),
            ),
          ),

          // ── Add wallet button ────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
              child: GestureDetector(
                onTap: _showAddWalletSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.4),
                        width: 1.5),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, color: AppColors.primary, size: 20),
                      SizedBox(width: 8),
                      Text('Add Wallet',
                          style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddWalletSheet() {
    final nameCtrl = TextEditingController();
    final iconCtrl = TextEditingController(text: '💳');
    String selectedIcon = '💳';
    String selectedColor = '3B82F6';

    final templates = [
      {'name': 'Cash', 'icon': '💵', 'color': '27AE60'},
      {'name': 'Public Bank', 'icon': '🏦', 'color': '003087'},
      {'name': 'Maybank', 'icon': '🏦', 'color': 'F7C700'},
      {'name': 'CIMB', 'icon': '🏦', 'color': 'E2001A'},
      {'name': 'TNG eWallet', 'icon': '📱', 'color': 'FF6B35'},
      {'name': 'Shopee Pay', 'icon': '🛍️', 'color': 'EE4D2D'},
      {'name': 'GrabPay', 'icon': '🟢', 'color': '00B14F'},
      {'name': 'Boost', 'icon': '⚡', 'color': 'FF4E00'},
    ];

    final colors = [
      '3B82F6', '27AE60', 'F39C12', 'E74C3C',
      '8E44AD', '2980B9', '003087', 'F7C700',
      'E2001A', 'FF6B35', 'EE4D2D', '00B14F',
    ];

    final iconSuggestions = [
      '💳', '💵', '🏦', '📱', '🛍️', '🟢',
      '⚡', '💰', '🪙', '💎', '🏧', '📲',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Add Wallet',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),

                // Quick templates
                const Text('Quick add',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: templates.map((t) {
                    return GestureDetector(
                      onTap: () => setSheet(() {
                        nameCtrl.text = t['name']!;
                        selectedIcon = t['icon']!;
                        iconCtrl.text = t['icon']!;
                        selectedColor = t['color']!;
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(t['icon']!,
                              style: const TextStyle(fontSize: 15)),
                          const SizedBox(width: 6),
                          Text(t['name']!,
                              style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Wallet name'),
                ),
                const SizedBox(height: 16),

                // Icon
                const Text('Icon',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                TextField(
                  controller: iconCtrl,
                  style: const TextStyle(fontSize: 24),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '💳',
                    helperText: 'Type any emoji from your keyboard',
                    helperStyle: const TextStyle(fontSize: 11),
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (val) {
                    final t = val.trim();
                    if (t.isNotEmpty) setSheet(() => selectedIcon = t);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: iconSuggestions.map((icon) {
                    final sel = selectedIcon == icon;
                    return GestureDetector(
                      onTap: () => setSheet(() {
                        selectedIcon = icon;
                        iconCtrl.text = icon;
                      }),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: sel
                              ? AppColors.primary.withValues(alpha: 0.15)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: sel
                              ? Border.all(
                                  color: AppColors.primary, width: 2)
                              : null,
                        ),
                        child: Center(
                            child: Text(icon,
                                style: const TextStyle(fontSize: 20))),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Color
                const Text('Colour',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: colors.map((hex) {
                    final color = Color(int.parse('FF$hex', radix: 16));
                    final sel = selectedColor == hex;
                    return GestureDetector(
                      onTap: () => setSheet(() => selectedColor = hex),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: sel
                              ? Border.all(
                                  color: Colors.black54, width: 3)
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) return;
                      final wallet = WalletModel(
                        id: 'wallet_${DateTime.now().millisecondsSinceEpoch}',
                        name: name,
                        icon: selectedIcon,
                        colorHex: selectedColor,
                      );
                      await context.read<WalletProvider>().addWallet(wallet);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Add Wallet'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String label;
  final String value;
  const _HeaderStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ],
      );
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../providers/savings_goal_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../features/wallet/providers/wallet_provider.dart';

class SavingsGoalsScreen extends StatefulWidget {
  const SavingsGoalsScreen({super.key});

  @override
  State<SavingsGoalsScreen> createState() => _SavingsGoalsScreenState();
}

class _SavingsGoalsScreenState extends State<SavingsGoalsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAndCheck());
  }

  Future<void> _loadAndCheck() async {
    final sp = context.read<SavingsGoalProvider>();
    final ep = context.read<ExpenseProvider>();
    final wp = context.read<WalletProvider>();
    final auth = context.read<AuthProvider>();
    await sp.load();
    final skipped = await sp.checkAutoTransfers(
      walletProvider: wp,
      expenseProvider: ep,
      userId: auth.userId,
    );
    if (mounted && skipped.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Auto-transfer skipped: ${skipped.join(', ')} — not enough balance'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SavingsGoalProvider>();
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Savings Goals'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        actions: [
          if (provider.goals.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Transfer Funds',
              onPressed: () => _showTransferFundsSheet(context, fmt),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showGoalSheet(context),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : provider.goals.isEmpty
              ? _emptyState()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Summary card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.primaryDark,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _summaryItem('Total Saved',
                              'RM ${fmt.format(provider.totalSaved)}'),
                          Container(
                              width: 1, height: 40, color: Colors.white24),
                          _summaryItem('Total Target',
                              'RM ${fmt.format(provider.totalTarget)}'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...provider.goals
                        .map((g) => _goalCard(context, g, fmt)),
                    const SizedBox(height: 80),
                  ],
                ),
    );
  }

  Widget _summaryItem(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ],
      );

  Widget _emptyState() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.track_changes_outlined,
                size: 64,
                color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('No savings goals yet',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('Tap + to create your first goal',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );

  Widget _goalCard(
      BuildContext context, SavingsGoalModel goal, NumberFormat fmt) {
    final pct = (goal.progress * 100).toStringAsFixed(0);
    final remaining = goal.targetAmount - goal.currentAmount;
    final isComplete = goal.isCompleted || goal.progress >= 1.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(goal.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    if (goal.linkedWalletLabel != null ||
                        goal.autoTransferEnabled)
                      const SizedBox(height: 4),
                    if (goal.linkedWalletLabel != null ||
                        goal.autoTransferEnabled)
                      Row(children: [
                        if (goal.linkedWalletLabel != null)
                          _badge(
                              '🏦 ${goal.linkedWalletLabel!}',
                              AppColors.textSecondary.withValues(alpha: 0.1),
                              AppColors.textSecondary),
                        if (goal.linkedWalletLabel != null &&
                            goal.autoTransferEnabled)
                          const SizedBox(width: 6),
                        if (goal.autoTransferEnabled)
                          _badge('🔄 Auto',
                              AppColors.primary.withValues(alpha: 0.1),
                              AppColors.primary),
                      ]),
                  ],
                ),
              ),
              if (isComplete)
                _badge('Completed', AppColors.budgetGreen.withValues(alpha: 0.15),
                    AppColors.budgetGreen),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'add') _showAddFundsSheet(context, goal, fmt);
                  if (v == 'withdraw') _showWithdrawSheet(context, goal, fmt);
                  if (v == 'auto') _showAutoTransferSheet(context, goal);
                  if (v == 'edit') _showGoalSheet(context, goal: goal);
                  if (v == 'delete') _confirmDelete(context, goal);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'add',
                      child: Row(children: [
                        Icon(Icons.add_circle_outline, size: 18),
                        SizedBox(width: 8),
                        Text('Add Funds'),
                      ])),
                  const PopupMenuItem(
                      value: 'withdraw',
                      child: Row(children: [
                        Icon(Icons.remove_circle_outline, size: 18),
                        SizedBox(width: 8),
                        Text('Withdraw'),
                      ])),
                  const PopupMenuItem(
                      value: 'auto',
                      child: Row(children: [
                        Icon(Icons.autorenew, size: 18),
                        SizedBox(width: 8),
                        Text('Auto-Transfer'),
                      ])),
                  const PopupMenuItem(
                      value: 'edit',
                      child: Row(children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Edit Goal'),
                      ])),
                  const PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline,
                            size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Delete',
                            style: TextStyle(color: Colors.red)),
                      ])),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('RM ${fmt.format(goal.currentAmount)}',
                  style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14)),
              Text('RM ${fmt.format(goal.targetAmount)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: goal.progress,
              minHeight: 8,
              backgroundColor:
                  AppColors.textSecondary.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(
                  isComplete ? AppColors.budgetGreen : AppColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$pct% reached',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              if (!isComplete)
                Text('RM ${fmt.format(remaining)} to go',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              if (goal.deadline != null)
                Text(
                    'Due ${DateFormat('d MMM yyyy').format(goal.deadline!)}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(
                color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  // ── Add Funds Sheet ─────────────────────────────────────────────────────────

  void _showAddFundsSheet(
      BuildContext context, SavingsGoalModel goal, NumberFormat fmt) {
    final ep = context.read<ExpenseProvider>();
    final wp = context.read<WalletProvider>();
    final wallets = wp.wallets;
    WalletModel selectedWallet = wp.defaultWallet;
    final amountCtrl = TextEditingController();
    String? errorMsg;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add Funds to "${goal.name}"',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text(
                  'Current: RM ${fmt.format(goal.currentAmount)} / RM ${fmt.format(goal.targetAmount)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 20),
              const Text('From wallet',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              _walletDropdown(
                wallets: wallets,
                selected: selectedWallet,
                expenses: ep.expenses,
                wp: wp,
                fmt: fmt,
                onChanged: (w) => setSheet(() {
                  selectedWallet = w!;
                  errorMsg = null;
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount (RM)',
                    prefixText: 'RM '),
                onChanged: (_) {
                  if (errorMsg != null) setSheet(() => errorMsg = null);
                },
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 10),
                _inlineError(errorMsg!),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final amount = double.tryParse(amountCtrl.text) ?? 0;
                    if (amount <= 0) {
                      setSheet(() => errorMsg = 'Please enter a valid amount');
                      return;
                    }
                    final balance =
                        wp.walletBalance(selectedWallet.id, ep.expenses);
                    if (amount > balance) {
                      setSheet(() => errorMsg =
                          '${selectedWallet.name} only has RM ${fmt.format(balance)} — not enough to transfer RM ${fmt.format(amount)}');
                      return;
                    }
                    final auth = context.read<AuthProvider>();
                    await context.read<SavingsGoalProvider>().addFunds(
                          goal: goal,
                          amount: amount,
                          sourceWalletId: selectedWallet.id,
                          expenseProvider: ep,
                          userId: auth.userId,
                        );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Add Funds'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Withdraw Sheet ──────────────────────────────────────────────────────────

  void _showWithdrawSheet(
      BuildContext context, SavingsGoalModel goal, NumberFormat fmt) {
    final ep = context.read<ExpenseProvider>();
    final wp = context.read<WalletProvider>();
    final wallets = wp.wallets;
    WalletModel selectedWallet = wp.defaultWallet;
    final amountCtrl = TextEditingController();
    String? errorMsg;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Withdraw from "${goal.name}"',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text(
                  'Available: RM ${fmt.format(goal.currentAmount)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 20),
              const Text('To wallet',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              _walletDropdown(
                wallets: wallets,
                selected: selectedWallet,
                expenses: ep.expenses,
                wp: wp,
                fmt: fmt,
                onChanged: (w) => setSheet(() {
                  selectedWallet = w!;
                  errorMsg = null;
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Amount (RM)',
                    prefixText: 'RM ',
                    helperText:
                        'Max: RM ${fmt.format(goal.currentAmount)}'),
                onChanged: (_) {
                  if (errorMsg != null) setSheet(() => errorMsg = null);
                },
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 10),
                _inlineError(errorMsg!),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final amount = double.tryParse(amountCtrl.text) ?? 0;
                    if (amount <= 0) {
                      setSheet(
                          () => errorMsg = 'Please enter a valid amount');
                      return;
                    }
                    if (amount > goal.currentAmount) {
                      setSheet(() => errorMsg =
                          'Cannot exceed goal balance of RM ${fmt.format(goal.currentAmount)}');
                      return;
                    }
                    final auth = context.read<AuthProvider>();
                    await context.read<SavingsGoalProvider>().withdrawFunds(
                          goal: goal,
                          amount: amount,
                          destWalletId: selectedWallet.id,
                          expenseProvider: ep,
                          userId: auth.userId,
                        );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Withdraw'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Transfer Funds (split across goals) Sheet ───────────────────────────────

  void _showTransferFundsSheet(BuildContext context, NumberFormat fmt) {
    final ep = context.read<ExpenseProvider>();
    final wp = context.read<WalletProvider>();
    final sp = context.read<SavingsGoalProvider>();
    final goals = sp.goals;
    final wallets = wp.wallets;
    WalletModel selectedWallet = wp.defaultWallet;
    final totalCtrl = TextEditingController();
    final allocCtrl = {for (final g in goals) g.id: TextEditingController()};
    double totalAmount = 0;
    double remaining = 0;
    String? errorMsg;

    void recalc(StateSetter setSheet) {
      totalAmount = double.tryParse(totalCtrl.text) ?? 0;
      double allocated = 0;
      for (final ctrl in allocCtrl.values) {
        allocated += double.tryParse(ctrl.text) ?? 0;
      }
      remaining = totalAmount - allocated;
      setSheet(() => errorMsg = null);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            maxChildSize: 0.92,
            builder: (_, scrollCtrl) => Padding(
              padding: EdgeInsets.fromLTRB(
                  24, 0, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
              child: ListView(
                controller: scrollCtrl,
                children: [
                  const SizedBox(height: 20),
                  const Text('Transfer Funds',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const Text(
                      'Split one source amount across multiple goals',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  const SizedBox(height: 20),
                  const Text('From wallet',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 6),
                  _walletDropdown(
                    wallets: wallets,
                    selected: selectedWallet,
                    expenses: ep.expenses,
                    wp: wp,
                    fmt: fmt,
                    onChanged: (w) =>
                        setSheet(() => selectedWallet = w!),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: totalCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Total amount to transfer (RM)',
                        prefixText: 'RM '),
                    onChanged: (_) => recalc(setSheet),
                  ),
                  const SizedBox(height: 20),
                  const Text('Allocate to goals',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 8),
                  ...goals.map((g) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(g.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                        fontSize: 13)),
                                Text(
                                    'RM ${fmt.format(g.currentAmount)} saved',
                                    style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: allocCtrl[g.id],
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  prefixText: 'RM ',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10)),
                              onChanged: (_) => recalc(setSheet),
                            ),
                          ),
                        ]),
                      )),
                  const SizedBox(height: 8),
                  // Remaining indicator
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: remaining == 0
                          ? AppColors.budgetGreen.withValues(alpha: 0.1)
                          : remaining < 0
                              ? AppColors.budgetRed.withValues(alpha: 0.1)
                              : AppColors.budgetYellow
                                  .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Icon(
                        remaining == 0
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_outlined,
                        size: 16,
                        color: remaining == 0
                            ? AppColors.budgetGreen
                            : remaining < 0
                                ? AppColors.budgetRed
                                : AppColors.budgetYellow,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        remaining == 0
                            ? 'All funds allocated'
                            : remaining > 0
                                ? 'RM ${fmt.format(remaining)} unallocated'
                                : 'Over-allocated by RM ${fmt.format(-remaining)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: remaining == 0
                              ? AppColors.budgetGreen
                              : remaining < 0
                                  ? AppColors.budgetRed
                                  : AppColors.budgetYellow,
                        ),
                      ),
                    ]),
                  ),
                  if (errorMsg != null) ...[
                    const SizedBox(height: 4),
                    _inlineError(errorMsg!),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: remaining == 0 && totalAmount > 0
                          ? () async {
                              final balance = wp.walletBalance(
                                  selectedWallet.id, ep.expenses);
                              if (totalAmount > balance) {
                                setSheet(() => errorMsg =
                                    '${selectedWallet.name} only has RM ${fmt.format(balance)} — not enough to transfer RM ${fmt.format(totalAmount)}');
                                return;
                              }
                              final auth = context.read<AuthProvider>();
                              final sgProvider =
                                  context.read<SavingsGoalProvider>();
                              for (final g in goals) {
                                final amt = double.tryParse(
                                        allocCtrl[g.id]?.text ?? '') ??
                                    0;
                                if (amt <= 0) continue;
                                final latest = sgProvider.goals
                                    .firstWhere((x) => x.id == g.id,
                                        orElse: () => g);
                                await sgProvider.addFunds(
                                  goal: latest,
                                  amount: amt,
                                  sourceWalletId: selectedWallet.id,
                                  expenseProvider: ep,
                                  userId: auth.userId,
                                );
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                            }
                          : null,
                      child: const Text('Confirm Transfer'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Auto-Transfer Sheet ─────────────────────────────────────────────────────

  void _showAutoTransferSheet(BuildContext context, SavingsGoalModel goal) {
    final wp = context.read<WalletProvider>();
    final ep = context.read<ExpenseProvider>();
    final wallets = wp.wallets;
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    bool enabled = goal.autoTransferEnabled;
    WalletModel selectedWallet = wallets
        .firstWhere((w) => w.id == goal.autoTransferSourceWalletId,
            orElse: () => wp.defaultWallet);
    final amountCtrl = TextEditingController(
        text: goal.autoTransferAmount?.toStringAsFixed(2) ?? '');
    int dayOfMonth = goal.autoTransferDayOfMonth ?? 1;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Auto-Transfer: ${goal.name}',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold)),
                  Switch(
                    value: enabled,
                    onChanged: (v) => setSheet(() => enabled = v),
                    activeThumbColor: AppColors.primary,
                    activeTrackColor: AppColors.primary.withValues(alpha: 0.5),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                enabled
                    ? 'Transfer runs automatically each month'
                    : 'Enable to set up auto-transfer',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              if (enabled) ...[
                const SizedBox(height: 20),
                const Text('From wallet',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                _walletDropdown(
                  wallets: wallets,
                  selected: selectedWallet,
                  expenses: ep.expenses,
                  wp: wp,
                  fmt: fmt,
                  onChanged: (w) =>
                      setSheet(() => selectedWallet = w!),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Transfer amount (RM)',
                      prefixText: 'RM '),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Day of month',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                    DropdownButton<int>(
                      value: dayOfMonth,
                      underline: const SizedBox.shrink(),
                      items: List.generate(28, (i) => i + 1)
                          .map((d) => DropdownMenuItem(
                              value: d, child: Text('$d')))
                          .toList(),
                      onChanged: (v) =>
                          setSheet(() => dayOfMonth = v ?? 1),
                    ),
                    const Text('th of each month',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final amount = enabled
                        ? (double.tryParse(amountCtrl.text) ?? 0)
                        : null;
                    if (enabled && (amount == null || amount <= 0)) return;
                    await context.read<SavingsGoalProvider>().update(
                          goal.copyWith(
                            autoTransferEnabled: enabled,
                            autoTransferAmount: enabled ? amount : null,
                            autoTransferSourceWalletId:
                                enabled ? selectedWallet.id : null,
                            autoTransferDayOfMonth:
                                enabled ? dayOfMonth : null,
                          ),
                        );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Create / Edit Goal Sheet ────────────────────────────────────────────────

  void _showGoalSheet(BuildContext context, {SavingsGoalModel? goal}) {
    final nameCtrl = TextEditingController(text: goal?.name ?? '');
    final targetCtrl = TextEditingController(
        text: goal != null ? goal.targetAmount.toStringAsFixed(2) : '');
    final walletLabelCtrl =
        TextEditingController(text: goal?.linkedWalletLabel ?? '');
    DateTime? deadline = goal?.deadline;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(goal == null ? 'New Savings Goal' : 'Edit Goal',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtrl,
                decoration:
                    const InputDecoration(labelText: 'Goal name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: targetCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Target amount (RM)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: walletLabelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Linked bank account (optional)',
                  hintText: 'e.g. Maybank Savings',
                  helperText:
                      'Just a label to remind you where this money is saved',
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: deadline ??
                        DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now(),
                    lastDate:
                        DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (picked != null) {
                    setSheetState(() => deadline = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_outlined,
                          size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(
                        deadline != null
                            ? 'Deadline: ${DateFormat('d MMM yyyy').format(deadline!)}'
                            : 'Set deadline (optional)',
                        style: TextStyle(
                            color: deadline != null
                                ? AppColors.textPrimary
                                : AppColors.textSecondary),
                      ),
                      if (deadline != null) ...[
                        const Spacer(),
                        GestureDetector(
                          onTap: () =>
                              setSheetState(() => deadline = null),
                          child: const Icon(Icons.close,
                              size: 16,
                              color: AppColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final target =
                        double.tryParse(targetCtrl.text) ?? 0;
                    if (name.isEmpty || target <= 0) return;
                    final label = walletLabelCtrl.text.trim();

                    final provider =
                        context.read<SavingsGoalProvider>();
                    final auth = context.read<AuthProvider>();

                    if (goal == null) {
                      await provider.add(SavingsGoalModel(
                        id: '',
                        userId: auth.userId,
                        name: name,
                        targetAmount: target,
                        currentAmount: 0,
                        deadline: deadline,
                        linkedWalletLabel:
                            label.isNotEmpty ? label : null,
                        createdAt: DateTime.now(),
                      ));
                    } else {
                      await provider.update(goal.copyWith(
                        name: name,
                        targetAmount: target,
                        deadline: deadline,
                        clearDeadline: deadline == null,
                        linkedWalletLabel:
                            label.isNotEmpty ? label : null,
                        clearLinkedWalletLabel: label.isEmpty,
                      ));
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(
                      goal == null ? 'Create Goal' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, SavingsGoalModel goal) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Goal'),
        content: Text(
            'Delete "${goal.name}"? This will not affect any past transactions.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              context.read<SavingsGoalProvider>().delete(goal.id);
              Navigator.pop(context);
            },
            child:
                const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Widget _inlineError(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    color: Colors.red.shade700,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
        ]),
      );

  Widget _walletDropdown({
    required List<WalletModel> wallets,
    required WalletModel selected,
    required List<ExpenseModel> expenses,
    required WalletProvider wp,
    required NumberFormat fmt,
    required ValueChanged<WalletModel?> onChanged,
  }) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: DropdownButton<WalletModel>(
        value: selected,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: wallets.map((w) {
          final bal = wp.walletBalance(w.id, expenses);
          return DropdownMenuItem(
            value: w,
            child: Row(children: [
              Text(w.icon,
                  style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(child: Text(w.name)),
              Text('RM ${fmt.format(bal)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12)),
            ]),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

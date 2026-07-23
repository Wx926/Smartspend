import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/loan_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../providers/loan_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../features/wallet/providers/wallet_provider.dart';

class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key});

  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAndCheck());
  }

  Future<void> _loadAndCheck() async {
    final lp = context.read<LoanProvider>();
    final ep = context.read<ExpenseProvider>();
    final wp = context.read<WalletProvider>();
    final auth = context.read<AuthProvider>();
    await lp.load();
    final skipped = await lp.checkAutoRepayments(
      walletProvider: wp,
      expenseProvider: ep,
      userId: auth.userId,
    );
    if (mounted && skipped.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Auto-repay skipped: ${skipped.join(', ')} — not enough balance',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LoanProvider>();
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Loans'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showLoanSheet(context),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : provider.loans.isEmpty
          ? _emptyState(provider.error)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primaryDark,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _summaryItem(
                        'Total Owed',
                        'RM ${fmt.format(provider.totalOwed)}',
                      ),
                      Container(width: 1, height: 40, color: Colors.white24),
                      _summaryItem(
                        'Total Borrowed',
                        'RM ${fmt.format(provider.totalBorrowed)}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ...provider.loans.map((l) => _loanCard(context, l, fmt)),
                const SizedBox(height: 80),
              ],
            ),
    );
  }

  Widget _summaryItem(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );

  Widget _emptyState(String? error) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.request_quote_outlined,
          size: 64,
          color: AppColors.textSecondary.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 16),
        Text(
          error != null ? "Couldn't sync loans from the cloud" : 'No loans yet',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          error != null
              ? 'You can still tap + to add a loan — it\'ll sync once the connection is back'
              : 'Tap + to record money you\'ve borrowed',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    ),
  );

  Widget _loanCard(BuildContext context, LoanModel loan, NumberFormat fmt) {
    final pct = (loan.progress * 100).toStringAsFixed(0);
    final isComplete = loan.isCompleted || loan.progress >= 1.0;
    final paceText = _paceText(loan, isComplete, fmt);

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
                    Text(
                      loan.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    if (loan.autoRepayEnabled) ...[
                      const SizedBox(height: 4),
                      _badge(
                        '🔄 Auto',
                        AppColors.primary.withValues(alpha: 0.1),
                        AppColors.primary,
                      ),
                    ],
                  ],
                ),
              ),
              if (isComplete)
                _badge(
                  'Paid Off',
                  AppColors.budgetGreen.withValues(alpha: 0.15),
                  AppColors.budgetGreen,
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'repay') _showRepaySheet(context, loan, fmt);
                  if (v == 'auto') _showAutoRepaySheet(context, loan);
                  if (v == 'edit') _showLoanSheet(context, loan: loan);
                  if (v == 'delete') _confirmDelete(context, loan);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'repay',
                    child: Row(
                      children: [
                        Icon(Icons.payments_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Repay'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'auto',
                    child: Row(
                      children: [
                        Icon(Icons.autorenew, size: 18),
                        SizedBox(width: 8),
                        Text('Auto-Repay'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Edit Loan'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Delete', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'RM ${fmt.format(loan.remaining)} owed',
                style: const TextStyle(
                  color: AppColors.budgetRed,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              Text(
                'RM ${fmt.format(loan.principalAmount)} borrowed',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: loan.progress,
              minHeight: 8,
              backgroundColor: AppColors.textSecondary.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(
                isComplete ? AppColors.budgetGreen : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$pct% repaid',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          if (paceText != null) ...[
            const SizedBox(height: 6),
            Text(
              paceText,
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Only ever based on auto-repay (loans have no deadline concept here) —
  /// nothing shown if auto-repay isn't set up.
  String? _paceText(LoanModel loan, bool isComplete, NumberFormat fmt) {
    if (isComplete || loan.remaining <= 0) return null;
    if (loan.autoRepayEnabled &&
        loan.autoRepayAmount != null &&
        loan.autoRepayAmount! > 0) {
      final months = (loan.remaining / loan.autoRepayAmount!).ceil();
      return 'RM ${fmt.format(loan.autoRepayAmount)}/mo → paid off in $months mo';
    }
    return null;
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );

  // ── Repay Sheet ─────────────────────────────────────────────────────────────

  void _showRepaySheet(BuildContext context, LoanModel loan, NumberFormat fmt) {
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Repay "${loan.name}"',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Owed: RM ${fmt.format(loan.remaining)} / RM ${fmt.format(loan.principalAmount)}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'From wallet',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
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
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount (RM)',
                  prefixText: 'RM ',
                  helperText: 'Max: RM ${fmt.format(loan.remaining)}',
                ),
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
                    if (amount > loan.remaining) {
                      setSheet(
                        () => errorMsg =
                            'Cannot exceed remaining balance of RM ${fmt.format(loan.remaining)}',
                      );
                      return;
                    }
                    final balance = wp.walletBalance(
                      selectedWallet.id,
                      ep.expenses,
                    );
                    if (amount > balance) {
                      setSheet(
                        () => errorMsg =
                            '${selectedWallet.name} only has RM ${fmt.format(balance)} — not enough to repay RM ${fmt.format(amount)}',
                      );
                      return;
                    }
                    final auth = context.read<AuthProvider>();
                    await context.read<LoanProvider>().repay(
                      loan: loan,
                      amount: amount,
                      sourceWalletId: selectedWallet.id,
                      expenseProvider: ep,
                      userId: auth.userId,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Repay'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Auto-Repay Sheet ─────────────────────────────────────────────────────────

  void _showAutoRepaySheet(BuildContext context, LoanModel loan) {
    final wp = context.read<WalletProvider>();
    final ep = context.read<ExpenseProvider>();
    final wallets = wp.wallets;
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    bool enabled = loan.autoRepayEnabled;
    WalletModel selectedWallet = wallets.firstWhere(
      (w) => w.id == loan.autoRepaySourceWalletId,
      orElse: () => wp.defaultWallet,
    );
    final amountCtrl = TextEditingController(
      text: loan.autoRepayAmount?.toStringAsFixed(2) ?? '',
    );
    int dayOfMonth = loan.autoRepayDayOfMonth ?? 1;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Auto-Repay: ${loan.name}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
                    ? 'Repayment runs automatically each month'
                    : 'Enable to set up auto-repay',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              if (enabled) ...[
                const SizedBox(height: 20),
                const Text(
                  'From wallet',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 6),
                _walletDropdown(
                  wallets: wallets,
                  selected: selectedWallet,
                  expenses: ep.expenses,
                  wp: wp,
                  fmt: fmt,
                  onChanged: (w) => setSheet(() => selectedWallet = w!),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Repayment amount (RM)',
                    prefixText: 'RM ',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Day of month',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    DropdownButton<int>(
                      value: dayOfMonth,
                      underline: const SizedBox.shrink(),
                      items: List.generate(28, (i) => i + 1)
                          .map(
                            (d) =>
                                DropdownMenuItem(value: d, child: Text('$d')),
                          )
                          .toList(),
                      onChanged: (v) => setSheet(() => dayOfMonth = v ?? 1),
                    ),
                    const Text(
                      'th of each month',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
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
                    await context.read<LoanProvider>().update(
                      loan.copyWith(
                        autoRepayEnabled: enabled,
                        autoRepayAmount: enabled ? amount : null,
                        autoRepaySourceWalletId: enabled
                            ? selectedWallet.id
                            : null,
                        autoRepayDayOfMonth: enabled ? dayOfMonth : null,
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

  // ── Create / Edit Loan Sheet ────────────────────────────────────────────────

  void _showLoanSheet(BuildContext context, {LoanModel? loan}) {
    final wp = context.read<WalletProvider>();
    final nameCtrl = TextEditingController(text: loan?.name ?? '');
    final principalCtrl = TextEditingController(
      text: loan != null ? loan.principalAmount.toStringAsFixed(2) : '',
    );
    // Only relevant when creating — an existing loan's principal was
    // already disbursed, editing just adjusts the name/amount on record.
    bool creditWallet = loan == null;
    WalletModel selectedWallet = wp.defaultWallet;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loan == null ? 'New Loan' : 'Edit Loan',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Loan name',
                  hintText: 'e.g. Public Bank Personal Loan',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: principalCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Amount borrowed (RM)',
                ),
              ),
              if (loan == null) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Credit this cash to a wallet',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Turn off if you already added this money separately',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: creditWallet,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) => setSheetState(() => creditWallet = v),
                ),
                if (creditWallet)
                  _walletDropdown(
                    wallets: wp.wallets,
                    selected: selectedWallet,
                    expenses: context.read<ExpenseProvider>().expenses,
                    wp: wp,
                    fmt: NumberFormat('#,##0.00', 'en_MY'),
                    onChanged: (w) => setSheetState(() => selectedWallet = w!),
                  ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final principal = double.tryParse(principalCtrl.text) ?? 0;
                    if (name.isEmpty || principal <= 0) return;

                    final auth = context.read<AuthProvider>();

                    if (loan == null) {
                      await context.read<LoanProvider>().disburse(
                        userId: auth.userId,
                        name: name,
                        principalAmount: principal,
                        creditWalletId: creditWallet
                            ? selectedWallet.id
                            : null,
                        expenseProvider: context.read<ExpenseProvider>(),
                      );
                    } else {
                      await context.read<LoanProvider>().update(
                        loan.copyWith(name: name, principalAmount: principal),
                      );
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(loan == null ? 'Add Loan' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, LoanModel loan) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Loan'),
        content: Text(
          'Delete "${loan.name}"? This will not affect any past transactions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<LoanProvider>().delete(loan.id);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
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
    child: Row(
      children: [
        Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              color: Colors.red.shade700,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
            child: Row(
              children: [
                Text(w.icon, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 10),
                Expanded(child: Text(w.name)),
                Text(
                  'RM ${fmt.format(bal)}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/expense_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/location/providers/location_provider.dart';
import '../../../features/savings_goals/providers/savings_goal_provider.dart';
import '../../../features/wallet/providers/wallet_provider.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../../ocr/screens/scan_receipt_screen.dart';

class AddExpenseScreen extends StatefulWidget {
  final ExpenseModel? existingExpense;
  const AddExpenseScreen({super.key, this.existingExpense});

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  CategoryModel? _selectedCategory;
  WalletModel? _selectedWallet;
  DateTime _selectedDate = DateTime.now();
  bool _saving = false;
  String _type = 'expense';

  SavingsGoalModel? _selectedGoal;

  bool get _isEdit => widget.existingExpense != null;
  bool get _isIncome => _type == 'income';

  @override
  void initState() {
    super.initState();
    final e = widget.existingExpense;
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(2);
      _descCtrl.text = e.description;
      _selectedDate = e.date;
      _type = e.type;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wp = context.read<WalletProvider>();
    if (_selectedWallet == null) {
      if (_isEdit) {
        _selectedWallet = wp.wallets
            .where((w) => w.id == widget.existingExpense!.walletId)
            .firstOrNull ?? wp.defaultWallet;
      } else {
        _selectedWallet = wp.defaultWallet;
      }
    }
    if (_selectedCategory == null && _isEdit) {
      final bp = context.read<BudgetProvider>();
      final allCats = [...bp.categories, ...bp.incomeCategories];
      _selectedCategory = allCats
          .where((c) => c.id == widget.existingExpense!.categoryId)
          .firstOrNull;
    }
    // Auto-select from location hint (expenses only)
    if (_selectedCategory == null && !_isEdit && !_isIncome) {
      final cats = context.read<BudgetProvider>().categories;
      final lp = context.read<LocationProvider>();
      if (lp.activeLocation?.categoryHint != null) {
        _selectedCategory = cats
            .where((c) =>
                c.name.toLowerCase().contains(
                    lp.activeLocation!.categoryHint!.toLowerCase()) ||
                lp.activeLocation!.categoryHint!
                    .toLowerCase()
                    .contains(c.name.toLowerCase()))
            .firstOrNull;
      }
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _switchType(String newType) {
    if (newType == _type) return;
    setState(() {
      _type = newType;
      _selectedCategory = null;
      if (newType == 'income') _selectedGoal = null;
    });
  }

  Future<void> _pickSavingsGoal() async {
    final sp = context.read<SavingsGoalProvider>();
    await sp.loadIfNeeded();
    if (!mounted) return;
    final goals = sp.goals;
    if (goals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No savings goals found')),
      );
      return;
    }
    final fmt = NumberFormat('#,##0.00', 'en_MY');
    final selected = await showModalBottomSheet<SavingsGoalModel>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('Select Savings Goal',
                style:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ...goals.map((g) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  child: const Text('🎯',
                      style: TextStyle(fontSize: 16)),
                ),
                title: Text(g.name),
                subtitle: Text(
                    'Available: RM ${fmt.format(g.currentAmount)} / RM ${fmt.format(g.targetAmount)}'),
                trailing: g.isCompleted
                    ? const Icon(Icons.check_circle,
                        color: AppColors.budgetGreen)
                    : null,
                onTap: () => Navigator.pop(ctx, g),
              )),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (selected != null) {
      setState(() {
        _selectedGoal = selected;
        _selectedWallet = null;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a category')),
      );
      return;
    }

    final amount = double.parse(_amountCtrl.text);

    // Validate savings goal balance if spending from one
    if (_selectedGoal != null && amount > _selectedGoal!.currentAmount) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Amount exceeds ${_selectedGoal!.name} balance of RM ${_selectedGoal!.currentAmount.toStringAsFixed(2)}'),
      ));
      return;
    }

    setState(() => _saving = true);
    try {
      final userId = context.read<AuthProvider>().userId;
      final expProvider = context.read<ExpenseProvider>();
      final sgProvider = context.read<SavingsGoalProvider>();
      final bp = context.read<BudgetProvider>();

      if (_isEdit) {
        await expProvider.updateExpense(
          widget.existingExpense!.copyWith(
            categoryId: _selectedCategory!.id,
            amount: amount,
            description: _descCtrl.text.trim(),
            date: _selectedDate,
            type: _type,
          ),
        );
      } else if (_selectedGoal != null) {
        // Spending from a savings goal — use special walletId, deduct from goal
        await expProvider.addExpense(
          userId: userId,
          categoryId: _selectedCategory!.id,
          amount: amount,
          description: _descCtrl.text.trim(),
          date: _selectedDate,
          type: 'expense',
          walletId: 'savings_goal',
          savingsGoalId: _selectedGoal!.id,
        );
        final newAmount = _selectedGoal!.currentAmount - amount;
        await sgProvider.update(
          _selectedGoal!.copyWith(
            currentAmount: newAmount,
            isCompleted: newAmount >= _selectedGoal!.targetAmount,
          ),
        );
      } else {
        await expProvider.addExpense(
          userId: userId,
          categoryId: _selectedCategory!.id,
          amount: amount,
          description: _descCtrl.text.trim(),
          date: _selectedDate,
          type: _type,
          walletId: _selectedWallet?.id ?? 'default_account',
        );
      }

      if (mounted) {
        bp.recalculate(
            expProvider.expensesForMonth(DateTime.now().month, DateTime.now().year));
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    final wp = context.watch<WalletProvider>();
    final lp = context.watch<LocationProvider>();
    final locationName = lp.activeLocation?.name;
    final cats = _isIncome ? bp.incomeCategories : bp.categories;
    final accentColor = _isIncome ? AppColors.budgetGreen : AppColors.primary;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(_isEdit ? 'Edit Record' : 'Add Record',
                style: const TextStyle(color: Colors.white)),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Input method row (add only) ──────────────────────
                    if (!_isEdit) ...[
                      Row(children: [
                        _MethodCard(
                          icon: Icons.camera_alt_outlined,
                          label: 'Scan receipt',
                          sub: 'Auto-fill via OCR',
                          selected: false,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ScanReceiptScreen()),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _MethodCard(
                          icon: Icons.mic_outlined,
                          label: 'Voice input',
                          sub: 'Speak your expense',
                          selected: false,
                          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Voice input — partner module (Yen Han Soon)')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _MethodCard(
                          icon: Icons.edit_outlined,
                          label: 'Manual entry',
                          sub: 'Selected',
                          selected: true,
                          onTap: () {},
                        ),
                      ]),
                      const SizedBox(height: 16),
                    ],

                    // ── Expense / Income toggle ───────────────────────────
                    if (!_isEdit) ...[
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEEEEE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(children: [
                          _TypeTab(
                            label: 'Expense',
                            icon: Icons.arrow_upward_rounded,
                            selected: !_isIncome,
                            color: AppColors.budgetRed,
                            onTap: () => _switchType('expense'),
                          ),
                          _TypeTab(
                            label: 'Income',
                            icon: Icons.arrow_downward_rounded,
                            selected: _isIncome,
                            color: AppColors.budgetGreen,
                            onTap: () => _switchType('income'),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // ── AI location banner ───────────────────────────────
                    if (locationName != null && !_isEdit && !_isIncome)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF8E1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFE082)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.auto_awesome,
                              color: AppColors.budgetYellow, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _selectedCategory != null
                                  ? 'At $locationName — ${_selectedCategory!.icon} ${_selectedCategory!.name} pre-selected. Change below if needed.'
                                  : 'At $locationName — select a category below.',
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF7C5800)),
                            ),
                          ),
                        ]),
                      ),

                    // ── Amount ───────────────────────────────────────────
                    const Text('Amount (RM)',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amountCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: accentColor),
                      decoration: InputDecoration(
                        prefixText: 'RM ',
                        prefixStyle: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: accentColor),
                        hintText: '0.00',
                        border: UnderlineInputBorder(
                            borderSide:
                                BorderSide(color: accentColor, width: 2)),
                        enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFFE0E0E0))),
                        focusedBorder: UnderlineInputBorder(
                            borderSide:
                                BorderSide(color: accentColor, width: 2)),
                        filled: false,
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter an amount';
                        if (double.tryParse(v) == null ||
                            double.parse(v) <= 0) {
                          return 'Enter a valid amount';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // ── Category ─────────────────────────────────────────
                    const Text('Category',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: cats.map((c) {
                        final selected = _selectedCategory?.id == c.id;
                        final color = AppColors.fromHex(c.colorHex);
                        return GestureDetector(
                          onTap: () =>
                              setState(() => _selectedCategory = c),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withValues(alpha: 0.12)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: selected
                                    ? color
                                    : const Color(0xFFE0E0E0),
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(c.icon,
                                      style: const TextStyle(fontSize: 15)),
                                  const SizedBox(width: 6),
                                  Text(
                                    c.name.split(' ').first,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: selected
                                          ? color
                                          : AppColors.textPrimary,
                                    ),
                                  ),
                                ]),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    // ── Wallet ────────────────────────────────────────────
                    const Text('Wallet',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    // Regular wallet picker (hidden when savings goal selected)
                    if (_selectedGoal == null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: DropdownButton<WalletModel>(
                          value: _selectedWallet,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: wp.wallets
                              .map((w) => DropdownMenuItem(
                                    value: w,
                                    child: Row(children: [
                                      Text(w.icon,
                                          style: const TextStyle(
                                              fontSize: 18)),
                                      const SizedBox(width: 10),
                                      Text(w.name),
                                    ]),
                                  ))
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _selectedWallet = v),
                        ),
                      ),
                    // Savings goal wallet (only for expenses, not edit)
                    if (!_isEdit && !_isIncome) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: _selectedGoal != null
                            ? () => setState(() {
                                  _selectedGoal = null;
                                  _selectedWallet = wp.defaultWallet;
                                })
                            : _pickSavingsGoal,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: _selectedGoal != null
                                ? AppColors.primary.withValues(alpha: 0.06)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _selectedGoal != null
                                  ? AppColors.primary
                                  : const Color(0xFFE0E0E0),
                            ),
                          ),
                          child: Row(children: [
                            const Text('🎯',
                                style: TextStyle(fontSize: 18)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _selectedGoal != null
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(_selectedGoal!.name,
                                            style: const TextStyle(
                                                fontWeight:
                                                    FontWeight.w600,
                                                fontSize: 14)),
                                        Text(
                                            'Available: RM ${_selectedGoal!.currentAmount.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                                color:
                                                    AppColors.textSecondary,
                                                fontSize: 12)),
                                      ],
                                    )
                                  : const Text(
                                      'Pay from Savings Goal',
                                      style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 14),
                                    ),
                            ),
                            Icon(
                              _selectedGoal != null
                                  ? Icons.close
                                  : Icons.chevron_right,
                              color: AppColors.textSecondary,
                              size: 18,
                            ),
                          ]),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    // ── Date ─────────────────────────────────────────────
                    const Text('Date',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: _pickDate,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: Row(children: [
                          Icon(Icons.calendar_today_outlined,
                              color: accentColor, size: 18),
                          const SizedBox(width: 10),
                          Text(DateFormat('d MMM yyyy').format(_selectedDate),
                              style: const TextStyle(fontSize: 15)),
                          const Spacer(),
                          const Icon(Icons.arrow_drop_down,
                              color: AppColors.textSecondary),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Details ───────────────────────────────────────────
                    const Text('Details',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _descCtrl,
                      maxLength: 100,
                      decoration: InputDecoration(
                        hintText: _isIncome
                            ? 'e.g. Monthly salary'
                            : 'e.g. Lunch at Mamak',
                        counterText: '',
                      ),
                    ),

                    // ── Location (auto-detected, expenses only) ───────────
                    if (locationName != null && !_isIncome) ...[
                      const SizedBox(height: 20),
                      const Text('Location',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.location_on,
                              color: AppColors.budgetRed, size: 18),
                          const SizedBox(width: 10),
                          Text(locationName,
                              style: const TextStyle(fontSize: 15)),
                        ]),
                      ),
                    ],

                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: accentColor,
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_isEdit ? 'Update Record' : 'Save Record'),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _TypeTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 2))
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? color : AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                    color: selected ? color : AppColors.textSecondary,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  const _MethodCard({
    required this.icon,
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.primarySurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : const Color(0xFFE0E0E0),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: selected
                    ? AppColors.primary
                    : AppColors.textSecondary,
                size: 24),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? AppColors.primary
                        : AppColors.textPrimary),
                textAlign: TextAlign.center),
            Text(sub,
                style: TextStyle(
                    fontSize: 10,
                    color: selected
                        ? AppColors.primary
                        : AppColors.textSecondary),
                textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

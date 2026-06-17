import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/expense_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/location/providers/location_provider.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/theme/app_colors.dart';

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
  DateTime _selectedDate = DateTime.now();
  bool _saving = false;

  bool get _isEdit => widget.existingExpense != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existingExpense;
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(2);
      _descCtrl.text = e.description;
      _selectedDate = e.date;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedCategory == null) {
      final cats = context.read<BudgetProvider>().categories;
      if (_isEdit) {
        _selectedCategory = cats
            .where((c) => c.id == widget.existingExpense!.categoryId)
            .firstOrNull;
      }
      // Auto-select from location hint if available
      if (_selectedCategory == null) {
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
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
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

    setState(() => _saving = true);
    final userId = context.read<AuthProvider>().userId;
    final expProvider = context.read<ExpenseProvider>();

    if (_isEdit) {
      await expProvider.updateExpense(
        widget.existingExpense!.copyWith(
          categoryId: _selectedCategory!.id,
          amount: double.parse(_amountCtrl.text),
          description: _descCtrl.text.trim(),
          date: _selectedDate,
        ),
      );
    } else {
      await expProvider.addExpense(
        userId: userId,
        categoryId: _selectedCategory!.id,
        amount: double.parse(_amountCtrl.text),
        description: _descCtrl.text.trim(),
        date: _selectedDate,
      );
    }

    if (mounted) {
      final bp = context.read<BudgetProvider>();
      bp.recalculate(expProvider.forMonth(DateTime.now().month, DateTime.now().year));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = context.watch<BudgetProvider>().categories;
    final lp = context.watch<LocationProvider>();
    final locationName = lp.activeLocation?.name;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // ── Dark green app bar ──────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(_isEdit ? 'Edit Expense' : 'Add Expense',
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
                    // ── Method selection (Manual only; OCR/Voice are partner modules) ──
                    if (!_isEdit) ...[
                      Row(children: [
                        _MethodCard(
                          icon: Icons.camera_alt_outlined,
                          label: 'Scan receipt',
                          sub: 'Auto-fill via OCR',
                          selected: false,
                          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'OCR Receipt scanning — partner module (Yen Han Soon)')),
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

                    // ── AI location banner ──────────────────────────────────
                    if (locationName != null && !_isEdit)
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
                              'AI detected $locationName. Category pre-set to ${_selectedCategory?.name ?? "Shopping"}.',
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF7C5800)),
                            ),
                          ),
                        ]),
                      ),

                    // ── Amount ────────────────────────────────────────────
                    const Text('Amount (RM)',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amountCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(
                          fontSize: 32, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        prefixText: 'RM ',
                        prefixStyle: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary),
                        hintText: '0.00',
                        border: UnderlineInputBorder(
                            borderSide: BorderSide(
                                color: AppColors.primary, width: 2)),
                        enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFFE0E0E0))),
                        focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                                color: AppColors.primary, width: 2)),
                        filled: false,
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter an amount';
                        if (double.tryParse(v) == null || double.parse(v) <= 0) {
                          return 'Enter a valid amount';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // ── Item name ──────────────────────────────────────────
                    const Text('Item name',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _descCtrl,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Lunch at Mamak',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Category chips ────────────────────────────────────
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
                            child: Row(mainAxisSize: MainAxisSize.min,
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

                    // ── Date ──────────────────────────────────────────────
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
                          border: Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.calendar_today_outlined,
                              color: AppColors.primary, size: 18),
                          const SizedBox(width: 10),
                          Text(DateFormat('d MMM yyyy').format(_selectedDate),
                              style: const TextStyle(fontSize: 15)),
                          const Spacer(),
                          const Icon(Icons.arrow_drop_down,
                              color: AppColors.textSecondary),
                        ]),
                      ),
                    ),

                    // ── Location (auto-detected) ────────────────────────
                    if (locationName != null) ...[
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
                          border: Border.all(color: const Color(0xFFE0E0E0)),
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
                          minimumSize: const Size.fromHeight(50)),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_isEdit ? 'Update Expense' : 'Save Expense'),
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
            color: selected
                ? AppColors.primarySurface
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.primary
                  : const Color(0xFFE0E0E0),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: selected ? AppColors.primary : AppColors.textSecondary,
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

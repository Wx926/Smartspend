import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/budget_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/theme/app_colors.dart';

class SetBudgetScreen extends StatefulWidget {
  final BudgetStatus? existingStatus;
  const SetBudgetScreen({super.key, this.existingStatus});

  @override
  State<SetBudgetScreen> createState() => _SetBudgetScreenState();
}

class _SetBudgetScreenState extends State<SetBudgetScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  CategoryModel? _selectedCategory;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existingStatus != null) {
      _amountCtrl.text =
          widget.existingStatus!.budget.amount.toStringAsFixed(2);
      // We'll find the category after build
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.existingStatus != null && _selectedCategory == null) {
      final cats = context.read<BudgetProvider>().categories;
      _selectedCategory = cats
          .where((c) => c.id == widget.existingStatus!.budget.categoryId)
          .firstOrNull;
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
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
    try {
      final userId = context.read<AuthProvider>().userId;
      await context.read<BudgetProvider>().setBudget(
            userId: userId,
            categoryId: _selectedCategory!.id,
            amount: double.parse(_amountCtrl.text),
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save budget: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    final isEdit = widget.existingStatus != null;

    // Filter out already-budgeted categories when adding new
    final available = isEdit
        ? bp.categories
        : bp.categories
            .where((c) =>
                !bp.budgets.any((b) => b.categoryId == c.id))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit Budget' : 'Set Budget'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Category',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),
            DropdownButtonFormField<CategoryModel>(
              initialValue: _selectedCategory,
              hint: const Text('Select category'),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE0E0E0))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE0E0E0))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: AppColors.primary, width: 2)),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              items: available
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Row(
                          children: [
                            Text(c.icon,
                                style: const TextStyle(fontSize: 20)),
                            const SizedBox(width: 12),
                            Text(c.name),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: isEdit
                  ? null
                  : (v) => setState(() => _selectedCategory = v),
            ),
            const SizedBox(height: 20),
            const Text('Monthly Budget Amount (RM)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                prefixText: 'RM ',
                hintText: '0.00',
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Enter an amount';
                final amount = double.tryParse(v);
                if (amount == null || amount <= 0) {
                  return 'Enter a valid positive amount';
                }
                return null;
              },
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(isEdit ? 'Update Budget' : 'Set Budget'),
            ),
          ],
        ),
      ),
    );
  }
}

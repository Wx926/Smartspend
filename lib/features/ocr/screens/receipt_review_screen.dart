import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../models/ocr_result.dart';

class ReceiptReviewScreen extends StatefulWidget {
  final OcrResult result;
  const ReceiptReviewScreen({super.key, required this.result});

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  late final TextEditingController _vendorCtrl;
  late DateTime _date;
  late List<_EditableItem> _items;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _vendorCtrl = TextEditingController(text: widget.result.vendorName ?? '');
    _date = widget.result.date != null
        ? DateTime.tryParse(widget.result.date!) ?? DateTime.now()
        : DateTime.now();

    if (widget.result.lineItems.isNotEmpty) {
      _items = widget.result.lineItems
          .map((li) => _EditableItem(
                nameCtrl: TextEditingController(text: li.itemName),
                priceCtrl: TextEditingController(
                    text: li.price.toStringAsFixed(2)),
                categoryId: li.categoryId,
                categoryName: li.categoryName,
              ))
          .toList();
    } else {
      // No line items — create one fallback row using the total amount
      _items = [
        _EditableItem(
          nameCtrl: TextEditingController(
              text: widget.result.vendorName ?? 'Receipt'),
          priceCtrl: TextEditingController(
              text: (widget.result.amount ?? 0.0).toStringAsFixed(2)),
          categoryId: widget.result.suggestedCategoryId,
          categoryName: widget.result.suggestedCategoryName ?? 'Others',
        ),
      ];
    }
  }

  @override
  void dispose() {
    _vendorCtrl.dispose();
    for (final item in _items) {
      item.nameCtrl.dispose();
      item.priceCtrl.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final uid = context.read<AuthProvider>().user!.id;
      final categories = context.read<BudgetProvider>().categories;
      final db = SupabaseService.instance;
      const uuid = Uuid();
      final now = DateTime.now();
      String? firstExpenseId;

      for (final item in _items) {
        final price = double.tryParse(item.priceCtrl.text) ?? 0;
        if (price <= 0) continue;

        // Resolve category — use selected or fall back to Others
        final catId = item.categoryId ??
            categories
                .firstWhere(
                  (c) => c.name == 'Others',
                  orElse: () => categories.first,
                )
                .id;

        final expense = ExpenseModel(
          id: uuid.v4(),
          userId: uid,
          categoryId: catId,
          amount: price,
          description: item.nameCtrl.text.trim(),
          date: _date,
          createdAt: now,
          updatedAt: now,
        );

        final saved = await db.insertExpense(expense);
        firstExpenseId ??= saved.id;
      }

      // FR 4.13: save warranty linked to the first expense created
      final w = widget.result.warranty;
      if (w != null && w.hasWarranty && firstExpenseId != null) {
        await db.insertWarranty(
          expenseId: firstExpenseId,
          vendorName: _vendorCtrl.text.trim(),
          durationMonths: w.durationMonths,
          expiryDate: w.expiryDate,
          status: w.status,
        );
      }

      // Refresh expense list in provider
      if (mounted) {
        await context.read<ExpenseProvider>().loadExpenses();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Expenses saved successfully!'),
            backgroundColor: AppColors.budgetGreen,
          ),
        );
        // Pop back to whichever screen launched the scan
        Navigator.popUntil(context, (route) => route.isFirst || route.settings.name != null);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: AppColors.budgetRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<BudgetProvider>().categories;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: AppColors.textWhite,
        title: const Text('Review & Confirm'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionCard(
            title: 'Receipt Details',
            child: Column(
              children: [
                _field(label: 'Vendor / Store', controller: _vendorCtrl),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: _inputDeco('Date'),
                    child: Text(
                      DateFormat('dd MMM yyyy').format(_date),
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            title: 'Line Items (FR 4.6)',
            trailing: TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Row'),
              onPressed: () => setState(() => _items.add(_EditableItem(
                    nameCtrl: TextEditingController(),
                    priceCtrl: TextEditingController(),
                    categoryId: null,
                    categoryName: 'Others',
                  ))),
            ),
            child: Column(
              children: [
                for (int i = 0; i < _items.length; i++) ...[
                  _LineItemRow(
                    item: _items[i],
                    categories: categories,
                    onDelete: _items.length > 1
                        ? () => setState(() => _items.removeAt(i))
                        : null,
                    onCategoryChanged: (cat) => setState(() {
                      _items[i].categoryId = cat.id;
                      _items[i].categoryName = cat.name;
                    }),
                  ),
                  if (i < _items.length - 1) const Divider(height: 20),
                ],
              ],
            ),
          ),
          if (widget.result.warranty != null) ...[
            const SizedBox(height: 12),
            _warrantyCard(widget.result.warranty!),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.textWhite,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text('Save ${_items.length} Expense${_items.length != 1 ? 's' : ''}'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 2))
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: AppColors.textSecondary)),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _field(
      {required String label, required TextEditingController controller}) {
    return TextFormField(
      controller: controller,
      decoration: _inputDeco(label),
      style: const TextStyle(color: AppColors.textPrimary),
    );
  }

  InputDecoration _inputDeco(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  Widget _warrantyCard(WarrantyInfo w) {
    Color bg;
    Color fg;
    String statusLabel;
    IconData icon;

    switch (w.status) {
      case 'green':
        bg = AppColors.alertGreenBg;
        fg = AppColors.budgetGreen;
        statusLabel = 'Valid';
        icon = Icons.verified_rounded;
        break;
      case 'yellow':
        bg = AppColors.alertYellowBg;
        fg = AppColors.budgetYellow;
        statusLabel = 'Expiring Soon';
        icon = Icons.warning_amber_rounded;
        break;
      case 'red':
        bg = AppColors.alertRedBg;
        fg = AppColors.budgetRed;
        statusLabel = 'Expired';
        icon = Icons.cancel_rounded;
        break;
      default:
        bg = AppColors.primarySurface;
        fg = AppColors.primary;
        statusLabel = 'Warranty Detected';
        icon = Icons.shield_rounded;
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Warranty $statusLabel',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: fg,
                        fontSize: 15)),
                if (w.durationMonths != null)
                  Text('Duration: ${w.durationMonths} month(s)',
                      style: TextStyle(color: fg, fontSize: 13)),
                if (w.expiryDate != null)
                  Text('Expires: ${w.expiryDate}',
                      style: TextStyle(color: fg, fontSize: 13)),
                if (w.daysRemaining != null && w.daysRemaining! >= 0)
                  Text('${w.daysRemaining} day(s) remaining',
                      style: TextStyle(color: fg, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableItem {
  TextEditingController nameCtrl;
  TextEditingController priceCtrl;
  String? categoryId;
  String categoryName;

  _EditableItem({
    required this.nameCtrl,
    required this.priceCtrl,
    required this.categoryId,
    required this.categoryName,
  });
}

class _LineItemRow extends StatelessWidget {
  final _EditableItem item;
  final List<CategoryModel> categories;
  final VoidCallback? onDelete;
  final ValueChanged<CategoryModel> onCategoryChanged;

  const _LineItemRow({
    required this.item,
    required this.categories,
    required this.onDelete,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: item.nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Item',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: item.priceCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'RM',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    color: AppColors.budgetRed),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (categories.isNotEmpty)
          DropdownButtonFormField<CategoryModel>(
            value: categories
                .where((c) => c.id == item.categoryId)
                .firstOrNull,
            decoration: const InputDecoration(
              labelText: 'Category',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: categories
                .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                .toList(),
            onChanged: (cat) {
              if (cat != null) onCategoryChanged(cat);
            },
          ),
      ],
    );
  }
}

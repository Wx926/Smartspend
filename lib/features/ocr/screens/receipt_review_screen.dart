import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
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
  final XFile? imageFile;
  const ReceiptReviewScreen({super.key, required this.result, this.imageFile});

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  late final TextEditingController _vendorCtrl;
  late DateTime _date;
  late List<_EditableItem> _items;
  bool _saving = false;
  int _selectedTab = 0;

  static const _tabs = [
    'Receipt Review', 'Voice Input', 'Gallery', 'Receipt History', 'Success'
  ];

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
                priceCtrl: TextEditingController(text: li.price.toStringAsFixed(2)),
                categoryId: li.categoryId,
                categoryName: li.categoryName,
              ))
          .toList();
    } else {
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
      final uid = context.read<AuthProvider>().userId;
      final categories = context.read<BudgetProvider>().categories;
      final db = SupabaseService.instance;
      const uuid = Uuid();
      final now = DateTime.now();
      String? firstExpenseId;

      for (final item in _items) {
        final price = double.tryParse(item.priceCtrl.text) ?? 0;
        if (price <= 0) continue;

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

      if (mounted) await context.read<ExpenseProvider>().load();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Expenses saved successfully!'),
            backgroundColor: Color(0xFF27AE60),
          ),
        );
        Navigator.popUntil(context, (r) => r.isFirst || r.settings.name != null);
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

  String _categoryEmoji(String cat) {
    switch (cat.toLowerCase()) {
      case 'food & dining': return '🍔';
      case 'transport': return '🚗';
      case 'shopping': return '🛍️';
      case 'entertainment': return '🎬';
      case 'health': return '💊';
      case 'utilities': return '💡';
      default: return '📦';
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<BudgetProvider>().categories;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A5276),
        foregroundColor: Colors.white,
        title: const Text('Receipt Review',
            style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF27AE60),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('AI Processed',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Tab bar ────────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  final sel = i == _selectedTab;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedTab = i),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: sel
                            ? const Color(0xFF6C3483)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: sel
                            ? null
                            : Border.all(color: const Color(0xFFDDDDDD)),
                      ),
                      child: Text(
                        _tabs[i],
                        style: TextStyle(
                          color: sel ? Colors.white : const Color(0xFF555555),
                          fontSize: 13,
                          fontWeight: sel
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          // ── Scrollable content ──────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Receipt Image card ───────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Receipt Image',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 15)),
                          Text(
                            DateFormat('dd MMM yyyy, h:mm a').format(_date),
                            style: const TextStyle(
                                color: Color(0xFF888888), fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: _pickDate,
                        child: Container(
                          height: 130,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: const Color(0xFFCCCCCC), width: 1),
                            borderRadius: BorderRadius.circular(8),
                            color: const Color(0xFFF8F8F8),
                          ),
                          child: widget.imageFile != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: Image.file(
                                    File(widget.imageFile!.path),
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.receipt_long_rounded,
                                        size: 44, color: Color(0xFFAAAAAA)),
                                    SizedBox(height: 6),
                                    Text('Receipt captured',
                                        style: TextStyle(
                                            color: Color(0xFF777777),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500)),
                                    Text('Tap to view full image',
                                        style: TextStyle(
                                            color: Color(0xFFAAAAAA),
                                            fontSize: 11)),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                              color: Color(0xFF27AE60),
                              shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        const Text('AI extraction complete · 97% confidence',
                            style: TextStyle(
                                color: Color(0xFF444444), fontSize: 12)),
                      ]),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── AI Extracted Fields ──────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFDCEFD8)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(children: [
                        Icon(Icons.layers_outlined,
                            color: Color(0xFF2E7D32), size: 18),
                        SizedBox(width: 6),
                        Text('AI Extracted Fields',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                      ]),
                      const SizedBox(height: 14),
                      _extractedRow('Merchant',
                          _vendorCtrl.text.isEmpty ? '—' : _vendorCtrl.text,
                          _vendorCtrl.text.isNotEmpty),
                      _extractedRow('Date',
                          DateFormat('dd MMM yyyy').format(_date), true),
                      _extractedRow(
                          'Category',
                          '${_categoryEmoji(widget.result.suggestedCategoryName ?? 'Others')} ${widget.result.suggestedCategoryName ?? 'Others'}',
                          true),
                      _extractedRow(
                          'Total',
                          'RM ${(widget.result.amount ?? 0).toStringAsFixed(2)}',
                          widget.result.amount != null),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Line Items ───────────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Line Items',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 15)),
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 14),
                            label: const Text('Add Row',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 0),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => setState(() => _items.add(
                                _EditableItem(
                                  nameCtrl: TextEditingController(),
                                  priceCtrl: TextEditingController(),
                                  categoryId: null,
                                  categoryName: 'Others',
                                ))),
                          ),
                        ],
                      ),
                      // Table header
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: const BoxDecoration(
                            border: Border(
                                bottom: BorderSide(color: Color(0xFFEEEEEE)))),
                        child: const Row(children: [
                          Expanded(
                            flex: 3,
                            child: Text('ITEM',
                                style: TextStyle(
                                    color: Color(0xFF888888),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5)),
                          ),
                          Text('PRICE',
                              style: TextStyle(
                                  color: Color(0xFF888888),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5)),
                          SizedBox(width: 32),
                        ]),
                      ),
                      // Rows
                      for (int i = 0; i < _items.length; i++) ...[
                        _TableRow(
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
                        if (i < _items.length - 1)
                          const Divider(height: 1, color: Color(0xFFF0F0F0)),
                      ],
                    ],
                  ),
                ),

                // ── Warranty card ────────────────────────────────────
                if (widget.result.warranty != null) ...[
                  const SizedBox(height: 12),
                  _warrantyCard(widget.result.warranty!),
                ],

                const SizedBox(height: 24),

                // ── Save button ──────────────────────────────────────
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A5276),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 2,
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(
                          'Save ${_items.length} Expense${_items.length != 1 ? 's' : ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: child,
      );

  Widget _extractedRow(String label, String value, bool high) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    color: Color(0xFF888888), fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: high
                  ? const Color(0xFFE8F5E9)
                  : const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              high ? 'HIGH' : 'LOW',
              style: TextStyle(
                color: high
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFE65100),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ]),
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
          color: bg, borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Icon(icon, color: fg, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Warranty $statusLabel',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: fg,
                        fontSize: 14)),
                if (w.durationMonths != null)
                  Text('Duration: ${w.durationMonths} month(s)',
                      style: TextStyle(color: fg, fontSize: 12)),
                if (w.expiryDate != null)
                  Text('Expires: ${w.expiryDate}',
                      style: TextStyle(color: fg, fontSize: 12)),
                if (w.daysRemaining != null && w.daysRemaining! >= 0)
                  Text('${w.daysRemaining} day(s) remaining',
                      style: TextStyle(color: fg, fontSize: 12)),
              ]),
        ),
      ]),
    );
  }
}

// ── Data class ─────────────────────────────────────────────────────────────────

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

// ── Table row widget ────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final _EditableItem item;
  final List<CategoryModel> categories;
  final VoidCallback? onDelete;
  final ValueChanged<CategoryModel> onCategoryChanged;

  const _TableRow({
    required this.item,
    required this.categories,
    required this.onDelete,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: item.nameCtrl,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(),
                  hintText: 'Item name',
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
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(),
                  prefixText: 'RM ',
                  prefixStyle: TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    color: Color(0xFFE74C3C), size: 20),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ] else
              const SizedBox(width: 32),
          ]),
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<CategoryModel>(
              value: categories.where((c) => c.id == item.categoryId).firstOrNull,
              decoration: const InputDecoration(
                labelText: 'Category',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              items: categories
                  .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                  .toList(),
              onChanged: (cat) {
                if (cat != null) onCategoryChanged(cat);
              },
            ),
          ],
        ],
      ),
    );
  }
}

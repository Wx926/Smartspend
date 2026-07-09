import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/category_model.dart';
import '../../auth/providers/auth_provider.dart';
import '../../budget/providers/budget_provider.dart';
import '../../expenses/providers/expense_provider.dart';
import 'scan_receipt_screen.dart';
import 'receipt_review_screen.dart';

/// One row in Receipt History — every line item saved from the same scan
/// (sharing a batchId) is merged back into a single receipt with a summed
/// total, rather than showing one row per item.
class _ReceiptGroup {
  final String id;
  final String? merchantName;
  final String description;
  final DateTime date;
  final String source;
  final double amount;
  final String? categoryId;
  final List<ExpenseModel> items;

  const _ReceiptGroup({
    required this.id,
    required this.merchantName,
    required this.description,
    required this.date,
    required this.source,
    required this.amount,
    required this.categoryId,
    required this.items,
  });

  static List<_ReceiptGroup> groupFrom(List<ExpenseModel> items) {
    final byKey = <String, List<ExpenseModel>>{};
    for (final e in items) {
      byKey.putIfAbsent(e.batchId ?? e.id, () => []).add(e);
    }
    return byKey.entries.map((entry) {
      final group = entry.value;
      final first = group.first;
      // Majority category across the receipt's items (same tie-break the
      // backend's own OCR category suggestion already uses).
      final counts = <String, int>{};
      for (final e in group) {
        counts[e.categoryId] = (counts[e.categoryId] ?? 0) + 1;
      }
      final majorityCategoryId = counts.entries.isEmpty
          ? null
          : (counts.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value)))
                .first
                .key;
      return _ReceiptGroup(
        id: entry.key,
        merchantName: first.merchantName,
        description: first.description,
        date: first.date,
        source: first.source,
        amount: group.fold(0.0, (s, e) => s + e.amount),
        categoryId: majorityCategoryId,
        items: group,
      );
    }).toList();
  }
}

/// Shows every receipt created via scan (OCR) or voice input — gated behind
/// login, since it's tied to the user's own saved history.
class ReceiptHistoryScreen extends StatefulWidget {
  const ReceiptHistoryScreen({super.key});

  @override
  State<ReceiptHistoryScreen> createState() => _ReceiptHistoryScreenState();
}

class _ReceiptHistoryScreenState extends State<ReceiptHistoryScreen> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  String _filter = 'All';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (!auth.isLoggedIn) {
      return _signInPrompt();
    }

    final categories = context.watch<BudgetProvider>().categories;
    final categoryById = {for (final c in categories) c.id: c};

    final rawItems = context
        .watch<ExpenseProvider>()
        .expenses
        .where((e) => e.source == 'ocr' || e.source == 'voice')
        .toList();
    final receipts = _ReceiptGroup.groupFrom(rawItems)
      ..sort((a, b) => b.date.compareTo(a.date));

    // Category chips only for categories that actually have a receipt in them
    final categoryFilters = <String>{
      for (final r in receipts)
        if (categoryById[r.categoryId] != null)
          categoryById[r.categoryId]!.name,
    }.toList();

    var filtered = receipts;
    if (_filter == 'Scanned') {
      filtered = filtered.where((r) => r.source == 'ocr').toList();
    } else if (_filter == 'Voice') {
      filtered = filtered.where((r) => r.source == 'voice').toList();
    } else if (_filter != 'All') {
      filtered = filtered
          .where((r) => categoryById[r.categoryId]?.name == _filter)
          .toList();
    }
    if (_search.trim().isNotEmpty) {
      final q = _search.trim().toLowerCase();
      filtered = filtered
          .where(
            (r) =>
                (r.merchantName ?? '').toLowerCase().contains(q) ||
                r.description.toLowerCase().contains(q),
          )
          .toList();
    }

    final now = DateTime.now();
    final thisMonthCount = receipts
        .where((r) => r.date.month == now.month && r.date.year == now.year)
        .length;
    final totalAmount = receipts.fold(0.0, (s, r) => s + r.amount);

    final grouped = <String, List<_ReceiptGroup>>{};
    for (final r in filtered) {
      final key = DateFormat('MMMM yyyy').format(r.date);
      grouped.putIfAbsent(key, () => []).add(r);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _header(context, categoryFilters),
          _statsRow(receipts.length, totalAmount, thisMonthCount),
          Expanded(
            child: filtered.isEmpty
                ? _emptyState()
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final entry in grouped.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                          child: Text(
                            entry.key.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        for (final r in entry.value)
                          _receiptTile(r, categoryById[r.categoryId]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, List<String> categoryFilters) =>
      Container(
        color: AppColors.primaryDark,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Receipt History',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ScanReceiptScreen(),
                        ),
                      ),
                      icon: const Icon(
                        Icons.add,
                        color: Colors.white,
                        size: 18,
                      ),
                      label: const Text(
                        'Scan',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: 'Search receipts',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _filterChip('All'),
                      _filterChip('Scanned', icon: Icons.receipt_long),
                      _filterChip('Voice', icon: Icons.mic),
                      for (final name in categoryFilters) _filterChip(name),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _filterChip(String label, {IconData? icon}) {
    final selected = _filter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _filter = label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: selected ? Colors.white : AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statsRow(int totalReceipts, double totalAmount, int thisMonth) =>
      Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            _stat('Total receipts', '$totalReceipts records'),
            _stat(
              'Total amount',
              'RM ${totalAmount.toStringAsFixed(2)}',
              color: AppColors.budgetRed,
            ),
            _stat('This month', '$thisMonth receipts'),
          ],
        ),
      );

  Widget _stat(String label, String value, {Color? color}) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color ?? AppColors.textPrimary,
          ),
        ),
      ],
    ),
  );

  Future<bool> _confirmDelete(_ReceiptGroup r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete receipt?'),
        content: Text(
          'This will permanently delete "${r.merchantName?.isNotEmpty == true ? r.merchantName! : r.description}" '
          'and all ${r.items.length} of its line item${r.items.length == 1 ? '' : 's'}. '
          'This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.budgetRed),
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteReceipt(_ReceiptGroup r) async {
    final expenseProvider = context.read<ExpenseProvider>();
    for (final item in r.items) {
      await expenseProvider.deleteExpense(item.id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Receipt deleted'),
        backgroundColor: AppColors.budgetRed,
      ),
    );
  }

  Widget _receiptTile(_ReceiptGroup r, CategoryModel? category) {
    final isVoice = r.source == 'voice';
    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(r),
      onDismissed: (_) => _deleteReceipt(r),
      background: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: AppColors.budgetRed,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReceiptReviewScreen(existingExpenses: r.items),
          ),
        ),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isVoice ? Icons.mic : Icons.receipt_long,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.merchantName?.isNotEmpty == true
                          ? r.merchantName!
                          : r.description,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('d MMM yyyy').format(r.date),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: [
                        _tag(isVoice ? '🎤 Voice' : '📄 Scanned'),
                        if (category != null)
                          _tag('${category.icon} ${category.name}'),
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                '-RM ${r.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: AppColors.budgetRed,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
    ),
  );

  Widget _emptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.receipt_long_outlined,
          size: 56,
          color: AppColors.textSecondary,
        ),
        const SizedBox(height: 12),
        const Text(
          'No receipts found',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 4),
        const Text(
          'Scan a receipt to see it here',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    ),
  );

  Widget _signInPrompt() => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      backgroundColor: AppColors.primaryDark,
      foregroundColor: Colors.white,
      title: const Text('Receipt History'),
    ),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 56,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 16),
            const Text(
              'Sign in to view your receipt history',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Receipt history is saved to your account so it stays with you across devices.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/login'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryDark,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
              ),
              child: const Text('Sign in with Google'),
            ),
          ],
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/expense_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/theme/app_colors.dart';
import 'add_expense_screen.dart';

class ExpenseListScreen extends StatefulWidget {
  const ExpenseListScreen({super.key});
  @override
  State<ExpenseListScreen> createState() => _ExpenseListScreenState();
}

class _ExpenseListScreenState extends State<ExpenseListScreen> {
  String? _filterCategoryId;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _searchQuery = _searchCtrl.text.toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExpenseProvider>().load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ep = context.watch<ExpenseProvider>();
    final bp = context.watch<BudgetProvider>();
    final cats = bp.categories;
    final allCats = [...bp.categories, ...bp.incomeCategories];
    final catMap = {for (final c in allCats) c.id: c};

    // Filter
    var expenses = ep.expenses;
    if (_filterCategoryId != null) {
      expenses = expenses.where((e) => e.categoryId == _filterCategoryId).toList();
    }
    if (_searchQuery.isNotEmpty) {
      expenses = expenses.where((e) {
        final desc = e.description.toLowerCase();
        final cat = catMap[e.categoryId]?.name.toLowerCase() ?? '';
        return desc.contains(_searchQuery) || cat.contains(_searchQuery);
      }).toList();
    }

    // Group by month then date
    final byMonth = <String, Map<String, List<ExpenseModel>>>{};
    for (final e in expenses) {
      final monthKey = DateFormat('MMMM yyyy').format(e.date).toUpperCase();
      final dateKey = DateFormat('d MMM yyyy').format(e.date);
      byMonth.putIfAbsent(monthKey, () => {}).putIfAbsent(dateKey, () => []).add(e);
    }
    final months = byMonth.keys.toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // ── Header ──────────────────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            title: const Text('Transaction History',
                style: TextStyle(color: Colors.white)),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),

          // ── Search bar ────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.primaryDark,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search transactions...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                          onPressed: () => _searchCtrl.clear(),
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.15),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),

          // ── Category filter chips ─────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              height: 44,
              color: Colors.white,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _FilterChip(
                    label: 'All',
                    icon: null,
                    selected: _filterCategoryId == null,
                    onTap: () => setState(() => _filterCategoryId = null),
                  ),
                  ...cats.map((c) => _FilterChip(
                        label: c.name.split(' ').first,
                        icon: c.icon,
                        selected: _filterCategoryId == c.id,
                        onTap: () => setState(() =>
                            _filterCategoryId =
                                _filterCategoryId == c.id ? null : c.id),
                      )),
                ],
              ),
            ),
          ),

          // ── Transactions ──────────────────────────────────────────────
          ep.isLoading
              ? const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()))
              : expenses.isEmpty
                  ? SliverFillRemaining(
                      child: Center(
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                          const Icon(Icons.receipt_long_outlined,
                              size: 56, color: AppColors.textSecondary),
                          const SizedBox(height: 12),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No results for "$_searchQuery"'
                                : _filterCategoryId != null
                                    ? 'No transactions in this category'
                                    : 'No transactions yet',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 15),
                          ),
                        ]),
                      ),
                    )
                  : SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, mi) {
                          final monthKey = months[mi];
                          final dateGroups = byMonth[monthKey]!;
                          final dates = dateGroups.keys.toList();

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                                child: Text(monthKey,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textSecondary,
                                        letterSpacing: 1)),
                              ),
                              ...dates.expand((dateKey) {
                                final dayExpenses = dateGroups[dateKey]!;
                                return [
                                  ...dayExpenses.map((e) {
                                    final cat = catMap[e.categoryId];
                                    final color = AppColors.fromHex(cat?.colorHex ?? '6B7280');
                                    return Dismissible(
                                      key: Key(e.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 20),
                                        color: AppColors.budgetRed,
                                        child: const Icon(Icons.delete, color: Colors.white),
                                      ),
                                      confirmDismiss: (_) => showDialog<bool>(
                                        context: context,
                                        builder: (_) => AlertDialog(
                                          title: const Text('Delete'),
                                          content: const Text('Delete this transaction?'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(context, false),
                                                child: const Text('Cancel')),
                                            TextButton(
                                                onPressed: () => Navigator.pop(context, true),
                                                child: const Text('Delete',
                                                    style: TextStyle(color: AppColors.budgetRed))),
                                          ],
                                        ),
                                      ),
                                      onDismissed: (_) => context.read<ExpenseProvider>().deleteExpense(e.id),
                                      child: Container(
                                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                                        decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(12)),
                                        child: ListTile(
                                          contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 4),
                                          leading: CircleAvatar(
                                            radius: 20,
                                            backgroundColor: color.withValues(alpha: 0.15),
                                            child: Text(cat?.icon ?? '📦',
                                                style: const TextStyle(fontSize: 16)),
                                          ),
                                          title: Text(
                                            e.description.isEmpty
                                                ? (cat?.name ?? 'Expense')
                                                : e.description,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14),
                                          ),
                                          subtitle: Text(
                                            '${cat?.name ?? 'Unknown'} · ${DateFormat('d MMM').format(e.date)}',
                                            style: const TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 12),
                                          ),
                                          trailing: Text(
                                            e.type == 'income'
                                                ? '+RM ${e.amount.toStringAsFixed(2)}'
                                                : '-RM ${e.amount.toStringAsFixed(2)}',
                                            style: TextStyle(
                                                color: e.type == 'income'
                                                    ? AppColors.budgetGreen
                                                    : AppColors.budgetRed,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14),
                                          ),
                                          onTap: () async {
                                            await Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (_) => AddExpenseScreen(
                                                      existingExpense: e)),
                                            );
                                            if (context.mounted) context.read<ExpenseProvider>().load();
                                          },
                                        ),
                                      ),
                                    );
                                  }),
                                ];
                              }),
                            ],
                          );
                        },
                        childCount: months.length,
                      ),
                    ),

          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final String? icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Text(icon!, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/budget_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/theme/app_colors.dart';
import 'set_budget_screen.dart';

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final expProvider = context.read<ExpenseProvider>();
    final budgetProvider = context.read<BudgetProvider>();
    final auth = context.read<AuthProvider>();
    final now = DateTime.now();

    // Auto-copy previous month budgets if opening current month with no budgets
    final copied = await budgetProvider.autoCopyFromPreviousMonth(auth.userId);
    if (copied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Budgets copied from last month — feel free to adjust!'),
        duration: Duration(seconds: 3),
      ));
    }

    await budgetProvider.load(expProvider.forMonth(now.month, now.year));
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openSetBudget(context),
            tooltip: 'Add Budget',
          ),
        ],
      ),
      body: bp.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: Column(
                children: [
                  _buildMonthHeader(bp),
                  _buildSummaryCard(bp),
                  Expanded(child: _buildBudgetList(bp)),
                ],
              ),
            ),
    );
  }

  Widget _buildMonthHeader(BudgetProvider bp) {
    return Container(
      color: AppColors.primary,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            onPressed: () {
              final m = bp.selectedMonth;
              bp.setMonth(DateTime(m.year, m.month - 1));
              _load();
            },
          ),
          Text(
            DateFormat('MMMM yyyy').format(bp.selectedMonth),
            style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white),
            onPressed: () {
              final m = bp.selectedMonth;
              bp.setMonth(DateTime(m.year, m.month + 1));
              _load();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BudgetProvider bp) {
    final percent = bp.totalBudget > 0
        ? (bp.totalSpent / bp.totalBudget).clamp(0.0, 1.0)
        : 0.0;
    final remaining = bp.totalBudget - bp.totalSpent;
    final color = percent >= 1.0
        ? AppColors.budgetRed
        : percent >= 0.8
            ? AppColors.budgetYellow
            : AppColors.budgetGreen;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Total Spent',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                    Text(
                      'RM ${bp.totalSpent.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Total Budget',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                    Text(
                      'RM ${bp.totalBudget.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: percent,
                backgroundColor: color.withValues(alpha:0.2),
                color: color,
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${(percent * 100).toStringAsFixed(0)}% used',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                Text(
                  remaining >= 0
                      ? 'RM ${remaining.toStringAsFixed(2)} left'
                      : 'Over by RM ${(-remaining).toStringAsFixed(2)}',
                  style: TextStyle(
                      color: remaining >= 0
                          ? AppColors.textSecondary
                          : AppColors.budgetRed,
                      fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBudgetList(BudgetProvider bp) {
    if (bp.statuses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.pie_chart_outline,
                size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text('No budgets set for this month',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _openSetBudget(context),
              icon: const Icon(Icons.add),
              label: const Text('Set Budget'),
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size(200, 48)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: bp.statuses.length,
      itemBuilder: (context, i) => _BudgetCategoryCard(
        status: bp.statuses[i],
        onEdit: () => _openSetBudget(context, status: bp.statuses[i]),
        onDelete: () => _confirmDelete(context, bp.statuses[i]),
      ),
    );
  }

  void _openSetBudget(BuildContext context, {BudgetStatus? status}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SetBudgetScreen(existingStatus: status),
      ),
    ).then((_) => _load());
  }

  void _confirmDelete(BuildContext context, BudgetStatus status) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Budget'),
        content: Text(
            'Remove the ${status.categoryName} budget? Your expense data will not be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context
                  .read<BudgetProvider>()
                  .deleteBudget(status.budget.id);
              Navigator.pop(context);
            },
            child: const Text('Delete',
                style: TextStyle(color: AppColors.budgetRed)),
          ),
        ],
      ),
    );
  }
}

class _BudgetCategoryCard extends StatelessWidget {
  final BudgetStatus status;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _BudgetCategoryCard({
    required this.status,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppColors.fromHex(status.categoryColorHex);
    final percent = status.percentUsed.clamp(0.0, 1.0);
    final statusColor = status.severity == AlertSeverity.red
        ? AppColors.budgetRed
        : status.severity == AlertSeverity.yellow
            ? AppColors.budgetYellow
            : AppColors.budgetGreen;
    final statusBg = status.severity == AlertSeverity.red
        ? AppColors.alertRedBg
        : status.severity == AlertSeverity.yellow
            ? AppColors.alertYellowBg
            : AppColors.alertGreenBg;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha:0.2),
                  child: Text(status.categoryIcon,
                      style: const TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status.categoryName,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(
                        'RM ${status.spent.toStringAsFixed(2)} / RM ${status.budget.amount.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${(percent * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: percent,
                backgroundColor: color.withValues(alpha:0.15),
                color: statusColor,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Daily burn: RM ${status.dailyBurnRate.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                    Text(
                      status.isOverBudget
                          ? 'Over by RM ${(-status.remaining).toStringAsFixed(2)}'
                          : 'RM ${status.remaining.toStringAsFixed(2)} remaining',
                      style: TextStyle(
                          fontSize: 12,
                          color: status.isOverBudget
                              ? AppColors.budgetRed
                              : AppColors.textSecondary),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: onEdit,
                      color: AppColors.textSecondary,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: onDelete,
                      color: AppColors.budgetRed,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

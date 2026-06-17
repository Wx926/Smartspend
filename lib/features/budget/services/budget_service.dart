import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/constants/app_constants.dart';

class BudgetService {
  BudgetService._();
  static final BudgetService instance = BudgetService._();

  final _store = LocalStorageService.instance;

  Future<List<BudgetModel>> getBudgets(int month, int year) async =>
      _store.getBudgets(month, year);

  Future<BudgetModel> upsertBudget(BudgetModel budget) =>
      _store.upsertBudget(budget);

  Future<void> deleteBudget(String budgetId) => _store.deleteBudget(budgetId);

  /// Algorithm 2: Burn Rate Calculation + Budget Forecast
  /// Computes budget status for each category using daily burn rate projection.
  List<BudgetStatus> computeBudgetStatuses({
    required List<BudgetModel> budgets,
    required List<CategoryModel> categories,
    required List<ExpenseModel> expenses,
    required DateTime forMonth,
  }) {
    final now = DateTime.now();
    final daysInMonth =
        DateTime(forMonth.year, forMonth.month + 1, 0).day;
    final daysElapsed =
        (forMonth.year == now.year && forMonth.month == now.month)
            ? now.day
            : daysInMonth;
    final daysRemaining = daysInMonth - daysElapsed;

    final categoryMap = {for (final c in categories) c.id: c};

    return budgets.map((budget) {
      final cat = categoryMap[budget.categoryId];
      final categoryName = cat?.name ?? 'Unknown';
      final categoryIcon = cat?.icon ?? '📦';
      final categoryColorHex = cat?.colorHex ?? '6B7280';

      final spent = expenses
          .where((e) =>
              e.categoryId == budget.categoryId &&
              e.date.month == forMonth.month &&
              e.date.year == forMonth.year)
          .fold(0.0, (sum, e) => sum + e.amount);

      final dailyBurnRate =
          daysElapsed > 0 ? spent / daysElapsed : 0.0;
      final projectedSpending =
          spent + (dailyBurnRate * daysRemaining);
      final percentUsed =
          budget.amount > 0 ? spent / budget.amount : 0.0;

      final AlertSeverity severity;
      if (percentUsed >= AppConstants.redThreshold) {
        severity = AlertSeverity.red;
      } else if (percentUsed >= AppConstants.yellowThreshold) {
        severity = AlertSeverity.yellow;
      } else {
        severity = AlertSeverity.green;
      }

      return BudgetStatus(
        budget: budget,
        categoryName: categoryName,
        categoryIcon: categoryIcon,
        categoryColorHex: categoryColorHex,
        spent: spent,
        dailyBurnRate: dailyBurnRate,
        projectedSpending: projectedSpending,
        percentUsed: percentUsed,
        severity: severity,
      );
    }).toList();
  }
}

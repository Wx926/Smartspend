import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../shared/constants/app_constants.dart';

class BudgetService {
  BudgetService._();
  static final BudgetService instance = BudgetService._();

  final _local = LocalStorageService.instance;
  final _supabase = SupabaseService.instance;

  /// Local-first, same pattern as ExpenseService: read the cache instantly,
  /// only reach for Supabase when that month has never been cached locally
  /// (e.g. first run, or a different device) — so a dropped connection no
  /// longer makes existing budgets disappear.
  Future<List<BudgetModel>> getBudgets(int month, int year) async {
    var budgets = _local.getBudgets(month, year);
    // A guest session has no Supabase user at all — there's nothing to fetch
    // (and _supabase.getBudgets would throw), so an empty local cache for a
    // guest just means "no budgets set," not "go check the cloud."
    if (budgets.isEmpty && _supabase.isLoggedIn) {
      final cloud = await _supabase.getBudgets(month, year);
      if (cloud.isNotEmpty) {
        for (final b in cloud) {
          await _local.upsertBudget(b);
        }
        budgets = _local.getBudgets(month, year);
      }
    }
    return budgets;
  }

  Future<BudgetModel> upsertBudget(BudgetModel budget) async {
    final saved = await _local.upsertBudget(budget);
    _syncUpsert(budget);
    return saved;
  }

  Future<void> _syncUpsert(BudgetModel budget) async {
    try {
      await _supabase.upsertBudget(budget);
    } catch (_) {
      // Offline — the local copy already saved above is the source of truth
      // for the UI; this sync just retries implicitly next successful call.
    }
  }

  Future<void> deleteBudget(String budgetId) async {
    await _local.deleteBudget(budgetId);
    _supabase.deleteBudget(budgetId).catchError((_) {});
  }

  /// Algorithm 2: Burn Rate Calculation + Budget Forecast
  List<BudgetStatus> computeBudgetStatuses({
    required List<BudgetModel> budgets,
    required List<CategoryModel> categories,
    required List<ExpenseModel> expenses,
    required DateTime forMonth,
  }) {
    final now = DateTime.now();
    final daysInMonth = DateTime(forMonth.year, forMonth.month + 1, 0).day;
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
          .where(
            (e) =>
                e.categoryId == budget.categoryId &&
                e.date.month == forMonth.month &&
                e.date.year == forMonth.year,
          )
          .fold(0.0, (sum, e) => sum + e.amount);

      final dailyBurnRate = daysElapsed > 0 ? spent / daysElapsed : 0.0;
      final projectedSpending = spent + (dailyBurnRate * daysRemaining);
      final percentUsed = budget.amount > 0 ? spent / budget.amount : 0.0;
      // Algorithm 2 Step 6: severity reflects the projected month-end total,
      // not just what's been spent so far — a slow starter who's on pace to
      // blow the budget by day 30 should be flagged before they've actually
      // overspent.
      final projectedPercentUsed = budget.amount > 0
          ? projectedSpending / budget.amount
          : 0.0;

      final AlertSeverity severity;
      if (projectedPercentUsed >= AppConstants.redThreshold) {
        severity = AlertSeverity.red;
      } else if (projectedPercentUsed >= AppConstants.yellowThreshold) {
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

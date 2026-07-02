import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';

class ExpenseService {
  ExpenseService._();
  static final ExpenseService instance = ExpenseService._();

  final _store = LocalStorageService.instance;

  Future<List<ExpenseModel>> getExpenses({int? month, int? year}) async {
    final all = _store.getExpenses();
    if (month == null && year == null) return all;
    return all
        .where((e) =>
            (month == null || e.date.month == month) &&
            (year == null || e.date.year == year))
        .toList();
  }

  Future<ExpenseModel> addExpense(ExpenseModel expense) =>
      _store.insertExpense(expense);

  Future<ExpenseModel> updateExpense(ExpenseModel expense) =>
      _store.updateExpense(expense);

  Future<void> deleteExpense(String id) => _store.deleteExpense(id);

  /// Returns a map of categoryId → total amount for the given month/year.
  /// Excludes savings_transfer records (goal contributions are not budget spend).
  Map<String, double> getCategoryTotals(
      List<ExpenseModel> expenses, int month, int year) {
    final filtered = expenses
        .where((e) =>
            e.date.month == month &&
            e.date.year == year &&
            e.categoryId != 'savings_transfer')
        .toList();
    final totals = <String, double>{};
    for (final e in filtered) {
      totals[e.categoryId] = (totals[e.categoryId] ?? 0) + e.amount;
    }
    return totals;
  }
}

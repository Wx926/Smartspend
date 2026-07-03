import '../../../shared/models/expense_model.dart';
import '../../../shared/services/supabase_service.dart';

class ExpenseService {
  ExpenseService._();
  static final ExpenseService instance = ExpenseService._();

  final _supabase = SupabaseService.instance;

  Future<List<ExpenseModel>> getExpenses({int? month, int? year}) async {
    return _supabase.getExpenses(month: month, year: year);
  }

  Future<ExpenseModel> addExpense(ExpenseModel expense) =>
      _supabase.insertExpense(expense);

  Future<ExpenseModel> updateExpense(ExpenseModel expense) =>
      _supabase.updateExpense(expense);

  Future<void> deleteExpense(String id) => _supabase.deleteExpense(id);

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

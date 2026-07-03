import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';

class ExpenseService {
  ExpenseService._();
  static final ExpenseService instance = ExpenseService._();

  final _local = LocalStorageService.instance;
  final _supabase = SupabaseService.instance;

  Future<List<ExpenseModel>> getExpenses({int? month, int? year}) async {
    final all = _local.getExpenses();
    if (month != null && year != null) {
      return all.where((e) => e.date.month == month && e.date.year == year).toList();
    }
    return all;
  }

  Future<ExpenseModel> addExpense(ExpenseModel expense) async {
    final saved = await _local.insertExpense(expense);
    _syncInsert(expense);
    return saved;
  }

  Future<ExpenseModel> updateExpense(ExpenseModel expense) async {
    final saved = await _local.updateExpense(expense);
    _syncUpdate(expense);
    return saved;
  }

  Future<void> _syncInsert(ExpenseModel e) async {
    try { await _supabase.insertExpense(e); } catch (_) {}
  }

  Future<void> _syncUpdate(ExpenseModel e) async {
    try { await _supabase.updateExpense(e); } catch (_) {}
  }

  Future<void> deleteExpense(String id) async {
    await _local.deleteExpense(id);
    _supabase.deleteExpense(id).catchError((_) {});
  }

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

import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';

class ExpenseService {
  ExpenseService._();
  static final ExpenseService instance = ExpenseService._();

  final _local = LocalStorageService.instance;
  final _supabase = SupabaseService.instance;

  Future<List<ExpenseModel>> getExpenses({int? month, int? year}) async {
    var all = _local.getExpenses();
    // Local storage is normally the source of truth, but it's wiped by an
    // uninstall/reinstall or a fresh device — while every write is also
    // best-effort synced to Supabase. If local is empty, treat that as a
    // possible loss and hydrate the cache back from the cloud once.
    if (all.isEmpty) {
      try {
        final cloud = await _supabase.getExpenses();
        if (cloud.isNotEmpty) {
          await _local.replaceExpenses(cloud);
          all = _local.getExpenses();
        }
      } catch (_) {
        // Offline, logged out, or nothing to recover — fall through with
        // whatever local has (still empty).
      }
    }
    if (month != null && year != null) {
      return all
          .where((e) => e.date.month == month && e.date.year == year)
          .toList();
    }
    return all;
  }

  Future<ExpenseModel> addExpense(ExpenseModel expense) async {
    final saved = await _local.insertExpense(expense);
    _syncInsert(expense);
    return saved;
  }

  /// Same as [addExpense], but awaits the Supabase insert instead of firing
  /// it in the background — for callers (e.g. attaching a warranty) that
  /// need a guarantee the row actually exists server-side before inserting
  /// something with a foreign key pointing at it. Unlike [_syncInsert], a
  /// Supabase failure here is NOT swallowed, since the caller can't safely
  /// proceed to a dependent insert if this one didn't really happen.
  Future<ExpenseModel> addExpenseSynced(ExpenseModel expense) async {
    final saved = await _local.insertExpense(expense);
    await _supabase.insertExpense(expense);
    return saved;
  }

  Future<ExpenseModel> updateExpense(ExpenseModel expense) async {
    final saved = await _local.updateExpense(expense);
    _syncUpdate(expense);
    return saved;
  }

  Future<void> _syncInsert(ExpenseModel e) async {
    try {
      await _supabase.insertExpense(e);
    } catch (_) {}
  }

  Future<void> _syncUpdate(ExpenseModel e) async {
    try {
      await _supabase.updateExpense(e);
    } catch (_) {}
  }

  Future<void> deleteExpense(String id) async {
    await _local.deleteExpense(id);
    _supabase.deleteExpense(id).catchError((_) {});
  }

  Map<String, double> getCategoryTotals(
    List<ExpenseModel> expenses,
    int month,
    int year,
  ) {
    final filtered = expenses
        .where(
          (e) =>
              e.date.month == month &&
              e.date.year == year &&
              e.categoryId != 'savings_transfer' &&
              e.categoryId != 'wallet_transfer',
        )
        .toList();
    final totals = <String, double>{};
    for (final e in filtered) {
      totals[e.categoryId] = (totals[e.categoryId] ?? 0) + e.amount;
    }
    return totals;
  }
}

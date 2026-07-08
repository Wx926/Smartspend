import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/expense_model.dart';
import '../services/expense_service.dart';

class ExpenseProvider extends ChangeNotifier {
  final _service = ExpenseService.instance;
  final _uuid = const Uuid();

  List<ExpenseModel> _expenses = [];
  bool _isLoading = false;
  String? _error;

  List<ExpenseModel> get expenses => _expenses;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// All records (income + expense) for the given month — used for history display.
  List<ExpenseModel> forMonth(int month, int year) => _expenses
      .where((e) => e.date.month == month && e.date.year == year)
      .toList();

  /// Only expense records excluding savings_transfer — used for budget calculations.
  List<ExpenseModel> expensesForMonth(int month, int year) => _expenses
      .where((e) =>
          e.date.month == month &&
          e.date.year == year &&
          e.type == 'expense' &&
          e.categoryId != 'savings_transfer')
      .toList();

  /// Only income records — used for income display.
  List<ExpenseModel> incomeForMonth(int month, int year) => _expenses
      .where((e) =>
          e.date.month == month &&
          e.date.year == year &&
          e.type == 'income')
      .toList();

  /// Balance for a specific wallet (income - expense for that walletId).
  /// Excludes records with walletId='savings_goal' (goal-funded purchases).
  double walletBalance(String walletId) {
    final relevant = _expenses.where((r) => r.walletId == walletId);
    final income =
        relevant.where((r) => r.type == 'income').fold(0.0, (s, r) => s + r.amount);
    final expense =
        relevant.where((r) => r.type == 'expense').fold(0.0, (s, r) => s + r.amount);
    return income - expense;
  }

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _expenses = await _service.getExpenses();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<ExpenseModel> addExpense({
    required String userId,
    required String categoryId,
    required double amount,
    required String description,
    required DateTime date,
    String? locationId,
    String type = 'expense',
    String walletId = 'default_account',
    String? savingsGoalId,
    String source = 'manual',
    String? merchantName,
    String? batchId,
    String? receiptImageUrl,
  }) async {
    final expense = ExpenseModel(
      id: _uuid.v4(),
      userId: userId,
      categoryId: categoryId,
      amount: amount,
      description: description,
      date: date,
      locationId: locationId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      type: type,
      walletId: walletId,
      savingsGoalId: savingsGoalId,
      source: source,
      merchantName: merchantName,
      batchId: batchId,
      receiptImageUrl: receiptImageUrl,
    );
    // Optimistic: insert locally and return immediately — don't block on network
    _expenses.insert(0, expense);
    notifyListeners();
    // Sync to Supabase in background
    _service.addExpense(expense).then((saved) {
      final idx = _expenses.indexWhere((e) => e.id == expense.id);
      if (idx != -1) _expenses[idx] = saved;
      notifyListeners();
    }).catchError((_) {
      _expenses.removeWhere((e) => e.id == expense.id);
      notifyListeners();
    });
    return expense;
  }

  Future<void> updateExpense(ExpenseModel updated) async {
    final idx = _expenses.indexWhere((e) => e.id == updated.id);
    final previous = idx != -1 ? _expenses[idx] : null;
    if (idx != -1) _expenses[idx] = updated;
    notifyListeners();
    _service.updateExpense(updated).then((saved) {
      final i = _expenses.indexWhere((e) => e.id == saved.id);
      if (i != -1) _expenses[i] = saved;
      notifyListeners();
    }).catchError((_) {
      if (previous != null && idx != -1) _expenses[idx] = previous;
      notifyListeners();
    });
  }

  Future<void> deleteExpense(String id) async {
    await _service.deleteExpense(id);
    _expenses.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  Map<String, double> categoryTotals(int month, int year) =>
      _service.getCategoryTotals(_expenses, month, year);
}

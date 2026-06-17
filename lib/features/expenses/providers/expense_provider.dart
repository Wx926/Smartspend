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

  List<ExpenseModel> forMonth(int month, int year) => _expenses
      .where((e) => e.date.month == month && e.date.year == year)
      .toList();

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

  Future<void> addExpense({
    required String userId,
    required String categoryId,
    required double amount,
    required String description,
    required DateTime date,
    String? locationId,
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
    );
    final saved = await _service.addExpense(expense);
    _expenses.insert(0, saved);
    notifyListeners();
  }

  Future<void> updateExpense(ExpenseModel updated) async {
    final saved = await _service.updateExpense(updated);
    final idx = _expenses.indexWhere((e) => e.id == saved.id);
    if (idx != -1) _expenses[idx] = saved;
    notifyListeners();
  }

  Future<void> deleteExpense(String id) async {
    await _service.deleteExpense(id);
    _expenses.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  Map<String, double> categoryTotals(int month, int year) =>
      _service.getCategoryTotals(_expenses, month, year);
}

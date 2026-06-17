import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../services/budget_service.dart';

class BudgetProvider extends ChangeNotifier {
  final _service = BudgetService.instance;
  final _uuid = const Uuid();

  List<BudgetModel> _budgets = [];
  List<CategoryModel> _categories = [];
  List<BudgetStatus> _statuses = [];
  bool _isLoading = false;
  String? _error;
  late DateTime _selectedMonth;

  BudgetProvider() {
    final now = DateTime.now();
    _selectedMonth = DateTime(now.year, now.month);
    // Categories come from local constants, always available immediately
    _categories = LocalStorageService.instance.getCategories();
  }

  List<BudgetModel> get budgets => _budgets;
  List<CategoryModel> get categories => _categories;
  List<BudgetStatus> get statuses => _statuses;
  bool get isLoading => _isLoading;
  String? get error => _error;
  DateTime get selectedMonth => _selectedMonth;

  double get totalBudget =>
      _budgets.fold(0.0, (sum, b) => sum + b.amount);

  double get totalSpent =>
      _statuses.fold(0.0, (sum, s) => sum + s.spent);

  void setMonth(DateTime month) {
    _selectedMonth = month;
    notifyListeners();
  }

  Future<void> load(List<ExpenseModel> expenses) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _budgets = await _service.getBudgets(
          _selectedMonth.month, _selectedMonth.year);
      _recalculate(expenses);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void recalculate(List<ExpenseModel> expenses) {
    _recalculate(expenses);
    notifyListeners();
  }

  void _recalculate(List<ExpenseModel> expenses) {
    _statuses = _service.computeBudgetStatuses(
      budgets: _budgets,
      categories: _categories,
      expenses: expenses,
      forMonth: _selectedMonth,
    );
  }

  Future<void> setBudget({
    required String userId,
    required String categoryId,
    required double amount,
  }) async {
    final existing = _budgets
        .where((b) =>
            b.categoryId == categoryId &&
            b.month == _selectedMonth.month &&
            b.year == _selectedMonth.year)
        .firstOrNull;

    final budget = BudgetModel(
      id: existing?.id ?? _uuid.v4(),
      userId: userId,
      categoryId: categoryId,
      amount: amount,
      month: _selectedMonth.month,
      year: _selectedMonth.year,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final saved = await _service.upsertBudget(budget);

    if (existing != null) {
      final idx = _budgets.indexWhere((b) => b.id == existing.id);
      _budgets[idx] = saved;
    } else {
      _budgets.add(saved);
    }
    notifyListeners();
  }

  Future<void> deleteBudget(String budgetId) async {
    await _service.deleteBudget(budgetId);
    _budgets.removeWhere((b) => b.id == budgetId);
    notifyListeners();
  }
}

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

  List<CategoryModel> _incomeCategories = [];

  BudgetProvider() {
    final now = DateTime.now();
    _selectedMonth = DateTime(now.year, now.month);
    _categories = LocalStorageService.instance.getCategories();
    _incomeCategories = LocalStorageService.instance.getCategories(type: 'income');
  }

  List<BudgetModel> get budgets => _budgets;
  List<CategoryModel> get categories => _categories;
  List<CategoryModel> get incomeCategories => _incomeCategories;
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

  // ── Category management ────────────────────────────────────────────────────
  void _reloadCategories() {
    _categories = LocalStorageService.instance.getCategories();
    _incomeCategories = LocalStorageService.instance.getCategories(type: 'income');
  }

  Future<void> addCategory(CategoryModel cat) async {
    await LocalStorageService.instance.saveCategory(cat);
    _reloadCategories();
    notifyListeners();
  }

  Future<void> removeCategory(CategoryModel cat) async {
    // Delete any budget entry set for this category
    final budgetsToDelete = _budgets.where((b) => b.categoryId == cat.id).toList();
    for (final b in budgetsToDelete) {
      await _service.deleteBudget(b.id);
    }
    _budgets.removeWhere((b) => b.categoryId == cat.id);

    // Reassign existing records to the fallback category for that type.
    // expense → "others", income → "bonus"
    final fallbackId = cat.type == 'income' ? 'bonus' : 'others';
    await LocalStorageService.instance.reassignCategory(cat.id, fallbackId);

    await LocalStorageService.instance.deleteCategory(cat.id);
    _reloadCategories();
    notifyListeners();
  }
}

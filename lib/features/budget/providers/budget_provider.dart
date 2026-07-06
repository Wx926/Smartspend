import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
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

    // Optimistic update: apply locally immediately
    if (existing != null) {
      final idx = _budgets.indexWhere((b) => b.id == existing.id);
      if (idx != -1) _budgets[idx] = budget;
    } else {
      _budgets.add(budget);
    }
    notifyListeners();

    try {
      final saved = await _service.upsertBudget(budget);
      final i = _budgets.indexWhere((b) => b.id == budget.id);
      if (i != -1) _budgets[i] = saved;
      notifyListeners();
    } catch (e) {
      if (existing != null) {
        final i = _budgets.indexWhere((b) => b.id == budget.id);
        if (i != -1) _budgets[i] = existing;
      } else {
        _budgets.removeWhere((b) => b.id == budget.id);
      }
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteBudget(String budgetId) async {
    await _service.deleteBudget(budgetId);
    _budgets.removeWhere((b) => b.id == budgetId);
    notifyListeners();
  }

  /// Auto-copies previous month's budgets into the current month if none exist.
  /// Returns true if budgets were copied, false otherwise.
  Future<bool> autoCopyFromPreviousMonth(String userId) async {
    final now = DateTime.now();
    if (_selectedMonth.month != now.month || _selectedMonth.year != now.year) {
      return false;
    }
    try {
      final prevMonth = DateTime(now.year, now.month - 1);
      final results = await Future.wait([
        _service.getBudgets(now.month, now.year),
        _service.getBudgets(prevMonth.month, prevMonth.year),
      ]).timeout(const Duration(seconds: 10));

      final existing = results[0];
      final prev = results[1];
      if (existing.isNotEmpty || prev.isEmpty) return false;

      await Future.wait(prev.map((b) => _service.upsertBudget(BudgetModel(
            id: _uuid.v4(),
            userId: userId,
            categoryId: b.categoryId,
            amount: b.amount,
            month: now.month,
            year: now.year,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ))));
      return true;
    } catch (_) {
      return false;
    }
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
    await SupabaseService.instance.reassignCategoryExpenses(cat.id, fallbackId);

    await LocalStorageService.instance.deleteCategory(cat.id);
    _reloadCategories();
    notifyListeners();
  }
}

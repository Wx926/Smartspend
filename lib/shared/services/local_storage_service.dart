import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants/app_constants.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/expense_model.dart';
import '../models/location_model.dart';
import '../models/alert_log_model.dart';

/// Local on-device storage. No internet or login required.
/// Data persists across app restarts via SharedPreferences.
class LocalStorageService {
  LocalStorageService._();
  static final LocalStorageService instance = LocalStorageService._();

  static const _keyBudgets = 'ss_budgets';
  static const _keyExpenses = 'ss_expenses';
  static const _keyLocations = 'ss_locations';
  static const _keyAlerts = 'ss_alerts';
  static const _keyDeviceId = 'ss_device_id';

  SharedPreferences? _prefs;
  final _uuid = const Uuid();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Generate a stable local user ID on first launch
    if (_prefs!.getString(_keyDeviceId) == null) {
      await _prefs!.setString(_keyDeviceId, _uuid.v4());
    }
  }

  String get localUserId => _prefs?.getString(_keyDeviceId) ?? 'local_user';

  // ── Categories (always from constants, no storage needed) ──────────────────
  List<CategoryModel> getCategories({String type = 'expense'}) {
    return AppConstants.defaultCategories
        .where((c) => c['type'] == type)
        .map((c) => CategoryModel(
              id: c['name']!.toLowerCase().replaceAll(' ', '_').replaceAll('&', 'and'),
              name: c['name']!,
              icon: c['icon']!,
              colorHex: c['color']!,
              type: c['type']!,
            ))
        .toList();
  }

  // ── Budgets ────────────────────────────────────────────────────────────────
  List<BudgetModel> _loadBudgets() {
    final raw = _prefs?.getString(_keyBudgets);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => BudgetModel.fromJson(e)).toList();
  }

  Future<void> _saveBudgets(List<BudgetModel> budgets) async {
    await _prefs?.setString(
        _keyBudgets, jsonEncode(budgets.map((b) => b.toJson()).toList()));
  }

  List<BudgetModel> getBudgets(int month, int year) {
    return _loadBudgets()
        .where((b) => b.month == month && b.year == year)
        .toList();
  }

  Future<BudgetModel> upsertBudget(BudgetModel budget) async {
    final all = _loadBudgets();
    final idx = all.indexWhere((b) =>
        b.userId == budget.userId &&
        b.categoryId == budget.categoryId &&
        b.month == budget.month &&
        b.year == budget.year);
    if (idx >= 0) {
      all[idx] = budget;
    } else {
      all.add(budget);
    }
    await _saveBudgets(all);
    return budget;
  }

  Future<void> deleteBudget(String id) async {
    final all = _loadBudgets()..removeWhere((b) => b.id == id);
    await _saveBudgets(all);
  }

  // ── Expenses ───────────────────────────────────────────────────────────────
  List<ExpenseModel> _loadExpenses() {
    final raw = _prefs?.getString(_keyExpenses);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => ExpenseModel.fromJson(e)).toList();
  }

  Future<void> _saveExpenses(List<ExpenseModel> expenses) async {
    await _prefs?.setString(
        _keyExpenses, jsonEncode(expenses.map((e) => e.toJson()).toList()));
  }

  List<ExpenseModel> getExpenses() {
    final expenses = _loadExpenses();
    expenses.sort((a, b) => b.date.compareTo(a.date));
    return expenses;
  }

  Future<ExpenseModel> insertExpense(ExpenseModel expense) async {
    final all = _loadExpenses();
    all.add(expense);
    await _saveExpenses(all);
    return expense;
  }

  Future<ExpenseModel> updateExpense(ExpenseModel expense) async {
    final all = _loadExpenses();
    final idx = all.indexWhere((e) => e.id == expense.id);
    if (idx >= 0) all[idx] = expense;
    await _saveExpenses(all);
    return expense;
  }

  Future<void> deleteExpense(String id) async {
    final all = _loadExpenses()..removeWhere((e) => e.id == id);
    await _saveExpenses(all);
  }

  // ── Locations ──────────────────────────────────────────────────────────────
  List<LocationModel> _loadLocations() {
    final raw = _prefs?.getString(_keyLocations);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => LocationModel.fromJson(e)).toList();
  }

  Future<void> _saveLocations(List<LocationModel> locs) async {
    await _prefs?.setString(
        _keyLocations, jsonEncode(locs.map((l) => l.toJson()).toList()));
  }

  List<LocationModel> getLocations() => _loadLocations();

  Future<LocationModel> upsertLocation(LocationModel loc) async {
    final all = _loadLocations();
    final idx = all.indexWhere((l) => l.id == loc.id);
    if (idx >= 0) {
      all[idx] = loc;
    } else {
      all.add(loc);
    }
    await _saveLocations(all);
    return loc;
  }

  Future<void> incrementVisitCount(String locationId) async {
    final all = _loadLocations();
    final idx = all.indexWhere((l) => l.id == locationId);
    if (idx >= 0) {
      final loc = all[idx];
      all[idx] = LocationModel(
        id: loc.id,
        userId: loc.userId,
        name: loc.name,
        address: loc.address,
        latitude: loc.latitude,
        longitude: loc.longitude,
        categoryHint: loc.categoryHint,
        visitCount: loc.visitCount + 1,
        isRoutine: loc.visitCount + 1 >= 5,
        createdAt: loc.createdAt,
      );
    }
    await _saveLocations(all);
  }

  // ── Alerts ─────────────────────────────────────────────────────────────────
  List<AlertLogModel> _loadAlerts() {
    final raw = _prefs?.getString(_keyAlerts);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => AlertLogModel.fromJson(e)).toList();
  }

  Future<void> _saveAlerts(List<AlertLogModel> alerts) async {
    await _prefs?.setString(
        _keyAlerts, jsonEncode(alerts.map((a) => a.toJson()).toList()));
  }

  List<AlertLogModel> getAlerts() {
    final alerts = _loadAlerts();
    alerts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return alerts.take(50).toList();
  }

  AlertLogModel? getLastAlertForCategory(String categoryId) {
    final alerts = _loadAlerts()
        .where((a) => a.categoryId == categoryId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return alerts.isEmpty ? null : alerts.first;
  }

  Future<AlertLogModel> insertAlert(AlertLogModel alert) async {
    final all = _loadAlerts();
    all.add(alert);
    await _saveAlerts(all);
    return alert;
  }

  Future<void> markAlertRead(String id) async {
    final all = _loadAlerts();
    final idx = all.indexWhere((a) => a.id == id);
    if (idx >= 0) all[idx] = all[idx].markRead();
    await _saveAlerts(all);
  }

  Future<void> markAllAlertsRead() async {
    final all = _loadAlerts().map((a) => a.markRead()).toList();
    await _saveAlerts(all);
  }

  // ── Location history (in-memory only for session) ──────────────────────────
  final List<LocationHistoryModel> _historyBuffer = [];

  void bufferHistory(LocationHistoryModel h) => _historyBuffer.add(h);

  void closeHistory(String id, DateTime leftAt, int dwell) {
    final idx = _historyBuffer.indexWhere((h) => h.id == id);
    if (idx >= 0) _historyBuffer.removeAt(idx);
  }
}

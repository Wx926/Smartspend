import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/expense_model.dart';
import '../models/location_model.dart';
import '../models/alert_log_model.dart';
import '../models/ai_insight_model.dart';

/// Data Access Object — single entry point for all Supabase queries.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;
  String get _uid => _client.auth.currentUser!.id;

  // ── Categories ────────────────────────────────────────────────
  Future<List<CategoryModel>> getCategories({String type = 'expense'}) async {
    final data = await _client
        .from('categories')
        .select()
        .eq('type', type)
        .order('name');
    return (data as List).map((e) => CategoryModel.fromJson(e)).toList();
  }

  // ── Budgets ───────────────────────────────────────────────────
  Future<List<BudgetModel>> getBudgets(int month, int year) async {
    final data = await _client
        .from('budgets')
        .select()
        .eq('user_id', _uid)
        .eq('month', month)
        .eq('year', year);
    return (data as List).map((e) => BudgetModel.fromJson(e)).toList();
  }

  Future<BudgetModel> upsertBudget(BudgetModel budget) async {
    final data = await _client
        .from('budgets')
        .upsert(budget.toJson(), onConflict: 'user_id,category_id,month,year')
        .select()
        .single();
    return BudgetModel.fromJson(data);
  }

  Future<void> deleteBudget(String budgetId) async {
    await _client.from('budgets').delete().eq('id', budgetId);
  }

  // ── Expenses ──────────────────────────────────────────────────
  Future<List<ExpenseModel>> getExpenses({int? month, int? year}) async {
    var query = _client
        .from('expenses')
        .select()
        .eq('user_id', _uid)
        .order('date', ascending: false);

    final data = await query;
    final expenses =
        (data as List).map((e) => ExpenseModel.fromJson(e)).toList();

    if (month != null && year != null) {
      return expenses
          .where((e) => e.date.month == month && e.date.year == year)
          .toList();
    }
    return expenses;
  }

  Future<ExpenseModel> insertExpense(ExpenseModel expense) async {
    final data = await _client
        .from('expenses')
        .insert(expense.toJson())
        .select()
        .single();
    return ExpenseModel.fromJson(data);
  }

  Future<ExpenseModel> updateExpense(ExpenseModel expense) async {
    final data = await _client
        .from('expenses')
        .update(expense.toJson())
        .eq('id', expense.id)
        .select()
        .single();
    return ExpenseModel.fromJson(data);
  }

  Future<void> deleteExpense(String expenseId) async {
    await _client.from('expenses').delete().eq('id', expenseId);
  }

  // ── Locations ─────────────────────────────────────────────────
  Future<List<LocationModel>> getLocations() async {
    final data = await _client
        .from('locations')
        .select()
        .eq('user_id', _uid)
        .order('visit_count', ascending: false);
    return (data as List).map((e) => LocationModel.fromJson(e)).toList();
  }

  Future<LocationModel> upsertLocation(LocationModel loc) async {
    final data = await _client
        .from('locations')
        .upsert(loc.toJson())
        .select()
        .single();
    return LocationModel.fromJson(data);
  }

  Future<void> incrementVisitCount(String locationId) async {
    await _client.rpc('increment_visit_count', params: {'loc_id': locationId});
  }

  Future<void> insertLocationHistory(LocationHistoryModel h) async {
    await _client.from('user_location_history').insert(h.toJson());
  }

  Future<void> closeLocationHistory(
      String historyId, DateTime leftAt, int dwellMinutes) async {
    await _client.from('user_location_history').update({
      'left_at': leftAt.toIso8601String(),
      'dwell_time_minutes': dwellMinutes,
    }).eq('id', historyId);
  }

  // ── Alert Logs ────────────────────────────────────────────────
  Future<List<AlertLogModel>> getAlerts() async {
    final data = await _client
        .from('alert_logs')
        .select()
        .eq('user_id', _uid)
        .order('created_at', ascending: false)
        .limit(50);
    return (data as List).map((e) => AlertLogModel.fromJson(e)).toList();
  }

  Future<AlertLogModel?> getLastAlertForCategory(String categoryId) async {
    final data = await _client
        .from('alert_logs')
        .select()
        .eq('user_id', _uid)
        .eq('category_id', categoryId)
        .order('created_at', ascending: false)
        .limit(1);
    final list = data as List;
    if (list.isEmpty) return null;
    return AlertLogModel.fromJson(list.first);
  }

  Future<AlertLogModel> insertAlert(AlertLogModel alert) async {
    final data = await _client
        .from('alert_logs')
        .insert(alert.toJson())
        .select()
        .single();
    return AlertLogModel.fromJson(data);
  }

  Future<void> markAlertRead(String alertId) async {
    await _client
        .from('alert_logs')
        .update({'is_read': true})
        .eq('id', alertId);
  }

  Future<void> markAllAlertsRead() async {
    await _client
        .from('alert_logs')
        .update({'is_read': true})
        .eq('user_id', _uid)
        .eq('is_read', false);
  }

  // ── AI Insights ───────────────────────────────────────────────
  Future<List<AiInsightModel>> getInsights({int? month, int? year}) async {
    var query = _client
        .from('ai_insights')
        .select()
        .eq('user_id', _uid)
        .order('created_at', ascending: false)
        .limit(10);

    final data = await query;
    return (data as List).map((e) => AiInsightModel.fromJson(e)).toList();
  }

  Future<AiInsightModel> insertInsight(AiInsightModel insight) async {
    final data = await _client
        .from('ai_insights')
        .insert(insight.toJson())
        .select()
        .single();
    return AiInsightModel.fromJson(data);
  }
}

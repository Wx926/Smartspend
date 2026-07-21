import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/expense_model.dart';
import '../models/location_model.dart';
import '../models/alert_log_model.dart';
import '../models/ai_insight_model.dart';
import '../models/savings_goal_model.dart';
import '../models/wallet_model.dart';

/// Data Access Object — single entry point for all Supabase queries.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;
  String get _uid => _client.auth.currentUser!.id;

  /// Guest sessions have no Supabase user at all — callers doing local-first
  /// caching with a cloud fallback should check this first instead of
  /// attempting a query that's guaranteed to throw on the `_uid` unwrap.
  bool get isLoggedIn => _client.auth.currentUser != null;

  // ── Categories ────────────────────────────────────────────────
  // Relies entirely on RLS to decide visibility (shared defaults where
  // user_id is null, plus this user's own custom ones) — no explicit
  // user_id filter needed here. Requires the categories table migration
  // (supabase_migration_sync_fix.sql) for custom categories to work; the
  // shared defaults already work without it.
  Future<List<CategoryModel>> getCategories({String type = 'expense'}) async {
    final data = await _client
        .from('categories')
        .select()
        .eq('type', type)
        .order('name');
    return (data as List).map((e) => CategoryModel.fromJson(e)).toList();
  }

  Future<CategoryModel> insertCategory(CategoryModel cat) async {
    final data = await _client
        .from('categories')
        .insert({...cat.toJson(), 'user_id': _uid})
        .select()
        .single();
    return CategoryModel.fromJson(data);
  }

  Future<void> deleteCategory(String id) async {
    await _client.from('categories').delete().eq('id', id);
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
        .order('date', ascending: false)
        .order('created_at', ascending: false);

    final data = await query;
    final expenses = (data as List)
        .map((e) => ExpenseModel.fromJson(e))
        .toList();

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

  /// Uploads a scanned receipt photo/PDF to the "receipts" Storage bucket
  /// (must exist — see supabase_storage_setup.sql) and returns its public
  /// URL, so it can be viewed again later from Receipt History.
  Future<String> uploadReceiptImage(File file, String batchId) async {
    final ext = file.path.split('.').last.toLowerCase();
    final path = '$_uid/$batchId.$ext';
    await _client.storage
        .from('receipts')
        .upload(path, file, fileOptions: const FileOptions(upsert: true));
    return _client.storage.from('receipts').getPublicUrl(path);
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

  Future<void> deleteLocation(String locationId) async {
    await _client.from('locations').delete().eq('id', locationId);
  }

  Future<void> insertLocationHistory(LocationHistoryModel h) async {
    await _client.from('user_location_history').insert(h.toJson());
  }

  Future<void> closeLocationHistory(
    String historyId,
    DateTime leftAt,
    int dwellMinutes,
  ) async {
    await _client
        .from('user_location_history')
        .update({
          'left_at': leftAt.toIso8601String(),
          'dwell_time_minutes': dwellMinutes,
        })
        .eq('id', historyId);
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

  // ── Warranties (FR 4.13, 4.15) ───────────────────────────────
  Future<void> insertWarranty({
    required String expenseId,
    required String vendorName,
    int? durationMonths,
    String? expiryDate,
    required String status,
  }) async {
    await _client.from('warranties').insert({
      'user_id': _uid,
      'expense_id': expenseId,
      'vendor_name': vendorName,
      'duration_months': durationMonths,
      'expiry_date': expiryDate,
      'status': status,
    });
  }

  Future<List<Map<String, dynamic>>> getWarranties() async {
    final data = await _client
        .from('warranties')
        .select()
        .eq('user_id', _uid)
        .order('created_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  // ── Wallets ───────────────────────────────────────────────────
  Future<List<WalletModel>> getWallets() async {
    final data = await _client
        .from('wallets')
        .select()
        .eq('user_id', _uid)
        .order('created_at');
    return (data as List).map((e) => WalletModel.fromJson(e)).toList();
  }

  Future<void> upsertWallet(WalletModel wallet) async {
    await _client.from('wallets').upsert({
      ...wallet.toJson(),
      'user_id': _uid,
      'created_at': DateTime.now().toIso8601String(),
    }, onConflict: 'id');
  }

  Future<void> deleteWallet(String id) async {
    await _client.from('wallets').delete().eq('id', id);
  }

  Future<void> reassignWalletExpenses(
    String fromWalletId,
    String toWalletId,
  ) async {
    await _client
        .from('expenses')
        .update({'wallet_id': toWalletId})
        .eq('user_id', _uid)
        .eq('wallet_id', fromWalletId);
  }

  Future<void> reassignCategoryExpenses(
    String fromCategoryId,
    String toCategoryId,
  ) async {
    await _client
        .from('expenses')
        .update({'category_id': toCategoryId})
        .eq('user_id', _uid)
        .eq('category_id', fromCategoryId);
  }

  // ── Savings Goals ─────────────────────────────────────────────
  Future<List<SavingsGoalModel>> getSavingsGoals() async {
    final data = await _client
        .from('savings_goals')
        .select()
        .eq('user_id', _uid)
        .order('created_at', ascending: false);
    return (data as List).map((e) => SavingsGoalModel.fromJson(e)).toList();
  }

  // Base-only fields that are guaranteed to exist in the original schema
  Map<String, dynamic> _goalBaseJson(
    Map<String, dynamic> json, {
    bool includeUserId = false,
  }) {
    return {
      if (includeUserId) 'user_id': json['user_id'],
      'name': json['name'],
      'target_amount': json['target_amount'],
      'current_amount': json['current_amount'],
      'deadline': json['deadline'],
      'is_completed': json['is_completed'],
    };
  }

  // Extended fields — only exist after running the Supabase migration
  Map<String, dynamic> _goalExtendedJson(Map<String, dynamic> json) {
    return {
      if (json['linked_wallet_label'] != null)
        'linked_wallet_label': json['linked_wallet_label'],
      'auto_transfer_enabled': json['auto_transfer_enabled'] ?? false,
      if (json['auto_transfer_amount'] != null)
        'auto_transfer_amount': json['auto_transfer_amount'],
      if (json['auto_transfer_source_wallet_id'] != null)
        'auto_transfer_source_wallet_id':
            json['auto_transfer_source_wallet_id'],
      if (json['auto_transfer_day_of_month'] != null)
        'auto_transfer_day_of_month': json['auto_transfer_day_of_month'],
      if (json['last_auto_transfer_date'] != null)
        'last_auto_transfer_date': json['last_auto_transfer_date'],
    };
  }

  Future<SavingsGoalModel> insertSavingsGoal(SavingsGoalModel goal) async {
    final json = goal.toJson();
    // Only remove id if empty — preserve pre-generated UUIDs for optimistic inserts
    if (goal.id.isEmpty) json.remove('id');
    final fullJson = {
      if (goal.id.isNotEmpty) 'id': goal.id,
      ..._goalBaseJson(json, includeUserId: true),
      ..._goalExtendedJson(json),
    };
    try {
      final data = await _client
          .from('savings_goals')
          .insert(fullJson)
          .select()
          .single();
      return SavingsGoalModel.fromJson(data);
    } catch (_) {
      // Fallback: use base columns only (extended columns not yet in schema)
      final baseJson = {
        if (goal.id.isNotEmpty) 'id': goal.id,
        ..._goalBaseJson(json, includeUserId: true),
      };
      final data = await _client
          .from('savings_goals')
          .insert(baseJson)
          .select()
          .single();
      return SavingsGoalModel.fromJson(data);
    }
  }

  Future<SavingsGoalModel> updateSavingsGoal(SavingsGoalModel goal) async {
    final json = goal.toJson();
    final fullJson = {..._goalBaseJson(json), ..._goalExtendedJson(json)};
    try {
      final data = await _client
          .from('savings_goals')
          .update(fullJson)
          .eq('id', goal.id)
          .select()
          .single();
      return SavingsGoalModel.fromJson(data);
    } catch (_) {
      // Fallback: update base columns only
      final data = await _client
          .from('savings_goals')
          .update(_goalBaseJson(json))
          .eq('id', goal.id)
          .select()
          .single();
      return SavingsGoalModel.fromJson(data);
    }
  }

  Future<void> deleteSavingsGoal(String goalId) async {
    await _client.from('savings_goals').delete().eq('id', goalId);
  }
}

import 'package:flutter/material.dart';
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../../expenses/providers/expense_provider.dart';

class WalletProvider extends ChangeNotifier {
  static const _defaultWallet = WalletModel(
    id: 'default_account',
    name: 'Default Account',
    icon: '💳',
    colorHex: '3B82F6',
    isDefault: true,
  );

  final _store = LocalStorageService.instance;

  List<WalletModel> _wallets = [_defaultWallet];
  bool _hidden = false;
  bool _loaded = false;

  List<WalletModel> get wallets => _wallets;
  bool get hidden => _hidden;

  /// The wallet the user picked as their "always use" wallet, falling back
  /// to the system default account if none was picked (or it got deleted).
  String? get preferredWalletId => _store.preferredWalletId;

  WalletModel get defaultWallet {
    final preferredId = _store.preferredWalletId;
    if (preferredId != null) {
      final preferred = _wallets.where((w) => w.id == preferredId).firstOrNull;
      if (preferred != null) return preferred;
    }
    return _wallets.firstWhere(
      (w) => w.id == 'default_account',
      orElse: () => _wallets.first,
    );
  }

  Future<void> setPreferredWallet(String walletId) async {
    await _store.setPreferredWalletId(walletId);
    notifyListeners();
  }

  // Called from app.dart on startup — kept for backward compat
  void init() {}

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final cloud = await SupabaseService.instance.getWallets();
      _wallets = [_defaultWallet, ...cloud];
      _loaded = true;
    } catch (_) {
      _wallets = [_defaultWallet];
    }
    notifyListeners();
  }

  void toggleHidden() {
    _hidden = !_hidden;
    notifyListeners();
  }

  /// Balance for a single wallet: income − expense.
  double walletBalance(String walletId, List<ExpenseModel> records) {
    final relevant = records.where((r) => r.walletId == walletId);
    final income = relevant
        .where((r) => r.type == 'income')
        .fold(0.0, (s, r) => s + r.amount);
    final expense = relevant
        .where((r) => r.type == 'expense')
        .fold(0.0, (s, r) => s + r.amount);
    return income - expense;
  }

  /// Total income across ALL wallets. Excludes internal transfers —
  /// a transfer between the user's own wallets/goals/loans isn't new money earned.
  double totalAsset(List<ExpenseModel> records) => records
      .where(
        (r) =>
            r.type == 'income' &&
            !AppConstants.internalCategoryIds.contains(r.categoryId),
      )
      .fold(0.0, (s, r) => s + r.amount);

  /// Total expenses across ALL wallets.
  /// Excludes savings_goal-sourced purchases (already counted when transferred to goal)
  /// and internal transfers (not real spending).
  double totalDebt(List<ExpenseModel> records) => records
      .where(
        (r) =>
            r.type == 'expense' &&
            r.walletId != 'savings_goal' &&
            !AppConstants.internalCategoryIds.contains(r.categoryId),
      )
      .fold(0.0, (s, r) => s + r.amount);

  /// Net asset = total income − total expenses.
  double netAsset(List<ExpenseModel> records) =>
      totalAsset(records) - totalDebt(records);

  Future<void> addWallet(WalletModel wallet) async {
    // Optimistic: show wallet immediately, sync to Supabase in background
    _wallets.add(wallet);
    notifyListeners();
    SupabaseService.instance.upsertWallet(wallet).catchError((_) {
      _wallets.removeWhere((w) => w.id == wallet.id);
      notifyListeners();
    });
  }

  Future<void> deleteWallet(String id) async {
    await SupabaseService.instance.reassignWalletExpenses(
      id,
      'default_account',
    );
    await SupabaseService.instance.deleteWallet(id);
    await load(force: true);
  }

  /// Moves [amount] from [fromWalletId] to [toWalletId] by recording a linked
  /// pair of transactions (an outflow on the source wallet, an inflow on the
  /// destination), tagged with categoryId 'wallet_transfer' so they're
  /// excluded from category/budget totals — same pattern as savings_transfer.
  Future<void> transfer({
    required String userId,
    required String fromWalletId,
    required String toWalletId,
    required double amount,
    required ExpenseProvider expenseProvider,
    String? note,
  }) async {
    if (fromWalletId == toWalletId) {
      throw Exception('Choose two different wallets');
    }
    if (amount <= 0) {
      throw Exception('Enter a valid amount');
    }
    final fromName =
        _wallets.where((w) => w.id == fromWalletId).firstOrNull?.name ??
        'Wallet';
    final toName =
        _wallets.where((w) => w.id == toWalletId).firstOrNull?.name ?? 'Wallet';
    final batchId = 'transfer_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    await expenseProvider.addExpense(
      userId: userId,
      categoryId: 'wallet_transfer',
      amount: amount,
      description: (note != null && note.isNotEmpty)
          ? note
          : 'Transfer → $toName',
      date: now,
      type: 'expense',
      walletId: fromWalletId,
      batchId: batchId,
    );
    await expenseProvider.addExpense(
      userId: userId,
      categoryId: 'wallet_transfer',
      amount: amount,
      description: (note != null && note.isNotEmpty)
          ? note
          : 'Transfer ← $fromName',
      date: now,
      type: 'income',
      walletId: toWalletId,
      batchId: batchId,
    );
  }
}

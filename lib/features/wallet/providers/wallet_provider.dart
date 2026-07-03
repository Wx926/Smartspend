import 'package:flutter/material.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/services/supabase_service.dart';

class WalletProvider extends ChangeNotifier {
  static const _defaultWallet = WalletModel(
    id: 'default_account',
    name: 'Default Account',
    icon: '💳',
    colorHex: '3B82F6',
    isDefault: true,
  );

  List<WalletModel> _wallets = [_defaultWallet];
  bool _hidden = false;
  bool _loaded = false;

  List<WalletModel> get wallets => _wallets;
  bool get hidden => _hidden;

  WalletModel get defaultWallet =>
      _wallets.firstWhere((w) => w.id == 'default_account',
          orElse: () => _wallets.first);

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
    final income =
        relevant.where((r) => r.type == 'income').fold(0.0, (s, r) => s + r.amount);
    final expense =
        relevant.where((r) => r.type == 'expense').fold(0.0, (s, r) => s + r.amount);
    return income - expense;
  }

  /// Total income across ALL wallets.
  double totalAsset(List<ExpenseModel> records) =>
      records.where((r) => r.type == 'income').fold(0.0, (s, r) => s + r.amount);

  /// Total expenses across ALL wallets.
  /// Excludes savings_goal-sourced purchases (already counted when transferred to goal).
  double totalDebt(List<ExpenseModel> records) =>
      records
          .where((r) => r.type == 'expense' && r.walletId != 'savings_goal')
          .fold(0.0, (s, r) => s + r.amount);

  /// Net asset = total income − total expenses.
  double netAsset(List<ExpenseModel> records) =>
      totalAsset(records) - totalDebt(records);

  Future<void> addWallet(WalletModel wallet) async {
    await SupabaseService.instance.upsertWallet(wallet);
    await load(force: true);
  }

  Future<void> deleteWallet(String id) async {
    await SupabaseService.instance.reassignWalletExpenses(id, 'default_account');
    await SupabaseService.instance.deleteWallet(id);
    await load(force: true);
  }
}

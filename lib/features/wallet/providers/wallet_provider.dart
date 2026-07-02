import 'package:flutter/material.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/services/local_storage_service.dart';

class WalletProvider extends ChangeNotifier {
  List<WalletModel> _wallets = [];
  bool _hidden = false;

  List<WalletModel> get wallets => _wallets;
  bool get hidden => _hidden;

  WalletModel get defaultWallet =>
      _wallets.firstWhere((w) => w.id == 'default_account',
          orElse: () => _wallets.first);

  void init() {
    _wallets = LocalStorageService.instance.getWallets();
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
    await LocalStorageService.instance.saveWallet(wallet);
    _wallets = LocalStorageService.instance.getWallets();
    notifyListeners();
  }

  Future<void> deleteWallet(String id) async {
    // Move all records from this wallet to the default account.
    await LocalStorageService.instance.reassignWallet(id, 'default_account');
    await LocalStorageService.instance.deleteWallet(id);
    _wallets = LocalStorageService.instance.getWallets();
    notifyListeners();
  }
}

import 'package:flutter/material.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/services/supabase_service.dart';
import '../../expenses/providers/expense_provider.dart';
import '../../wallet/providers/wallet_provider.dart';

class SavingsGoalProvider extends ChangeNotifier {
  final _db = SupabaseService.instance;

  List<SavingsGoalModel> _goals = [];
  bool _isLoading = false;

  List<SavingsGoalModel> get goals => _goals;
  bool get isLoading => _isLoading;

  double get totalSaved =>
      _goals.fold(0, (sum, g) => sum + g.currentAmount);

  double get totalTarget =>
      _goals.fold(0, (sum, g) => sum + g.targetAmount);

  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    try {
      _goals = await _db.getSavingsGoals();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadIfNeeded() async {
    if (_goals.isEmpty && !_isLoading) await load();
  }

  Future<void> add(SavingsGoalModel goal) async {
    final created = await _db.insertSavingsGoal(goal);
    _goals.insert(0, created);
    notifyListeners();
  }

  Future<void> update(SavingsGoalModel goal) async {
    final updated = await _db.updateSavingsGoal(goal);
    final i = _goals.indexWhere((g) => g.id == goal.id);
    if (i != -1) _goals[i] = updated;
    notifyListeners();
  }

  Future<void> delete(String id) async {
    await _db.deleteSavingsGoal(id);
    _goals.removeWhere((g) => g.id == id);
    notifyListeners();
  }

  /// Transfers [amount] from [sourceWalletId] into [goal].
  /// Creates an expense record on the source wallet and updates goal balance.
  Future<void> addFunds({
    required SavingsGoalModel goal,
    required double amount,
    required String sourceWalletId,
    required ExpenseProvider expenseProvider,
    required String userId,
    DateTime? transferDate,
    bool isAutoTransfer = false,
  }) async {
    await expenseProvider.addExpense(
      userId: userId,
      categoryId: 'savings_transfer',
      amount: amount,
      description: 'Transfer → ${goal.name}',
      date: transferDate ?? DateTime.now(),
      type: 'expense',
      walletId: sourceWalletId,
      savingsGoalId: goal.id,
    );

    final newAmount = goal.currentAmount + amount;
    final updated = goal.copyWith(
      currentAmount: newAmount,
      isCompleted: newAmount >= goal.targetAmount,
      lastAutoTransferDate: isAutoTransfer ? DateTime.now() : goal.lastAutoTransferDate,
    );
    await update(updated);
  }

  /// Withdraws [amount] from [goal] into [destWalletId].
  /// Creates an income record on the destination wallet and reduces goal balance.
  Future<void> withdrawFunds({
    required SavingsGoalModel goal,
    required double amount,
    required String destWalletId,
    required ExpenseProvider expenseProvider,
    required String userId,
  }) async {
    if (amount > goal.currentAmount) {
      throw Exception('Withdraw amount exceeds goal balance');
    }

    await expenseProvider.addExpense(
      userId: userId,
      categoryId: 'savings_transfer',
      amount: amount,
      description: 'Transfer ← ${goal.name}',
      date: DateTime.now(),
      type: 'income',
      walletId: destWalletId,
      savingsGoalId: goal.id,
    );

    final newAmount = goal.currentAmount - amount;
    await update(goal.copyWith(
      currentAmount: newAmount,
      isCompleted: newAmount >= goal.targetAmount,
    ));
  }

  /// Checks each goal's auto-transfer settings and runs transfers when due.
  /// Returns list of goal names that were skipped due to insufficient wallet balance.
  Future<List<String>> checkAutoTransfers({
    required WalletProvider walletProvider,
    required ExpenseProvider expenseProvider,
    required String userId,
  }) async {
    final skipped = <String>[];
    final now = DateTime.now();

    for (final goal in _goals) {
      if (!goal.autoTransferEnabled) continue;
      if (goal.autoTransferAmount == null ||
          goal.autoTransferAmount! <= 0 ||
          goal.autoTransferSourceWalletId == null ||
          goal.autoTransferDayOfMonth == null) continue;

      // Already transferred this month
      if (goal.lastAutoTransferDate != null &&
          goal.lastAutoTransferDate!.year == now.year &&
          goal.lastAutoTransferDate!.month == now.month) {
        continue;
      }

      // Not yet the scheduled day
      if (now.day < goal.autoTransferDayOfMonth!) {
        continue;
      }

      // Check source wallet balance
      final balance = walletProvider.walletBalance(
          goal.autoTransferSourceWalletId!, expenseProvider.expenses);
      if (balance < goal.autoTransferAmount!) {
        skipped.add(goal.name);
        continue;
      }

      await addFunds(
        goal: goal,
        amount: goal.autoTransferAmount!,
        sourceWalletId: goal.autoTransferSourceWalletId!,
        expenseProvider: expenseProvider,
        userId: userId,
        isAutoTransfer: true,
      );
    }

    return skipped;
  }
}

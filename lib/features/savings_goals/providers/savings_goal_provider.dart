import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../../expenses/providers/expense_provider.dart';
import '../../wallet/providers/wallet_provider.dart';

class SavingsGoalProvider extends ChangeNotifier {
  final _local = LocalStorageService.instance;
  final _db = SupabaseService.instance;
  final _uuid = const Uuid();

  List<SavingsGoalModel> _goals = [];
  bool _isLoading = false;
  String? _error;

  List<SavingsGoalModel> get goals => _goals;
  bool get isLoading => _isLoading;
  String? get error => _error;

  double get totalSaved => _goals.fold(0, (sum, g) => sum + g.currentAmount);

  double get totalTarget => _goals.fold(0, (sum, g) => sum + g.targetAmount);

  /// Local-first, same pattern as ExpenseService: read the cache instantly,
  /// only reach for Supabase when nothing has ever been cached locally (e.g.
  /// first run, or a different device) — so a dropped connection no longer
  /// makes existing goals disappear.
  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    var goals = _local.getSavingsGoals();
    // A guest session has no Supabase user at all — there's nothing to fetch
    // (and _db.getSavingsGoals would throw), so an empty local cache for a
    // guest just means "no goals yet," not "go check the cloud."
    if (goals.isEmpty && _db.isLoggedIn) {
      try {
        final cloud = await _db.getSavingsGoals();
        if (cloud.isNotEmpty) {
          await _local.replaceSavingsGoals(cloud);
          goals = _local.getSavingsGoals();
        }
      } catch (e) {
        // Surface this only when there's truly nothing to show — if local
        // has cached goals, that's shown instead of an error, same as the
        // rest of the app during a dropped connection.
        _error = e.toString();
      }
    }
    _goals = goals;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadIfNeeded() async {
    if (_goals.isEmpty && !_isLoading) await load();
  }

  Future<void> add(SavingsGoalModel goal) async {
    // Pre-generate UUID so we can insert optimistically without waiting for server
    final goalWithId = SavingsGoalModel(
      id: _uuid.v4(),
      userId: goal.userId,
      name: goal.name,
      targetAmount: goal.targetAmount,
      currentAmount: goal.currentAmount,
      deadline: goal.deadline,
      isCompleted: goal.isCompleted,
      createdAt: goal.createdAt,
      linkedWalletLabel: goal.linkedWalletLabel,
      autoTransferEnabled: goal.autoTransferEnabled,
      autoTransferAmount: goal.autoTransferAmount,
      autoTransferSourceWalletId: goal.autoTransferSourceWalletId,
      autoTransferDayOfMonth: goal.autoTransferDayOfMonth,
      lastAutoTransferDate: goal.lastAutoTransferDate,
    );
    _goals.insert(0, goalWithId);
    await _local.upsertSavingsGoal(goalWithId);
    notifyListeners();
    _db
        .insertSavingsGoal(goalWithId)
        .then((created) {
          final idx = _goals.indexWhere((g) => g.id == goalWithId.id);
          if (idx != -1) _goals[idx] = created;
          _local.upsertSavingsGoal(created);
          notifyListeners();
        })
        .catchError((_) {
          // Offline — keep the goal locally rather than rolling it back;
          // the whole point is that this should still work without a
          // connection. It'll sync up next time a cloud call succeeds.
        });
  }

  Future<void> update(SavingsGoalModel goal) async {
    final idx = _goals.indexWhere((g) => g.id == goal.id);
    if (idx != -1) _goals[idx] = goal;
    await _local.upsertSavingsGoal(goal);
    notifyListeners();
    _db
        .updateSavingsGoal(goal)
        .then((updated) {
          final i = _goals.indexWhere((g) => g.id == updated.id);
          if (i != -1) _goals[i] = updated;
          _local.upsertSavingsGoal(updated);
          notifyListeners();
        })
        .catchError((_) {
          // Offline — the local update above already stands as-is.
        });
  }

  Future<void> delete(String id) async {
    await _local.deleteSavingsGoal(id);
    _goals.removeWhere((g) => g.id == id);
    notifyListeners();
    _db.deleteSavingsGoal(id).catchError((_) {});
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
      lastAutoTransferDate: isAutoTransfer
          ? DateTime.now()
          : goal.lastAutoTransferDate,
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
    await update(
      goal.copyWith(
        currentAmount: newAmount,
        isCompleted: newAmount >= goal.targetAmount,
      ),
    );
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
          goal.autoTransferDayOfMonth == null) {
        continue;
      }

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
        goal.autoTransferSourceWalletId!,
        expenseProvider.expenses,
      );
      if (balance < goal.autoTransferAmount!) {
        skipped.add(goal.name);
        // Mark as attempted this month so we don't nag on every app open
        await update(goal.copyWith(lastAutoTransferDate: now));
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

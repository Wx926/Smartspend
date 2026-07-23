import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/loan_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../../expenses/providers/expense_provider.dart';
import '../../wallet/providers/wallet_provider.dart';

class LoanProvider extends ChangeNotifier {
  final _local = LocalStorageService.instance;
  final _db = SupabaseService.instance;
  final _uuid = const Uuid();

  List<LoanModel> _loans = [];
  bool _isLoading = false;
  String? _error;

  List<LoanModel> get loans => _loans;
  bool get isLoading => _isLoading;
  String? get error => _error;

  double get totalOwed => _loans.fold(0, (sum, l) => sum + l.remaining);

  double get totalBorrowed =>
      _loans.fold(0, (sum, l) => sum + l.principalAmount);

  /// Local-first, same pattern as SavingsGoalProvider: read the cache
  /// instantly, only reach for Supabase when nothing has ever been cached
  /// locally (e.g. first run, or a different device).
  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    var loans = _local.getLoans();
    if (loans.isEmpty && _db.isLoggedIn) {
      try {
        final cloud = await _db.getLoans();
        if (cloud.isNotEmpty) {
          await _local.replaceLoans(cloud);
          loans = _local.getLoans();
        }
      } catch (e) {
        _error = e.toString();
      }
    }
    _loans = loans;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadIfNeeded() async {
    if (_loans.isEmpty && !_isLoading) await load();
  }

  /// Creates the loan and, if [creditWalletId] is given, credits the
  /// borrowed principal into that wallet as an income record tagged
  /// 'loan_disbursement' (excluded from real income stats — the cash is
  /// real, but it isn't earnings).
  Future<void> disburse({
    required String userId,
    required String name,
    required double principalAmount,
    String? creditWalletId,
    required ExpenseProvider expenseProvider,
  }) async {
    final loan = LoanModel(
      id: _uuid.v4(),
      userId: userId,
      name: name,
      principalAmount: principalAmount,
      paidAmount: 0,
      createdAt: DateTime.now(),
    );
    _loans.insert(0, loan);
    await _local.upsertLoan(loan);
    notifyListeners();

    if (creditWalletId != null) {
      await expenseProvider.addExpense(
        userId: userId,
        categoryId: 'loan_disbursement',
        amount: principalAmount,
        description: 'Loan received: ${loan.name}',
        date: DateTime.now(),
        type: 'income',
        walletId: creditWalletId,
      );
    }

    _db
        .insertLoan(loan)
        .then((created) {
          final idx = _loans.indexWhere((l) => l.id == loan.id);
          if (idx != -1) _loans[idx] = created;
          _local.upsertLoan(created);
          notifyListeners();
        })
        .catchError((_) {
          // Offline — keep the loan locally rather than rolling it back;
          // it'll sync up next time a cloud call succeeds.
        });
  }

  Future<void> update(LoanModel loan) async {
    final idx = _loans.indexWhere((l) => l.id == loan.id);
    if (idx != -1) _loans[idx] = loan;
    await _local.upsertLoan(loan);
    notifyListeners();
    _db
        .updateLoan(loan)
        .then((updated) {
          final i = _loans.indexWhere((l) => l.id == updated.id);
          if (i != -1) _loans[i] = updated;
          _local.upsertLoan(updated);
          notifyListeners();
        })
        .catchError((_) {
          // Offline — the local update above already stands as-is.
        });
  }

  Future<void> delete(String id) async {
    _loans.removeWhere((l) => l.id == id);
    await _local.deleteLoan(id);
    notifyListeners();
    _db.deleteLoan(id).catchError((_) {});
  }

  /// Repays [amount] from [sourceWalletId] toward [loan].
  /// Creates an expense record on the source wallet (real cash out) tagged
  /// 'loan_repayment' (excluded from real expense/debt stats — same pattern
  /// as savings-goal transfers) and reduces the loan's remaining balance.
  Future<void> repay({
    required LoanModel loan,
    required double amount,
    required String sourceWalletId,
    required ExpenseProvider expenseProvider,
    required String userId,
    bool isAutoRepay = false,
  }) async {
    await expenseProvider.addExpense(
      userId: userId,
      categoryId: 'loan_repayment',
      amount: amount,
      description: 'Repay → ${loan.name}',
      date: DateTime.now(),
      type: 'expense',
      walletId: sourceWalletId,
    );

    final newPaid = loan.paidAmount + amount;
    final updated = loan.copyWith(
      paidAmount: newPaid,
      isCompleted: newPaid >= loan.principalAmount,
      lastAutoRepayDate: isAutoRepay
          ? DateTime.now()
          : loan.lastAutoRepayDate,
    );
    await update(updated);
  }

  /// Checks each loan's auto-repay settings and runs repayments when due.
  /// Returns list of loan names that were skipped due to insufficient
  /// wallet balance — same skip-and-mark-attempted-this-month behavior as
  /// SavingsGoalProvider.checkAutoTransfers, so it never partially repays.
  Future<List<String>> checkAutoRepayments({
    required WalletProvider walletProvider,
    required ExpenseProvider expenseProvider,
    required String userId,
  }) async {
    final skipped = <String>[];
    final now = DateTime.now();

    for (final loan in _loans) {
      if (loan.isCompleted || !loan.autoRepayEnabled) continue;
      if (loan.autoRepayAmount == null ||
          loan.autoRepayAmount! <= 0 ||
          loan.autoRepaySourceWalletId == null ||
          loan.autoRepayDayOfMonth == null) {
        continue;
      }

      // Already repaid this month
      if (loan.lastAutoRepayDate != null &&
          loan.lastAutoRepayDate!.year == now.year &&
          loan.lastAutoRepayDate!.month == now.month) {
        continue;
      }

      // Not yet the scheduled day
      if (now.day < loan.autoRepayDayOfMonth!) continue;

      // Only ever repay what's actually left owed, even if the fixed
      // amount would overshoot the remaining balance.
      final amount = loan.autoRepayAmount! > loan.remaining
          ? loan.remaining
          : loan.autoRepayAmount!;

      final balance = walletProvider.walletBalance(
        loan.autoRepaySourceWalletId!,
        expenseProvider.expenses,
      );
      if (balance < amount) {
        skipped.add(loan.name);
        // Mark as attempted this month so we don't nag on every app open
        await update(loan.copyWith(lastAutoRepayDate: now));
        continue;
      }

      await repay(
        loan: loan,
        amount: amount,
        sourceWalletId: loan.autoRepaySourceWalletId!,
        expenseProvider: expenseProvider,
        userId: userId,
        isAutoRepay: true,
      );
    }

    return skipped;
  }
}

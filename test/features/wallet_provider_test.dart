import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/wallet/providers/wallet_provider.dart';
import 'package:smartspend/shared/models/expense_model.dart';

void main() {
  final provider = WalletProvider();

  ExpenseModel record({
    required String type,
    required double amount,
    String walletId = 'default_account',
    String categoryId = 'food',
  }) {
    final now = DateTime(2025, 6, 5);
    return ExpenseModel(
      id: 'e-$type-$amount-$walletId-$categoryId',
      userId: 'u1',
      categoryId: categoryId,
      amount: amount,
      description: 'test',
      date: now,
      createdAt: now,
      updatedAt: now,
      type: type,
      walletId: walletId,
    );
  }

  group('walletBalance', () {
    test('income minus expense for a single wallet', () {
      final records = [
        record(type: 'income', amount: 500),
        record(type: 'expense', amount: 120),
      ];
      expect(provider.walletBalance('default_account', records), 380);
    });

    test('ignores records belonging to a different wallet', () {
      final records = [
        record(type: 'income', amount: 500, walletId: 'default_account'),
        record(type: 'expense', amount: 999, walletId: 'savings_goal'),
      ];
      expect(provider.walletBalance('default_account', records), 500);
    });

    test('returns 0 when a wallet has no records at all', () {
      expect(provider.walletBalance('empty_wallet', []), 0);
    });
  });

  group('totalAsset', () {
    test('sums income across all wallets', () {
      final records = [
        record(type: 'income', amount: 500, walletId: 'default_account'),
        record(type: 'income', amount: 200, walletId: 'goal_wallet'),
      ];
      expect(provider.totalAsset(records), 700);
    });

    test('excludes internal transfer categories (not real income)', () {
      final records = [
        record(type: 'income', amount: 500),
        record(
          type: 'income',
          amount: 300,
          categoryId: 'wallet_transfer', // moving own money, not earning it
        ),
        record(type: 'income', amount: 100, categoryId: 'savings_transfer'),
      ];
      expect(provider.totalAsset(records), 500);
    });

    test('ignores expense-type records entirely', () {
      final records = [
        record(type: 'income', amount: 500),
        record(type: 'expense', amount: 9999),
      ];
      expect(provider.totalAsset(records), 500);
    });
  });

  group('totalDebt', () {
    test('sums expenses across all wallets', () {
      final records = [
        record(type: 'expense', amount: 100, walletId: 'default_account'),
        record(type: 'expense', amount: 50, walletId: 'goal_wallet'),
      ];
      expect(provider.totalDebt(records), 150);
    });

    test('excludes savings_goal-sourced purchases (already counted)', () {
      final records = [
        record(type: 'expense', amount: 100, walletId: 'default_account'),
        record(type: 'expense', amount: 200, walletId: 'savings_goal'),
      ];
      expect(provider.totalDebt(records), 100);
    });

    test('excludes internal transfer categories', () {
      final records = [
        record(type: 'expense', amount: 100),
        record(type: 'expense', amount: 300, categoryId: 'loan_repayment'),
      ];
      expect(provider.totalDebt(records), 100);
    });
  });

  group('netAsset', () {
    test('is total income minus total expenses', () {
      final records = [
        record(type: 'income', amount: 1000),
        record(type: 'expense', amount: 400),
      ];
      expect(provider.netAsset(records), 600);
    });

    test('can go negative when spending exceeds income', () {
      final records = [
        record(type: 'income', amount: 100),
        record(type: 'expense', amount: 300),
      ];
      expect(provider.netAsset(records), -200);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/budget/services/budget_service.dart';
import 'package:smartspend/shared/models/budget_model.dart';
import 'package:smartspend/shared/models/category_model.dart';
import 'package:smartspend/shared/models/expense_model.dart';

void main() {
  final service = BudgetService.instance;

  const category = CategoryModel(
    id: 'food',
    name: 'Food & Dining',
    icon: '🍔',
    colorHex: 'FF6B35',
    type: 'expense',
  );

  BudgetModel budget(double amount, DateTime forMonth) => BudgetModel(
    id: 'b1',
    userId: 'u1',
    categoryId: 'food',
    amount: amount,
    month: forMonth.month,
    year: forMonth.year,
    createdAt: forMonth,
    updatedAt: forMonth,
  );

  ExpenseModel expense(double amount, DateTime date) => ExpenseModel(
    id: 'e-${date.millisecondsSinceEpoch}-$amount',
    userId: 'u1',
    categoryId: 'food',
    amount: amount,
    description: 'test',
    date: date,
    createdAt: date,
    updatedAt: date,
  );

  test('marks status green when projected spend is well under budget', () {
    // Fixed to a real past month so daysElapsed == daysInMonth (no
    // "now"-dependent projection), keeping the case deterministic.
    final month = DateTime(2025, 6);
    final statuses = service.computeBudgetStatuses(
      budgets: [budget(500, month)],
      categories: [category],
      expenses: [expense(100, DateTime(2025, 6, 5))],
      forMonth: month,
    );

    expect(statuses.single.severity, AlertSeverity.green);
    expect(statuses.single.spent, 100);
    expect(statuses.single.percentUsed, closeTo(0.2, 0.001));
  });

  test('marks status yellow when projected spend crosses 80%', () {
    final month = DateTime(2025, 6);
    final statuses = service.computeBudgetStatuses(
      budgets: [budget(100, month)],
      categories: [category],
      expenses: [expense(85, DateTime(2025, 6, 5))],
      forMonth: month,
    );

    expect(statuses.single.severity, AlertSeverity.yellow);
  });

  test('marks status red when projected spend exceeds 100%', () {
    final month = DateTime(2025, 6);
    final statuses = service.computeBudgetStatuses(
      budgets: [budget(100, month)],
      categories: [category],
      expenses: [expense(150, DateTime(2025, 6, 5))],
      forMonth: month,
    );

    expect(statuses.single.severity, AlertSeverity.red);
    expect(statuses.single.isOverBudget, isTrue);
  });

  test('ignores expenses from other categories or months', () {
    final month = DateTime(2025, 6);
    const otherCategory = CategoryModel(
      id: 'transport',
      name: 'Transport',
      icon: '🚗',
      colorHex: '4ECDC4',
      type: 'expense',
    );
    final statuses = service.computeBudgetStatuses(
      budgets: [budget(100, month)],
      categories: [category, otherCategory],
      expenses: [
        expense(50, DateTime(2025, 5, 20)), // wrong month
        ExpenseModel(
          id: 'e2',
          userId: 'u1',
          categoryId: 'transport', // wrong category
          amount: 999,
          description: 'bus',
          date: DateTime(2025, 6, 5),
          createdAt: DateTime(2025, 6, 5),
          updatedAt: DateTime(2025, 6, 5),
        ),
      ],
      forMonth: month,
    );

    expect(statuses.single.spent, 0);
  });

  test('handles zero-amount budget without dividing by zero', () {
    final month = DateTime(2025, 6);
    final statuses = service.computeBudgetStatuses(
      budgets: [budget(0, month)],
      categories: [category],
      expenses: [expense(10, DateTime(2025, 6, 5))],
      forMonth: month,
    );

    expect(statuses.single.percentUsed, 0.0);
    expect(statuses.single.severity, AlertSeverity.green);
  });
}

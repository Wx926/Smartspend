class BudgetModel {
  final String id;
  final String userId;
  final String categoryId;
  final double amount;
  final int month;
  final int year;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BudgetModel({
    required this.id,
    required this.userId,
    required this.categoryId,
    required this.amount,
    required this.month,
    required this.year,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BudgetModel.fromJson(Map<String, dynamic> json) {
    return BudgetModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      categoryId: json['category_id'] as String,
      amount: (json['amount'] as num).toDouble(),
      month: json['month'] as int,
      year: json['year'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'category_id': categoryId,
      'amount': amount,
      'month': month,
      'year': year,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  BudgetModel copyWith({double? amount}) {
    return BudgetModel(
      id: id,
      userId: userId,
      categoryId: categoryId,
      amount: amount ?? this.amount,
      month: month,
      year: year,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

enum AlertSeverity { green, yellow, red }

class BudgetStatus {
  final BudgetModel budget;
  final String categoryName;
  final String categoryIcon;
  final String categoryColorHex;
  final double spent;
  final double dailyBurnRate;
  final double projectedSpending;
  final double percentUsed;
  final AlertSeverity severity;

  const BudgetStatus({
    required this.budget,
    required this.categoryName,
    required this.categoryIcon,
    required this.categoryColorHex,
    required this.spent,
    required this.dailyBurnRate,
    required this.projectedSpending,
    required this.percentUsed,
    required this.severity,
  });

  double get remaining => budget.amount - spent;
  bool get isOverBudget => spent > budget.amount;

  /// Algorithm 2 Step 5: at the current daily burn rate, how many days
  /// until the remaining budget runs out. Null if already exhausted or
  /// burn rate is zero (nothing spent yet, so no rate to project from).
  double? get daysUntilDepletion {
    if (dailyBurnRate <= 0) return null;
    if (remaining <= 0) return 0;
    return remaining / dailyBurnRate;
  }
}

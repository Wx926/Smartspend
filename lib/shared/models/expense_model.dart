class ExpenseModel {
  final String id;
  final String userId;
  final String categoryId;
  final double amount;
  final String description;
  final DateTime date;
  final String? locationId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String type; // 'expense' or 'income'
  final String walletId;
  final String? savingsGoalId; // links to a savings goal when relevant

  const ExpenseModel({
    required this.id,
    required this.userId,
    required this.categoryId,
    required this.amount,
    required this.description,
    required this.date,
    this.locationId,
    required this.createdAt,
    required this.updatedAt,
    this.type = 'expense',
    this.walletId = 'default_account',
    this.savingsGoalId,
  });

  factory ExpenseModel.fromJson(Map<String, dynamic> json) {
    return ExpenseModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      categoryId: json['category_id'] as String,
      amount: (json['amount'] as num).toDouble(),
      description: json['description'] as String? ?? '',
      date: DateTime.parse(json['date'] as String),
      locationId: json['location_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      type: json['type'] as String? ?? 'expense',
      walletId: json['wallet_id'] as String? ?? 'default_account',
      savingsGoalId: json['savings_goal_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'category_id': categoryId,
      'amount': amount,
      'description': description,
      'date': date.toIso8601String().substring(0, 10),
      if (locationId != null) 'location_id': locationId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'type': type,
      'wallet_id': walletId,
      if (savingsGoalId != null) 'savings_goal_id': savingsGoalId,
    };
  }

  ExpenseModel copyWith({
    String? categoryId,
    double? amount,
    String? description,
    DateTime? date,
    String? locationId,
    String? type,
    String? walletId,
    String? savingsGoalId,
  }) {
    return ExpenseModel(
      id: id,
      userId: userId,
      categoryId: categoryId ?? this.categoryId,
      amount: amount ?? this.amount,
      description: description ?? this.description,
      date: date ?? this.date,
      locationId: locationId ?? this.locationId,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      type: type ?? this.type,
      walletId: walletId ?? this.walletId,
      savingsGoalId: savingsGoalId ?? this.savingsGoalId,
    );
  }
}

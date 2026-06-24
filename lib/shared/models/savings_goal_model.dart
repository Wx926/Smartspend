class SavingsGoalModel {
  final String id;
  final String userId;
  final String name;
  final double targetAmount;
  final double currentAmount;
  final DateTime? deadline;
  final bool isCompleted;
  final DateTime createdAt;

  const SavingsGoalModel({
    required this.id,
    required this.userId,
    required this.name,
    required this.targetAmount,
    this.currentAmount = 0,
    this.deadline,
    this.isCompleted = false,
    required this.createdAt,
  });

  double get progress =>
      targetAmount > 0 ? (currentAmount / targetAmount).clamp(0.0, 1.0) : 0;

  factory SavingsGoalModel.fromJson(Map<String, dynamic> json) {
    return SavingsGoalModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      targetAmount: (json['target_amount'] as num).toDouble(),
      currentAmount: (json['current_amount'] as num? ?? 0).toDouble(),
      deadline: json['deadline'] != null
          ? DateTime.parse(json['deadline'] as String)
          : null,
      isCompleted: json['is_completed'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'target_amount': targetAmount,
        'current_amount': currentAmount,
        'deadline': deadline?.toIso8601String().split('T').first,
        'is_completed': isCompleted,
      };

  SavingsGoalModel copyWith({
    String? name,
    double? targetAmount,
    double? currentAmount,
    DateTime? deadline,
    bool? isCompleted,
    bool clearDeadline = false,
  }) =>
      SavingsGoalModel(
        id: id,
        userId: userId,
        name: name ?? this.name,
        targetAmount: targetAmount ?? this.targetAmount,
        currentAmount: currentAmount ?? this.currentAmount,
        deadline: clearDeadline ? null : (deadline ?? this.deadline),
        isCompleted: isCompleted ?? this.isCompleted,
        createdAt: createdAt,
      );
}

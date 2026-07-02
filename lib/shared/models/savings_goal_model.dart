class SavingsGoalModel {
  final String id;
  final String userId;
  final String name;
  final double targetAmount;
  final double currentAmount;
  final DateTime? deadline;
  final bool isCompleted;
  final DateTime createdAt;
  final String? linkedWalletLabel;
  final bool autoTransferEnabled;
  final double? autoTransferAmount;
  final String? autoTransferSourceWalletId;
  final int? autoTransferDayOfMonth;
  final DateTime? lastAutoTransferDate;

  const SavingsGoalModel({
    required this.id,
    required this.userId,
    required this.name,
    required this.targetAmount,
    this.currentAmount = 0,
    this.deadline,
    this.isCompleted = false,
    required this.createdAt,
    this.linkedWalletLabel,
    this.autoTransferEnabled = false,
    this.autoTransferAmount,
    this.autoTransferSourceWalletId,
    this.autoTransferDayOfMonth,
    this.lastAutoTransferDate,
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
      linkedWalletLabel: json['linked_wallet_label'] as String?,
      autoTransferEnabled: json['auto_transfer_enabled'] as bool? ?? false,
      autoTransferAmount: (json['auto_transfer_amount'] as num?)?.toDouble(),
      autoTransferSourceWalletId:
          json['auto_transfer_source_wallet_id'] as String?,
      autoTransferDayOfMonth: json['auto_transfer_day_of_month'] as int?,
      lastAutoTransferDate: json['last_auto_transfer_date'] != null
          ? DateTime.parse(json['last_auto_transfer_date'] as String)
          : null,
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
        if (linkedWalletLabel != null) 'linked_wallet_label': linkedWalletLabel,
        'auto_transfer_enabled': autoTransferEnabled,
        if (autoTransferAmount != null) 'auto_transfer_amount': autoTransferAmount,
        if (autoTransferSourceWalletId != null)
          'auto_transfer_source_wallet_id': autoTransferSourceWalletId,
        if (autoTransferDayOfMonth != null)
          'auto_transfer_day_of_month': autoTransferDayOfMonth,
        if (lastAutoTransferDate != null)
          'last_auto_transfer_date':
              lastAutoTransferDate!.toIso8601String().split('T').first,
      };

  SavingsGoalModel copyWith({
    String? name,
    double? targetAmount,
    double? currentAmount,
    DateTime? deadline,
    bool? isCompleted,
    bool clearDeadline = false,
    String? linkedWalletLabel,
    bool? clearLinkedWalletLabel,
    bool? autoTransferEnabled,
    double? autoTransferAmount,
    String? autoTransferSourceWalletId,
    int? autoTransferDayOfMonth,
    DateTime? lastAutoTransferDate,
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
        linkedWalletLabel: (clearLinkedWalletLabel == true)
            ? null
            : (linkedWalletLabel ?? this.linkedWalletLabel),
        autoTransferEnabled: autoTransferEnabled ?? this.autoTransferEnabled,
        autoTransferAmount: autoTransferAmount ?? this.autoTransferAmount,
        autoTransferSourceWalletId:
            autoTransferSourceWalletId ?? this.autoTransferSourceWalletId,
        autoTransferDayOfMonth:
            autoTransferDayOfMonth ?? this.autoTransferDayOfMonth,
        lastAutoTransferDate: lastAutoTransferDate ?? this.lastAutoTransferDate,
      );
}

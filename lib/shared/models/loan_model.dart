class LoanModel {
  final String id;
  final String userId;
  final String name;
  final double principalAmount;
  final double paidAmount;
  final bool isCompleted;
  final DateTime createdAt;
  final bool autoRepayEnabled;
  final double? autoRepayAmount;
  final String? autoRepaySourceWalletId;
  final int? autoRepayDayOfMonth;
  final DateTime? lastAutoRepayDate;

  const LoanModel({
    required this.id,
    required this.userId,
    required this.name,
    required this.principalAmount,
    this.paidAmount = 0,
    this.isCompleted = false,
    required this.createdAt,
    this.autoRepayEnabled = false,
    this.autoRepayAmount,
    this.autoRepaySourceWalletId,
    this.autoRepayDayOfMonth,
    this.lastAutoRepayDate,
  });

  double get remaining => (principalAmount - paidAmount).clamp(
    0.0,
    principalAmount,
  );

  double get progress =>
      principalAmount > 0 ? (paidAmount / principalAmount).clamp(0.0, 1.0) : 0;

  factory LoanModel.fromJson(Map<String, dynamic> json) {
    return LoanModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      principalAmount: (json['principal_amount'] as num).toDouble(),
      paidAmount: (json['paid_amount'] as num? ?? 0).toDouble(),
      isCompleted: json['is_completed'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      autoRepayEnabled: json['auto_repay_enabled'] as bool? ?? false,
      autoRepayAmount: (json['auto_repay_amount'] as num?)?.toDouble(),
      autoRepaySourceWalletId: json['auto_repay_source_wallet_id'] as String?,
      autoRepayDayOfMonth: json['auto_repay_day_of_month'] as int?,
      lastAutoRepayDate: json['last_auto_repay_date'] != null
          ? DateTime.parse(json['last_auto_repay_date'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'principal_amount': principalAmount,
    'paid_amount': paidAmount,
    'is_completed': isCompleted,
    'created_at': createdAt.toIso8601String(),
    'auto_repay_enabled': autoRepayEnabled,
    if (autoRepayAmount != null) 'auto_repay_amount': autoRepayAmount,
    if (autoRepaySourceWalletId != null)
      'auto_repay_source_wallet_id': autoRepaySourceWalletId,
    if (autoRepayDayOfMonth != null)
      'auto_repay_day_of_month': autoRepayDayOfMonth,
    if (lastAutoRepayDate != null)
      'last_auto_repay_date': lastAutoRepayDate!.toIso8601String().split(
        'T',
      ).first,
  };

  LoanModel copyWith({
    String? name,
    double? principalAmount,
    double? paidAmount,
    bool? isCompleted,
    bool? autoRepayEnabled,
    double? autoRepayAmount,
    String? autoRepaySourceWalletId,
    int? autoRepayDayOfMonth,
    DateTime? lastAutoRepayDate,
  }) => LoanModel(
    id: id,
    userId: userId,
    name: name ?? this.name,
    principalAmount: principalAmount ?? this.principalAmount,
    paidAmount: paidAmount ?? this.paidAmount,
    isCompleted: isCompleted ?? this.isCompleted,
    createdAt: createdAt,
    autoRepayEnabled: autoRepayEnabled ?? this.autoRepayEnabled,
    autoRepayAmount: autoRepayAmount ?? this.autoRepayAmount,
    autoRepaySourceWalletId:
        autoRepaySourceWalletId ?? this.autoRepaySourceWalletId,
    autoRepayDayOfMonth: autoRepayDayOfMonth ?? this.autoRepayDayOfMonth,
    lastAutoRepayDate: lastAutoRepayDate ?? this.lastAutoRepayDate,
  );
}

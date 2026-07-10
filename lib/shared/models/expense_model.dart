class ExpenseModel {
  final String id;
  final String userId;
  final String categoryId;
  final double amount;
  final String description;
  final DateTime date;
  final String? locationId;
  // A snapshot of the place name at the time this record was made, kept even
  // when the user declines to save it as a permanent location (or later
  // deletes that saved location) — so the visit still shows up in history.
  final String? locationName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String type; // 'expense' or 'income'
  final String walletId;
  final String? savingsGoalId; // links to a savings goal when relevant
  final String source; // 'manual' | 'ocr' | 'voice' — how this record was created
  final String? merchantName; // set when source is 'ocr'/'voice'
  final String? batchId; // shared by every line item from the same receipt scan
  final String? receiptImageUrl; // Supabase Storage public URL for the scanned receipt photo

  const ExpenseModel({
    required this.id,
    required this.userId,
    required this.categoryId,
    required this.amount,
    required this.description,
    required this.date,
    this.locationId,
    this.locationName,
    required this.createdAt,
    required this.updatedAt,
    this.type = 'expense',
    this.walletId = 'default_account',
    this.savingsGoalId,
    this.source = 'manual',
    this.merchantName,
    this.batchId,
    this.receiptImageUrl,
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
      locationName: json['location_name'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      type: json['type'] as String? ?? 'expense',
      walletId: json['wallet_id'] as String? ?? 'default_account',
      savingsGoalId: json['savings_goal_id'] as String?,
      source: json['source'] as String? ?? 'manual',
      merchantName: json['merchant_name'] as String?,
      batchId: json['batch_id'] as String?,
      receiptImageUrl: json['receipt_image_url'] as String?,
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
      if (locationName != null) 'location_name': locationName,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'type': type,
      'wallet_id': walletId,
      if (savingsGoalId != null) 'savings_goal_id': savingsGoalId,
      'source': source,
      if (merchantName != null) 'merchant_name': merchantName,
      if (batchId != null) 'batch_id': batchId,
      if (receiptImageUrl != null) 'receipt_image_url': receiptImageUrl,
    };
  }

  ExpenseModel copyWith({
    String? categoryId,
    double? amount,
    String? description,
    DateTime? date,
    String? locationId,
    String? locationName,
    String? type,
    String? walletId,
    String? savingsGoalId,
    String? source,
    String? merchantName,
    String? batchId,
    String? receiptImageUrl,
  }) {
    return ExpenseModel(
      id: id,
      userId: userId,
      categoryId: categoryId ?? this.categoryId,
      amount: amount ?? this.amount,
      description: description ?? this.description,
      date: date ?? this.date,
      locationId: locationId ?? this.locationId,
      locationName: locationName ?? this.locationName,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      type: type ?? this.type,
      walletId: walletId ?? this.walletId,
      savingsGoalId: savingsGoalId ?? this.savingsGoalId,
      source: source ?? this.source,
      merchantName: merchantName ?? this.merchantName,
      batchId: batchId ?? this.batchId,
      receiptImageUrl: receiptImageUrl ?? this.receiptImageUrl,
    );
  }
}

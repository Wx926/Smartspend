class AlertLogModel {
  final String id;
  final String userId;
  final String type; // 'green' | 'yellow' | 'red' | 'location'
  final String title;
  final String message;
  final String? categoryId;
  final bool isRead;
  final DateTime createdAt;

  const AlertLogModel({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    required this.message,
    this.categoryId,
    this.isRead = false,
    required this.createdAt,
  });

  factory AlertLogModel.fromJson(Map<String, dynamic> json) {
    return AlertLogModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      type: json['type'] as String,
      title: json['title'] as String,
      message: json['message'] as String,
      categoryId: json['category_id'] as String?,
      isRead: json['is_read'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'type': type,
      'title': title,
      'message': message,
      if (categoryId != null) 'category_id': categoryId,
      'is_read': isRead,
      'created_at': createdAt.toIso8601String(),
    };
  }

  AlertLogModel markRead() {
    return AlertLogModel(
      id: id,
      userId: userId,
      type: type,
      title: title,
      message: message,
      categoryId: categoryId,
      isRead: true,
      createdAt: createdAt,
    );
  }
}

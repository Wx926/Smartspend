class ChatMessageRecord {
  final String text;
  final bool isUser;

  const ChatMessageRecord({required this.text, required this.isUser});

  factory ChatMessageRecord.fromJson(Map<String, dynamic> json) =>
      ChatMessageRecord(
        text: json['text'] as String,
        isUser: json['is_user'] as bool,
      );

  Map<String, dynamic> toJson() => {'text': text, 'is_user': isUser};
}

class ChatSessionModel {
  final String id;
  final String userId;
  final String title;
  final List<ChatMessageRecord> messages;
  final bool isStarred;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ChatSessionModel({
    required this.id,
    required this.userId,
    required this.title,
    this.messages = const [],
    this.isStarred = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Supabase returns the jsonb `messages` column as a native List, but the
  /// same fromJson also round-trips through local storage's jsonEncode/
  /// jsonDecode of the whole session — decode defensively either way.
  static List<ChatMessageRecord> _parseMessages(dynamic raw) {
    if (raw == null) return [];
    final list = raw as List;
    return list
        .map((e) => ChatMessageRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  factory ChatSessionModel.fromJson(Map<String, dynamic> json) {
    return ChatSessionModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      title: json['title'] as String,
      messages: _parseMessages(json['messages']),
      isStarred: json['is_starred'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'is_starred': isStarred,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  ChatSessionModel copyWith({
    String? title,
    List<ChatMessageRecord>? messages,
    bool? isStarred,
    DateTime? updatedAt,
  }) => ChatSessionModel(
    id: id,
    userId: userId,
    title: title ?? this.title,
    messages: messages ?? this.messages,
    isStarred: isStarred ?? this.isStarred,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class AiInsightModel {
  final String id;
  final String userId;
  final String content;
  final String type; // 'advice' | 'forecast' | 'tip'
  final int? month;
  final int? year;
  final DateTime createdAt;

  const AiInsightModel({
    required this.id,
    required this.userId,
    required this.content,
    required this.type,
    this.month,
    this.year,
    required this.createdAt,
  });

  factory AiInsightModel.fromJson(Map<String, dynamic> json) {
    return AiInsightModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      content: json['content'] as String,
      type: json['type'] as String,
      month: json['month'] as int?,
      year: json['year'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'content': content,
      'type': type,
      if (month != null) 'month': month,
      if (year != null) 'year': year,
    };
  }
}

/// A previously-picked receipt file (image or PDF) remembered locally so it
/// can show up in the custom receipt picker's "Recents" section with a real
/// thumbnail, without needing broad device-storage permissions.
class RecentReceiptModel {
  final String id;
  final String filePath;
  final String thumbnailPath;
  final bool isPdf;
  final DateTime addedAt;

  const RecentReceiptModel({
    required this.id,
    required this.filePath,
    required this.thumbnailPath,
    required this.isPdf,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_path': filePath,
        'thumbnail_path': thumbnailPath,
        'is_pdf': isPdf,
        'added_at': addedAt.toIso8601String(),
      };

  factory RecentReceiptModel.fromJson(Map<String, dynamic> json) =>
      RecentReceiptModel(
        id: json['id'] as String,
        filePath: json['file_path'] as String,
        thumbnailPath: json['thumbnail_path'] as String,
        isPdf: json['is_pdf'] as bool? ?? false,
        addedAt: DateTime.parse(json['added_at'] as String),
      );
}

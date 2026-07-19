class CategoryModel {
  final String id;
  final String name;
  final String icon;
  final String colorHex;
  final String type; // 'expense' or 'income'
  final bool isDefault;
  // null = a shared default category (seeded, visible to everyone). Set =
  // this user's own custom category — requires the categories table
  // migration (supabase_migration_sync_fix.sql) to actually sync to Supabase.
  final String? userId;

  const CategoryModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.colorHex,
    required this.type,
    this.isDefault = true,
    this.userId,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String,
      colorHex: json['color_hex'] as String,
      type: json['type'] as String,
      isDefault: json['is_default'] as bool? ?? true,
      userId: json['user_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
      'color_hex': colorHex,
      'type': type,
      'is_default': isDefault,
      if (userId != null) 'user_id': userId,
    };
  }

  CategoryModel copyWith({
    String? id,
    String? name,
    String? icon,
    String? colorHex,
    String? type,
    bool? isDefault,
    String? userId,
  }) {
    return CategoryModel(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      colorHex: colorHex ?? this.colorHex,
      type: type ?? this.type,
      isDefault: isDefault ?? this.isDefault,
      userId: userId ?? this.userId,
    );
  }
}

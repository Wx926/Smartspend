class CategoryModel {
  final String id;
  final String name;
  final String icon;
  final String colorHex;
  final String type; // 'expense' or 'income'
  final bool isDefault;

  const CategoryModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.colorHex,
    required this.type,
    this.isDefault = true,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String,
      colorHex: json['color_hex'] as String,
      type: json['type'] as String,
      isDefault: json['is_default'] as bool? ?? true,
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
    };
  }

  CategoryModel copyWith({
    String? id,
    String? name,
    String? icon,
    String? colorHex,
    String? type,
    bool? isDefault,
  }) {
    return CategoryModel(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      colorHex: colorHex ?? this.colorHex,
      type: type ?? this.type,
      isDefault: isDefault ?? this.isDefault,
    );
  }
}

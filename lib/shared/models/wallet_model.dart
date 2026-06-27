class WalletModel {
  final String id;
  final String name;
  final String icon;
  final String colorHex;
  final bool isDefault;

  const WalletModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.colorHex,
    this.isDefault = false,
  });

  factory WalletModel.fromJson(Map<String, dynamic> json) => WalletModel(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: json['icon'] as String,
        colorHex: json['color_hex'] as String,
        isDefault: json['is_default'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon,
        'color_hex': colorHex,
        'is_default': isDefault,
      };
}

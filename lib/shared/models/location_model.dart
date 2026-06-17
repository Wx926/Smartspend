class LocationModel {
  final String id;
  final String userId;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  final String? categoryHint;
  final int visitCount;
  final bool isRoutine;
  final DateTime createdAt;

  const LocationModel({
    required this.id,
    required this.userId,
    required this.name,
    this.address,
    required this.latitude,
    required this.longitude,
    this.categoryHint,
    this.visitCount = 0,
    this.isRoutine = false,
    required this.createdAt,
  });

  factory LocationModel.fromJson(Map<String, dynamic> json) {
    return LocationModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      address: json['address'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      categoryHint: json['category_hint'] as String?,
      visitCount: json['visit_count'] as int? ?? 0,
      isRoutine: json['is_routine'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      if (address != null) 'address': address,
      'latitude': latitude,
      'longitude': longitude,
      if (categoryHint != null) 'category_hint': categoryHint,
      'visit_count': visitCount,
      'is_routine': isRoutine,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class LocationHistoryModel {
  final String id;
  final String userId;
  final String? locationId;
  final double latitude;
  final double longitude;
  final DateTime arrivedAt;
  final DateTime? leftAt;
  final int? dwellTimeMinutes;
  final bool triggeredAlert;

  const LocationHistoryModel({
    required this.id,
    required this.userId,
    this.locationId,
    required this.latitude,
    required this.longitude,
    required this.arrivedAt,
    this.leftAt,
    this.dwellTimeMinutes,
    this.triggeredAlert = false,
  });

  factory LocationHistoryModel.fromJson(Map<String, dynamic> json) {
    return LocationHistoryModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      locationId: json['location_id'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      arrivedAt: DateTime.parse(json['arrived_at'] as String),
      leftAt: json['left_at'] != null ? DateTime.parse(json['left_at'] as String) : null,
      dwellTimeMinutes: json['dwell_time_minutes'] as int?,
      triggeredAlert: json['triggered_alert'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      if (locationId != null) 'location_id': locationId,
      'latitude': latitude,
      'longitude': longitude,
      'arrived_at': arrivedAt.toIso8601String(),
      if (leftAt != null) 'left_at': leftAt!.toIso8601String(),
      if (dwellTimeMinutes != null) 'dwell_time_minutes': dwellTimeMinutes,
      'triggered_alert': triggeredAlert,
    };
  }
}

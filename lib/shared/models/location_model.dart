class LocationModel {
  final String id;
  final String userId;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  // Category ids (CategoryModel.id) relevant at this venue — a mall might
  // have Food + Shopping + Entertainment all set. System-suggested (from an
  // OSM place type) or user-picked; always user-editable either way.
  final List<String> categoryIds;
  final int visitCount;
  final bool isRoutine;
  // User correction for when auto-detection gets it wrong: null = trust
  // isRoutine, true = force-treat as Home/Work (always mute alerts here),
  // false = force-treat as not routine (always alert here regardless of
  // how often it's visited).
  final bool? routineOverride;
  final DateTime createdAt;

  const LocationModel({
    required this.id,
    required this.userId,
    required this.name,
    this.address,
    required this.latitude,
    required this.longitude,
    this.categoryIds = const [],
    this.visitCount = 0,
    this.isRoutine = false,
    this.routineOverride,
    required this.createdAt,
  });

  /// What Algorithm 1 / Algorithm 3 should actually treat this location as
  /// — the user's manual correction wins over the auto-detected pattern.
  bool get effectiveIsRoutine => routineOverride ?? isRoutine;

  factory LocationModel.fromJson(Map<String, dynamic> json) {
    return LocationModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      address: json['address'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      categoryIds:
          (json['category_ids'] as List?)?.map((e) => e as String).toList() ??
          const [],
      visitCount: json['visit_count'] as int? ?? 0,
      isRoutine: json['is_routine'] as bool? ?? false,
      routineOverride: json['routine_override'] as bool?,
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
      if (categoryIds.isNotEmpty) 'category_ids': categoryIds,
      'visit_count': visitCount,
      'is_routine': isRoutine,
      if (routineOverride != null) 'routine_override': routineOverride,
      'created_at': createdAt.toIso8601String(),
    };
  }

  // Two dedicated copy methods rather than one shared copyWith: both
  // routineOverride and categoryIds need to support being explicitly
  // cleared, which a single nullable named parameter can't distinguish
  // from "leave unchanged".
  LocationModel copyWithRoutineOverride(bool? routineOverride) {
    return LocationModel(
      id: id,
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryIds: categoryIds,
      visitCount: visitCount,
      isRoutine: isRoutine,
      routineOverride: routineOverride,
      createdAt: createdAt,
    );
  }

  LocationModel copyWithCategoryIds(List<String> categoryIds) {
    return LocationModel(
      id: id,
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryIds: categoryIds,
      visitCount: visitCount,
      isRoutine: isRoutine,
      routineOverride: routineOverride,
      createdAt: createdAt,
    );
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
      leftAt: json['left_at'] != null
          ? DateTime.parse(json['left_at'] as String)
          : null,
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

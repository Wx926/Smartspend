import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/services/local_storage_service.dart';

/// Algorithm 1: Location Detection + Dwell Time Filtering
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  final _store = LocalStorageService.instance;
  final _uuid = const Uuid();

  Timer? _timer;
  String? _activeHistoryId;
  String? _currentLocationId;
  DateTime? _arrivedAt;

  final StreamController<LocationEvent> _eventController =
      StreamController.broadcast();
  Stream<LocationEvent> get events => _eventController.stream;

  /// Request permission and start polling every 60 seconds.
  Future<bool> startTracking(String userId) async {
    final permission = await _requestPermission();
    if (!permission) return false;

    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: AppConstants.locationIntervalSeconds),
      (_) => _poll(userId),
    );
    await _poll(userId);
    return true;
  }

  void stopTracking() {
    _timer?.cancel();
    _timer = null;
  }

  /// Force an immediate poll outside the normal 60-second interval.
  Future<void> forcePoll(String userId) => _poll(userId);

  Future<bool> _requestPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;
    return true;
  }

  Future<void> _poll(String userId) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 15));

      final knownLocations = _store.getLocations();
      LocationModel? matched;

      for (final loc in knownLocations) {
        final dist = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          loc.latitude,
          loc.longitude,
        );
        if (dist <= AppConstants.geofenceRadiusMeters) {
          matched = loc;
          break;
        }
      }

      if (matched != null) {
        if (_currentLocationId != matched.id) {
          await _closeCurrentVisit(userId);
          _currentLocationId = matched.id;
          _arrivedAt = DateTime.now();
          _activeHistoryId = _uuid.v4();
          _store.bufferHistory(LocationHistoryModel(
            id: _activeHistoryId!,
            userId: userId,
            locationId: matched.id,
            latitude: position.latitude,
            longitude: position.longitude,
            arrivedAt: _arrivedAt!,
          ));
          _eventController.add(LocationEvent(
            type: LocationEventType.entered,
            location: matched,
            dwellMinutes: 0,
          ));
        } else {
          final dwell = DateTime.now().difference(_arrivedAt!).inMinutes;
          if (dwell >= AppConstants.dwellTimeMinutes) {
            _eventController.add(LocationEvent(
              type: LocationEventType.dwell,
              location: matched,
              dwellMinutes: dwell,
            ));
          }
        }
      } else if (_currentLocationId != null) {
        await _closeCurrentVisit(userId);
      }
    } catch (_) {
      // Silently ignore GPS errors
    }
  }

  Future<void> _closeCurrentVisit(String userId) async {
    if (_activeHistoryId != null && _arrivedAt != null) {
      final dwell = DateTime.now().difference(_arrivedAt!).inMinutes;
      _store.closeHistory(_activeHistoryId!, DateTime.now(), dwell);
      if (_currentLocationId != null) {
        await _store.incrementVisitCount(_currentLocationId!);
      }
    }
    _activeHistoryId = null;
    _currentLocationId = null;
    _arrivedAt = null;
  }

  Future<LocationModel> saveLocation({
    required String userId,
    required String name,
    String? address,
    required double latitude,
    required double longitude,
    String? categoryHint,
  }) async {
    final loc = LocationModel(
      id: _uuid.v4(),
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryHint: categoryHint,
      createdAt: DateTime.now(),
    );
    return _store.upsertLocation(loc);
  }

  Future<Position?> getCurrentPosition() async {
    try {
      // getLastKnownPosition reflects emulator location changes immediately
      // and is faster than waiting for a fresh GPS fix
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }
}

enum LocationEventType { entered, dwell }

class LocationEvent {
  final LocationEventType type;
  final LocationModel location;
  final int dwellMinutes;
  const LocationEvent({
    required this.type,
    required this.location,
    required this.dwellMinutes,
  });
}

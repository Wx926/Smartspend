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
  // Whether _currentLocationId has been confirmed as the "now location"
  // (either by dwelling there long enough, or by a manual refresh).
  bool _confirmed = false;

  final StreamController<LocationEvent> _eventController =
      StreamController.broadcast();
  Stream<LocationEvent> get events => _eventController.stream;

  /// Request permission and start polling every
  /// [AppConstants.locationIntervalSeconds] seconds.
  Future<bool> startTracking(String userId) async {
    final permission = await requestPermission();
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

  /// Force an immediate poll outside the normal periodic interval. Unlike a
  /// regular background poll, a forced one confirms whatever location is
  /// currently matched right away instead of waiting for
  /// [AppConstants.dwellTimeMinutes] to pass.
  Future<void> forcePoll(String userId) => _poll(userId, forced: true);

  /// Public so the foreground UI (which has a live Activity to show the OS
  /// permission dialog) can request it before handing tracking off to the
  /// background service, which has no Activity of its own to prompt from.
  Future<bool> requestPermission() async {
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

  /// Runs one detection cycle.
  ///
  /// Algorithm: a newly-matched location is tracked immediately, but only
  /// confirmed as the "now location" (surfaced via a LocationEvent) once the
  /// user has dwelled there for [AppConstants.dwellTimeMinutes] — unless
  /// [forced] is true (a manual refresh), which confirms it right away.
  Future<void> _poll(String userId, {bool forced = false}) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));

      // Pick up any saved-location/category edits made from the foreground
      // app since this isolate's SharedPreferences cache was last refreshed.
      await _store.reload();
      final knownLocations = _store.getLocations();
      LocationModel? matched;
      double matchedDist = double.infinity;

      // Closest match wins, not the first one found — two saved spots can
      // easily be within range of each other (e.g. a cafe next to a mall).
      for (final loc in knownLocations) {
        final dist = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          loc.latitude,
          loc.longitude,
        );
        if (dist <= AppConstants.geofenceRadiusMeters && dist < matchedDist) {
          matched = loc;
          matchedDist = dist;
        }
      }

      if (matched != null) {
        if (_currentLocationId != matched.id) {
          // Switched to a new (or first) location — reset the dwell clock
          // and un-confirm until it earns "now location" status too.
          final wasConfirmed = _confirmed;
          await _closeCurrentVisit(userId);
          _currentLocationId = matched.id;
          _arrivedAt = DateTime.now();
          _activeHistoryId = _uuid.v4();
          await _store.bufferHistory(
            LocationHistoryModel(
              id: _activeHistoryId!,
              userId: userId,
              locationId: matched.id,
              latitude: position.latitude,
              longitude: position.longitude,
              arrivedAt: _arrivedAt!,
            ),
          );

          if (forced) {
            _confirmed = true;
            _eventController.add(
              LocationEvent(
                type: LocationEventType.entered,
                location: matched,
                dwellMinutes: 0,
              ),
            );
          } else if (wasConfirmed) {
            // Left a confirmed location for an unconfirmed one — clear the
            // "now location" state until the new spot earns it.
            _eventController.add(
              const LocationEvent(
                type: LocationEventType.left,
                location: null,
                dwellMinutes: 0,
              ),
            );
          }
        } else if (!_confirmed) {
          final dwell = DateTime.now().difference(_arrivedAt!).inMinutes;
          if (forced || dwell >= AppConstants.dwellTimeMinutes) {
            _confirmed = true;
            _eventController.add(
              LocationEvent(
                type: LocationEventType.entered,
                location: matched,
                dwellMinutes: dwell,
              ),
            );
          }
        } else {
          // Already confirmed — keep the displayed dwell time current.
          final dwell = DateTime.now().difference(_arrivedAt!).inMinutes;
          _eventController.add(
            LocationEvent(
              type: LocationEventType.dwell,
              location: matched,
              dwellMinutes: dwell,
            ),
          );
        }
      } else if (_currentLocationId != null) {
        final wasConfirmed = _confirmed;
        await _closeCurrentVisit(userId);
        if (wasConfirmed) {
          _eventController.add(
            const LocationEvent(
              type: LocationEventType.left,
              location: null,
              dwellMinutes: 0,
            ),
          );
        }
      }
    } catch (_) {
      // Silently ignore GPS errors
    }
  }

  Future<void> _closeCurrentVisit(String userId) async {
    if (_activeHistoryId != null && _arrivedAt != null) {
      final dwell = DateTime.now().difference(_arrivedAt!).inMinutes;
      await _store.closeHistory(_activeHistoryId!, DateTime.now(), dwell);
      if (_currentLocationId != null) {
        await _store.incrementVisitCount(_currentLocationId!);
      }
    }
    _activeHistoryId = null;
    _currentLocationId = null;
    _arrivedAt = null;
    _confirmed = false;
  }

  Future<LocationModel> saveLocation({
    required String userId,
    required String name,
    String? address,
    required double latitude,
    required double longitude,
    List<String> categoryIds = const [],
  }) async {
    final loc = LocationModel(
      id: _uuid.v4(),
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryIds: categoryIds,
      createdAt: DateTime.now(),
    );
    return _store.upsertLocation(loc);
  }

  Future<Position?> getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Fall back to a cached fix if a fresh one couldn't be obtained
      // (e.g. GPS unavailable or the request timed out).
      return Geolocator.getLastKnownPosition();
    }
  }
}

enum LocationEventType { entered, dwell, left }

class LocationEvent {
  final LocationEventType type;
  final LocationModel? location;
  final int dwellMinutes;
  const LocationEvent({
    required this.type,
    required this.location,
    required this.dwellMinutes,
  });
}

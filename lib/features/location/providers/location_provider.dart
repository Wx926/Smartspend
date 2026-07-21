import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../services/location_service.dart';

class LocationProvider extends ChangeNotifier {
  // Only used here for one-off calls (saveLocation, requestPermission) — the
  // actual polling loop now runs inside the background service's own isolate
  // (see background_location_service.dart), not in this app process.
  final _service = LocationService.instance;
  final _store = LocalStorageService.instance;
  final _supabase = SupabaseService.instance;
  final _bgService = FlutterBackgroundService();

  List<LocationModel> _locations = [];
  bool _isTracking = false;
  bool _isLoading = false;
  String? _error;
  StreamSubscription<Map<String, dynamic>?>? _sub;

  // Currently detected location (Algorithm 1 output), mirrored from the
  // background service's events so the UI can display it live.
  LocationModel? _activeLocation;
  int _activeDwellMinutes = 0;

  final StreamController<LocationEvent> _eventController =
      StreamController.broadcast();

  List<LocationModel> get locations => _locations;
  bool get isTracking => _isTracking;
  bool get isLoading => _isLoading;
  String? get error => _error;
  LocationModel? get activeLocation => _activeLocation;
  int get activeDwellMinutes => _activeDwellMinutes;

  List<LocationModel> get routineLocations =>
      _locations.where((l) => l.effectiveIsRoutine).toList();

  Future<void> setRoutineOverride(String locationId, bool? override) async {
    await _store.setRoutineOverride(locationId, override);
    final idx = _locations.indexWhere((l) => l.id == locationId);
    if (idx != -1) {
      _locations[idx] = _locations[idx].copyWithRoutineOverride(override);
      notifyListeners();
      _syncUpsert(_locations[idx]);
    }
  }

  Future<void> setCategoryIds(
    String locationId,
    List<String> categoryIds,
  ) async {
    await _store.setCategoryIds(locationId, categoryIds);
    _locations = _store.getLocations();
    notifyListeners();
    final updated = _locations.where((l) => l.id == locationId).firstOrNull;
    if (updated != null) _syncUpsert(updated);
  }

  Future<void> _syncUpsert(LocationModel loc) async {
    if (!_supabase.isLoggedIn) return;
    try {
      await _supabase.upsertLocation(loc);
    } catch (_) {}
  }

  /// Local-first, same pattern as ExpenseService: read the cache instantly,
  /// only reach for Supabase when nothing has ever been cached locally (e.g.
  /// first run, or a different device/account) — so a dropped connection no
  /// longer makes existing saved locations disappear.
  Future<void> load([String? userId]) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    var locations = _store.getLocations();
    if (locations.isEmpty && _supabase.isLoggedIn) {
      try {
        final cloud = await _supabase.getLocations();
        if (cloud.isNotEmpty) {
          for (final loc in cloud) {
            await _store.upsertLocation(loc);
          }
          locations = _store.getLocations();
        }
      } catch (e) {
        _error = e.toString();
      }
    }
    _locations = locations;
    try {
      // Auto-resume tracking if it was on before the app was closed. Safe to
      // call even if the background service is already running (e.g. it
      // survived the app being killed) — it just (re)attaches the listener.
      if (!_isTracking && userId != null && _store.trackingEnabled) {
        await startTracking(userId);
      }
    } catch (_) {}
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> startTracking(String userId) async {
    // Requested here (foreground, with a live Activity) rather than inside
    // the background service, which has no Activity to show the OS dialog.
    final granted = await _service.requestPermission();
    if (!granted) return false;

    await _store.setTrackingEnabled(true);

    // Best-effort: improves the odds Android doesn't kill the service later.
    // Not blocking — some OEMs restrict this further regardless.
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}

    if (!await _bgService.isRunning()) {
      await _bgService.startService();
    }

    _sub?.cancel();
    _sub = _bgService.on('locationEvent').listen((data) {
      if (data == null) return;
      final type = LocationEventType.values.byName(data['type'] as String);
      final locationJson = data['location'] as Map<dynamic, dynamic>?;
      final location = locationJson != null
          ? LocationModel.fromJson(Map<String, dynamic>.from(locationJson))
          : null;
      final dwellMinutes = data['dwellMinutes'] as int? ?? 0;

      if (type == LocationEventType.left) {
        _activeLocation = null;
        _activeDwellMinutes = 0;
      } else {
        _activeLocation = location;
        _activeDwellMinutes = dwellMinutes;
      }
      _eventController.add(
        LocationEvent(
          type: type,
          location: location,
          dwellMinutes: dwellMinutes,
        ),
      );
      notifyListeners();
    });

    _isTracking = true;
    notifyListeners();
    return true;
  }

  void stopTracking() {
    _bgService.invoke('stopTracking');
    _store.setTrackingEnabled(false);
    _sub?.cancel();
    _sub = null;
    _isTracking = false;
    _activeLocation = null;
    _activeDwellMinutes = 0;
    notifyListeners();
  }

  Future<void> refresh(String userId) async {
    _bgService.invoke('forcePoll');
  }

  Future<void> deleteLocation(String locationId) async {
    await _store.deleteLocation(locationId);
    _locations.removeWhere((l) => l.id == locationId);
    notifyListeners();
    if (_supabase.isLoggedIn) {
      _supabase.deleteLocation(locationId).catchError((_) {});
    }
  }

  Stream<LocationEvent> get locationEvents => _eventController.stream;

  Future<LocationModel> addLocation({
    required String userId,
    required String name,
    String? address,
    required double latitude,
    required double longitude,
    List<String> categoryIds = const [],
  }) async {
    final loc = await _service.saveLocation(
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryIds: categoryIds,
    );
    _locations.insert(0, loc);
    notifyListeners();
    return loc;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

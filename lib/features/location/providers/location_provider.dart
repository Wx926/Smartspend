import 'dart:async';
import 'package:flutter/material.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../services/location_service.dart';

class LocationProvider extends ChangeNotifier {
  final _service = LocationService.instance;
  final _store = LocalStorageService.instance;

  List<LocationModel> _locations = [];
  bool _isTracking = false;
  bool _isLoading = false;
  String? _error;
  StreamSubscription<LocationEvent>? _sub;

  // Currently detected location (Algorithm 1 output)
  LocationModel? _activeLocation;
  int _activeDwellMinutes = 0;

  List<LocationModel> get locations => _locations;
  bool get isTracking => _isTracking;
  bool get isLoading => _isLoading;
  String? get error => _error;
  LocationModel? get activeLocation => _activeLocation;
  int get activeDwellMinutes => _activeDwellMinutes;

  List<LocationModel> get routineLocations =>
      _locations.where((l) => l.isRoutine).toList();

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _locations = _store.getLocations();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> startTracking(String userId) async {
    final started = await _service.startTracking(userId);
    _isTracking = started;
    if (started) {
      _sub?.cancel();
      _sub = _service.events.listen((event) {
        _activeLocation = event.location;
        _activeDwellMinutes = event.dwellMinutes;
        notifyListeners();
      });
    }
    notifyListeners();
    return started;
  }

  void stopTracking() {
    _service.stopTracking();
    _sub?.cancel();
    _isTracking = false;
    _activeLocation = null;
    _activeDwellMinutes = 0;
    notifyListeners();
  }

  Stream<LocationEvent> get locationEvents => _service.events;

  Future<LocationModel> addLocation({
    required String userId,
    required String name,
    String? address,
    required double latitude,
    required double longitude,
    String? categoryHint,
  }) async {
    final loc = await _service.saveLocation(
      userId: userId,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      categoryHint: categoryHint,
    );
    _locations.insert(0, loc);
    notifyListeners();
    return loc;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _service.stopTracking();
    super.dispose();
  }
}

import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/alerts/services/alert_service.dart';
import '../../features/location/services/location_service.dart';
import '../constants/app_constants.dart';
import 'local_storage_service.dart';

const trackingNotificationChannelId = 'smartspend_tracking';

/// Registers the foreground service so Algorithm 1 (location polling) and
/// Algorithm 3 (budget alerts) keep running even if the app is closed or the
/// phone is locked. Called once from main() — this only configures the
/// service, it doesn't start it (that happens when the user turns the
/// "Location Tracking" toggle on, same as before).
Future<void> initializeBackgroundService() async {
  // The notification channel must exist *before* configure() runs — the
  // service crashes on startForeground() otherwise (posting to a channel
  // Android has never heard of throws CannotPostForegroundServiceNotificationException).
  const channel = AndroidNotificationChannel(
    trackingNotificationChannelId,
    'SmartSpend Tracking',
    description:
        'Shown while SmartSpend is tracking your location for budget alerts',
    importance: Importance.low,
  );
  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: trackingNotificationChannelId,
      initialNotificationTitle: 'SmartSpend',
      initialNotificationContent: 'Tracking your location for budget alerts',
      foregroundServiceTypes: const [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(),
  );
}

/// Runs in its own isolate/engine, independent of the main app UI. Bootstraps
/// the same singletons `main()` does, then reuses [LocationService] and
/// [AlertService] completely unmodified — neither depends on BuildContext or
/// Provider, so the exact same Algorithm 1/3 logic that used to run inside
/// the app's own process now runs here instead.
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  await dotenv.load(fileName: '.env');
  await LocalStorageService.instance.init();
  try {
    await Supabase.initialize(
      url: AppConstants.supabaseUrl,
      publishableKey: AppConstants.supabaseAnonKey,
    );
  } catch (_) {
    // Already initialized in this isolate (e.g. a hot restart) — ignore.
  }

  // A boot-triggered start shouldn't turn tracking on for a user who had it
  // off; only proceed if it was actually enabled before.
  if (!LocalStorageService.instance.trackingEnabled) {
    service.stopSelf();
    return;
  }

  final userId =
      Supabase.instance.client.auth.currentUser?.id ??
      LocalStorageService.instance.localUserId;

  await LocationService.instance.startTracking(userId);

  LocationService.instance.events.listen((event) async {
    service.invoke('locationEvent', {
      'type': event.type.name,
      'location': event.location?.toJson(),
      'dwellMinutes': event.dwellMinutes,
    });

    if (event.type == LocationEventType.entered ||
        event.type == LocationEventType.dwell) {
      final venue = event.location;
      if (venue != null) {
        await AlertService.instance.checkVenueAndAlert(userId, venue);
      }
    }
  });

  service.on('forcePoll').listen((_) {
    LocationService.instance.forcePoll(userId);
  });

  service.on('stopTracking').listen((_) {
    LocationService.instance.stopTracking();
    service.stopSelf();
  });
}

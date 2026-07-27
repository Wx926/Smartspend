import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'shared/constants/app_constants.dart';
import 'shared/services/background_location_service.dart';
import 'shared/services/local_storage_service.dart';
import 'features/alerts/services/alert_service.dart';
import 'features/reminders/services/meal_reminder_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: '.env');

  // Local storage must be ready before any provider reads it
  await LocalStorageService.instance.init();

  await Supabase.initialize(
    url: AppConstants.supabaseUrl,
    publishableKey: AppConstants.supabaseAnonKey,
  );

  await AlertService.instance.initNotifications();
  await initializeBackgroundService();
  // Fire-and-forget — schedules today's remaining meal reminders. Doesn't
  // block app start if this hits an issue (e.g. a locale/timezone quirk).
  MealReminderService.instance.rescheduleAll();

  runApp(const SmartSpendApp());
}

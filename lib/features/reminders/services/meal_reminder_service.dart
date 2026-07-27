import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../expenses/services/expense_service.dart';

class _MealSlot {
  final int id;
  final int hour;
  final int minute;
  final int windowStartHour;
  final int windowEndHour;
  final String title;
  final String body;

  const _MealSlot({
    required this.id,
    required this.hour,
    required this.minute,
    required this.windowStartHour,
    required this.windowEndHour,
    required this.title,
    required this.body,
  });
}

/// Scheduled breakfast/lunch/dinner nudges to log spending — unrelated to
/// Algorithm 1/3's location-triggered alerts. Each slot is scheduled one
/// occurrence at a time (never as an infinitely-repeating notification) so
/// that logging a matching expense can cancel just that one occurrence
/// without touching the next day's.
///
/// Relies on the app being opened at least once a day to keep the "next
/// occurrence" fresh (there's no server-side push channel in this project —
/// see Chapter 6 — so a reminder that's already fired can't be
/// auto-rescheduled for tomorrow until the app runs again).
class MealReminderService {
  MealReminderService._();
  static final MealReminderService instance = MealReminderService._();

  final _notifications = FlutterLocalNotificationsPlugin();
  final _store = LocalStorageService.instance;
  bool _tzInitialised = false;

  static const _slots = [
    _MealSlot(
      id: 900001,
      hour: 8,
      minute: 0,
      windowStartHour: 6,
      windowEndHour: 10,
      title: '🍳 Breakfast time',
      body: 'Remember to log your spending!',
    ),
    _MealSlot(
      id: 900002,
      hour: 12,
      minute: 0,
      windowStartHour: 11,
      windowEndHour: 14,
      title: '🍜 Lunch time',
      body: 'Remember to log your spending!',
    ),
    _MealSlot(
      id: 900003,
      hour: 18,
      minute: 0,
      windowStartHour: 17,
      windowEndHour: 20,
      title: '🍽️ Dinner time',
      body: 'Remember to log your spending!',
    ),
  ];

  /// Builds a fixed-offset Location from the device's current UTC offset
  /// rather than requiring a plugin to resolve the exact IANA zone name —
  /// avoids adding another native dependency just for this. Fine for a
  /// single-country target (Malaysia, UTC+8, no DST); falls back to UTC if
  /// the offset ever falls outside Etc/GMT's whole-hour range.
  Future<void> _ensureTz() async {
    if (_tzInitialised) return;
    tz_data.initializeTimeZones();
    final offsetHours = DateTime.now().timeZoneOffset.inMinutes / 60.0;
    final wholeHours = offsetHours.round();
    final name = wholeHours == 0
        ? 'UTC'
        : 'Etc/GMT${wholeHours > 0 ? '-$wholeHours' : '+${-wholeHours}'}';
    try {
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
    _tzInitialised = true;
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'smartspend_meal_reminders',
      'Meal Reminders',
      channelDescription: 'Reminders to log spending at meal times',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
    iOS: DarwinNotificationDetails(),
  );

  bool _alreadyLoggedToday(List<ExpenseModel> expenses, _MealSlot slot) {
    final now = DateTime.now();
    return expenses.any(
      (e) =>
          e.type == 'expense' &&
          !AppConstants.internalCategoryIds.contains(e.categoryId) &&
          e.date.year == now.year &&
          e.date.month == now.month &&
          e.date.day == now.day &&
          e.date.hour >= slot.windowStartHour &&
          e.date.hour < slot.windowEndHour,
    );
  }

  /// Ensures each of the 3 meal slots has exactly one upcoming occurrence
  /// scheduled (today's, or tomorrow's if today's time already passed) —
  /// unless a matching expense was already logged today, in which case
  /// today's occurrence is skipped. Call on app start and whenever the
  /// "Meal reminders" toggle is turned on.
  Future<void> rescheduleAll() async {
    if (!_store.mealRemindersEnabled) {
      await cancelAll();
      return;
    }
    await _ensureTz();
    List<ExpenseModel> expenses;
    try {
      expenses = await ExpenseService.instance.getExpenses();
    } catch (_) {
      expenses = const [];
    }
    final now = tz.TZDateTime.now(tz.local);

    for (final slot in _slots) {
      if (_alreadyLoggedToday(expenses, slot)) {
        await _notifications.cancel(slot.id);
        continue;
      }
      var when = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        slot.hour,
        slot.minute,
      );
      if (when.isBefore(now)) {
        when = when.add(const Duration(days: 1));
      }
      await _notifications.zonedSchedule(
        slot.id,
        slot.title,
        slot.body,
        when,
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: 'meal_reminder',
      );
    }
  }

  /// Cancels today's already-scheduled reminder for whichever meal window
  /// [expense] falls into — called right after a real expense is recorded
  /// so the reminder doesn't nag about something already logged.
  Future<void> onExpenseLogged(ExpenseModel expense) async {
    if (!_store.mealRemindersEnabled) return;
    if (expense.type != 'expense' ||
        AppConstants.internalCategoryIds.contains(expense.categoryId)) {
      return;
    }
    for (final slot in _slots) {
      if (expense.date.hour >= slot.windowStartHour &&
          expense.date.hour < slot.windowEndHour) {
        await _notifications.cancel(slot.id);
      }
    }
  }

  Future<void> cancelAll() async {
    for (final slot in _slots) {
      await _notifications.cancel(slot.id);
    }
  }
}

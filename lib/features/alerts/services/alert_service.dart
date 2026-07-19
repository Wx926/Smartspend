import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/alert_log_model.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/services/gemini_service.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/services/supabase_service.dart';
import '../../budget/services/budget_service.dart';
import '../../expenses/services/expense_service.dart';

/// Algorithm 3: Smart Alert Trigger.
///
/// Combines Algorithm 1 (a confirmed, non-routine venue visit) with
/// Algorithm 2 (budget forecast per category) to decide whether to notify
/// the user, at what severity, and with what content — enforcing a
/// per-venue cooldown to avoid notification fatigue.
class AlertService {
  AlertService._();
  static final AlertService instance = AlertService._();

  final _store = LocalStorageService.instance;
  final _supabase = SupabaseService.instance;
  final _gemini = GeminiService.instance;
  final _uuid = const Uuid();

  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsInitialised = false;
  int _notifId = 0;

  Future<void> initNotifications() async {
    if (_notificationsInitialised) return;
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
    _notificationsInitialised = true;

    // Android 13+ requires this runtime permission — declaring it in the
    // manifest alone isn't enough. Without this, every notification the app
    // tries to send is silently dropped by the OS, with no error anywhere
    // in the app's own logs.
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Local-first, same pattern as ExpenseService: read the cache instantly,
  /// only reach for Supabase when nothing has ever been cached locally (e.g.
  /// first run, or a different device/account).
  Future<List<AlertLogModel>> getAlerts() async {
    var alerts = _store.getAlerts();
    if (alerts.isEmpty && _supabase.isLoggedIn) {
      try {
        final cloud = await _supabase.getAlerts();
        if (cloud.isNotEmpty) {
          for (final a in cloud) {
            await _store.insertAlert(a);
          }
          alerts = _store.getAlerts();
        }
      } catch (_) {}
    }
    return alerts;
  }

  Future<void> markRead(String alertId) async {
    await _store.markAlertRead(alertId);
    if (_supabase.isLoggedIn) {
      _supabase.markAlertRead(alertId).catchError((_) {});
    }
  }

  Future<void> markAllRead() async {
    await _store.markAllAlertsRead();
    if (_supabase.isLoggedIn) {
      _supabase.markAllAlertsRead().catchError((_) {});
    }
  }

  /// Saves an alert locally (source of truth for the UI) and syncs it to
  /// Supabase in the background, best-effort.
  Future<void> _saveAlert(AlertLogModel alert) async {
    await _store.insertAlert(alert);
    if (_supabase.isLoggedIn) {
      _supabase.insertAlert(alert).catchError((_) => alert);
    }
  }

  /// Gathers categories/budgets/expenses itself (all plain singletons, no
  /// BuildContext/Provider needed) and runs [evaluateVenueVisit]. This is
  /// the entry point the background location service calls — it has no
  /// widget tree to read Providers from — and is also the single source of
  /// truth so the foreground app doesn't need its own duplicate wiring.
  Future<void> checkVenueAndAlert(String userId, LocationModel venue) async {
    try {
      final categories = _store.getCategories();
      final now = DateTime.now();
      final budgets = await BudgetService.instance.getBudgets(
        now.month,
        now.year,
      );
      final expenses = await ExpenseService.instance.getExpenses();
      final allStatuses = BudgetService.instance.computeBudgetStatuses(
        budgets: budgets,
        categories: categories,
        expenses: expenses,
        forMonth: now,
      );
      final venueExpenses = expenses
          .where((e) => e.locationId == venue.id)
          .toList();

      await evaluateVenueVisit(
        userId: userId,
        venue: venue,
        categories: categories,
        allStatuses: allStatuses,
        venueExpenses: venueExpenses,
      );
    } catch (_) {
      // Background isolate has no UI to surface this to — a transient
      // network failure here just means this poll cycle's check is skipped;
      // the next one retries.
    }
  }

  /// Core algorithm: called once a venue visit is confirmed (dwelled 15min,
  /// or manually force-refreshed) by Algorithm 1. Does nothing for routine
  /// venues (Algorithm 1 Step 3) or venues still in cooldown (Step 1).
  Future<void> evaluateVenueVisit({
    required String userId,
    required LocationModel venue,
    required List<CategoryModel> categories,
    required List<BudgetStatus> allStatuses,
    required List<ExpenseModel> venueExpenses,
  }) async {
    if (venue.effectiveIsRoutine) return;

    // Step 1: per-venue cooldown.
    final last = _store.getLastAlertForLocation(venue.id);
    if (last != null) {
      final hoursSince =
          DateTime.now().difference(last.createdAt).inMinutes / 60.0;
      if (hoursSince < AppConstants.alertCooldownHours) return;
    }

    // Step 7: hard daily cap — even with the cooldown, a very long stay
    // shouldn't produce unlimited repeat alerts for the same venue.
    final sentToday = _store.countAlertsForLocationSince(
      venue.id,
      DateTime.now().subtract(const Duration(hours: 12)),
    );
    if (sentToday >= AppConstants.maxAlertsPerVenuePerDay) return;

    // Step 2: the categories the user (or the OSM place-type guess) has
    // actually assigned to this venue — a mall can be tagged with several.
    if (venue.categoryIds.isEmpty) {
      // No category set at all (e.g. saved via "enter manually") — nothing
      // to check, but say so instead of staying silently unexplained.
      final title = '📍 ${venue.name}';
      const message =
          'No category set for this venue, so spending alerts can\'t run here yet. '
          'Set one from the Nearby screen\'s saved locations list.';
      final alert = AlertLogModel(
        id: _uuid.v4(),
        userId: userId,
        type: 'location',
        title: title,
        message: message,
        locationId: venue.id,
        createdAt: DateTime.now(),
      );
      await _saveAlert(alert);
      await _pushNotification(title, message, const Color(0xFF1976D2));
      return;
    }

    final relevant = allStatuses
        .where((s) => venue.categoryIds.contains(s.budget.categoryId))
        .toList();

    if (relevant.isEmpty) {
      // Recognizable spending categories, but no budget set for any of them
      // yet — nudge the user instead of staying completely silent.
      final categoryNames = venue.categoryIds
          .map((id) => categories.where((c) => c.id == id).firstOrNull?.name)
          .whereType<String>()
          .toList();
      final title = '📍 ${venue.name}';
      final message =
          'No ${categoryNames.join('/')} budget set yet. Set one to get spending warnings here.';
      final alert = AlertLogModel(
        id: _uuid.v4(),
        userId: userId,
        type: 'location',
        title: title,
        message: message,
        locationId: venue.id,
        createdAt: DateTime.now(),
      );
      await _saveAlert(alert);
      await _pushNotification(title, message, const Color(0xFF1976D2));
      return;
    }

    // Worst severity among the relevant categories decides the overall tier.
    final worst = relevant.reduce(
      (a, b) => _severityRank(b.severity) > _severityRank(a.severity) ? b : a,
    );

    String title;
    String message;
    String type;

    // Shown in every severity tier, not just green — the user should always
    // see the hard number their advice/warning is based on.
    final remainingLines = relevant
        .map(
          (s) => '${s.categoryName}: RM ${s.remaining.toStringAsFixed(2)} left',
        )
        .join('\n');

    if (worst.severity == AlertSeverity.green) {
      // Step 3: informational, no urgency, no AI call needed.
      type = 'green';
      title = '✅ ${venue.name}';
      message = remainingLines;
    } else {
      // Step 4-5: Caution/Critical — ask Gemini for a contextual warning.
      type = worst.severity == AlertSeverity.red ? 'red' : 'yellow';
      title = worst.severity == AlertSeverity.red
          ? '🔴 Budget Alert — ${venue.name}'
          : '⚠️ Spending Heads-Up — ${venue.name}';

      final categorySummary = relevant
          .map((s) {
            final depletion = s.daysUntilDepletion;
            final depletionNote = depletion == null
                ? ''
                : ', runs out in ${depletion.toStringAsFixed(1)} day(s) at current pace';
            return '- ${s.categoryName}: RM ${s.remaining.toStringAsFixed(2)} left '
                '(${_severityLabel(s.severity)}, projected RM ${s.projectedSpending.toStringAsFixed(2)} by month-end$depletionNote)';
          })
          .join('\n');

      final pastAmounts = venueExpenses.map((e) => e.amount).toList();
      final averageSpend = pastAmounts.isEmpty
          ? null
          : pastAmounts.reduce((a, b) => a + b) / pastAmounts.length;

      final now = DateTime.now();
      final daysLeftInMonth =
          DateTime(now.year, now.month + 1, 0).day - now.day;
      final overallBudgetRemaining = allStatuses.fold(
        0.0,
        (sum, s) => sum + s.remaining,
      );

      final advice = await _gemini.getVenueVisitAdvice(
        venueName: venue.name,
        categorySummary: categorySummary,
        overallBudgetRemaining: overallBudgetRemaining,
        daysLeftInMonth: daysLeftInMonth,
        averageSpendAtVenue: averageSpend,
        pastVisitCount: pastAmounts.length,
      );
      // Never present a fallback/error string as if it were personalized
      // AI advice — label it honestly when Gemini couldn't be reached.
      final adviceLine = advice.isFallback
          ? '⚠️ AI tip unavailable right now — general advice: ${advice.text}'
          : '💡 ${advice.text}';
      message = '$remainingLines\n$adviceLine';
    }

    final alert = AlertLogModel(
      id: _uuid.v4(),
      userId: userId,
      type: type,
      title: title,
      message: message,
      categoryId: worst.budget.categoryId,
      locationId: venue.id,
      createdAt: DateTime.now(),
    );

    await _saveAlert(alert);
    await _pushNotification(title, message, _severityColor(worst.severity));
  }

  int _severityRank(AlertSeverity s) => switch (s) {
    AlertSeverity.green => 0,
    AlertSeverity.yellow => 1,
    AlertSeverity.red => 2,
  };

  String _severityLabel(AlertSeverity s) => switch (s) {
    AlertSeverity.green => 'Safe',
    AlertSeverity.yellow => 'Caution',
    AlertSeverity.red => 'Critical',
  };

  Color _severityColor(AlertSeverity s) => switch (s) {
    AlertSeverity.green => const Color(0xFF2ECC71),
    AlertSeverity.yellow => const Color(0xFFF39C12),
    AlertSeverity.red => const Color(0xFFE74C3C),
  };

  Future<void> _pushNotification(String title, String body, Color color) async {
    await _notifications.show(
      _notifId++,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'smartspend_alerts',
          'SmartSpend Alerts',
          channelDescription: 'Budget and spending alerts',
          importance: Importance.high,
          priority: Priority.high,
          color: color,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
          actions: const [
            AndroidNotificationAction(
              'record_spending',
              'Record Spending',
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              'view_details',
              'View Details',
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  /// Routes a notification tap — whether on the body or on one of the two
  /// action buttons — since this runs outside the widget tree and has no
  /// BuildContext of its own to navigate with.
  void _onNotificationTap(NotificationResponse response) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (response.actionId == 'record_spending') {
      nav.pushNamed('/add-expense');
    } else {
      nav.pushNamed('/alerts');
    }
  }
}

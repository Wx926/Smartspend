import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/alert_log_model.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/services/gemini_service.dart';
import '../../../shared/services/local_storage_service.dart';

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
  final _gemini = GeminiService.instance;
  final _uuid = const Uuid();

  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsInitialised = false;
  int _notifId = 0;

  // Step 2: which budget categories are relevant at each type of venue.
  // A venue's categoryHint (set when it was saved) selects this list; a
  // mall checks both Shopping and Entertainment, a restaurant checks only
  // Food, etc. Unlisted hints just check their own name.
  static const Map<String, List<String>> _venueRelevantCategories = {
    'Food': ['Food'],
    'Shopping': ['Shopping', 'Entertainment'],
    'Entertainment': ['Entertainment', 'Shopping'],
    'Transport': ['Transport'],
    'Health': ['Health'],
    'Utilities': ['Utilities'],
  };

  Future<void> initNotifications() async {
    if (_notificationsInitialised) return;
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );
    _notificationsInitialised = true;
  }

  Future<List<AlertLogModel>> getAlerts() async => _store.getAlerts();

  Future<void> markRead(String alertId) => _store.markAlertRead(alertId);

  Future<void> markAllRead() => _store.markAllAlertsRead();

  /// Core algorithm: called once a venue visit is confirmed (dwelled 15min,
  /// or manually force-refreshed) by Algorithm 1. Does nothing for routine
  /// venues (Algorithm 1 Step 3) or venues still in cooldown (Step 1).
  Future<void> evaluateVenueVisit({
    required String userId,
    required LocationModel venue,
    required List<BudgetStatus> allStatuses,
    required List<ExpenseModel> venueExpenses,
  }) async {
    if (venue.isRoutine) return;

    // Step 1: per-venue cooldown.
    final last = _store.getLastAlertForLocation(venue.id);
    if (last != null) {
      final hoursSince = DateTime.now().difference(last.createdAt).inHours;
      if (hoursSince < AppConstants.alertCooldownHours) return;
    }

    // Step 2: only the categories relevant to this venue's type.
    final relevantNames =
        _venueRelevantCategories[venue.categoryHint] ??
        (venue.categoryHint != null ? [venue.categoryHint!] : const []);
    final relevant = relevantNames.isEmpty
        ? const <BudgetStatus>[]
        : allStatuses
              .where((s) => relevantNames.contains(s.categoryName))
              .toList();
    if (relevant.isEmpty) return;

    // Worst severity among the relevant categories decides the overall tier.
    final worst = relevant.reduce(
      (a, b) => _severityRank(b.severity) > _severityRank(a.severity) ? b : a,
    );

    String title;
    String message;
    String type;

    if (worst.severity == AlertSeverity.green) {
      // Step 3: informational, no urgency, no AI call needed.
      type = 'green';
      title = '✅ ${venue.name}';
      message = relevant
          .map(
            (s) =>
                '${s.categoryName}: RM ${s.remaining.toStringAsFixed(2)} left',
          )
          .join(' · ');
    } else {
      // Step 4-5: Caution/Critical — ask Gemini for a contextual warning.
      type = worst.severity == AlertSeverity.red ? 'red' : 'yellow';
      title = worst.severity == AlertSeverity.red
          ? '🔴 Budget Alert — ${venue.name}'
          : '⚠️ Spending Heads-Up — ${venue.name}';

      final categorySummary = relevant
          .map(
            (s) =>
                '- ${s.categoryName}: RM ${s.remaining.toStringAsFixed(2)} left '
                '(${_severityLabel(s.severity)}, projected RM ${s.projectedSpending.toStringAsFixed(2)} by month-end)',
          )
          .join('\n');

      final pastAmounts = venueExpenses.map((e) => e.amount).toList();
      final averageSpend = pastAmounts.isEmpty
          ? null
          : pastAmounts.reduce((a, b) => a + b) / pastAmounts.length;

      final advice = await _gemini.getVenueVisitAdvice(
        venueName: venue.name,
        categorySummary: categorySummary,
        averageSpendAtVenue: averageSpend,
        pastVisitCount: pastAmounts.length,
      );
      message = '💡 $advice';
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

    await _store.insertAlert(alert);
    await _pushNotification(title, message, worst.severity);
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

  Future<void> _pushNotification(
    String title,
    String body,
    AlertSeverity severity,
  ) async {
    final color = switch (severity) {
      AlertSeverity.green => const Color(0xFF2ECC71),
      AlertSeverity.yellow => const Color(0xFFF39C12),
      AlertSeverity.red => const Color(0xFFE74C3C),
    };
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
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }
}

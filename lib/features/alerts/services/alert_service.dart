import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/constants/app_constants.dart';
import '../../../shared/models/alert_log_model.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/services/gemini_service.dart';
import '../../../shared/services/local_storage_service.dart';

/// Algorithm 3: Smart Alert Trigger
class AlertService {
  AlertService._();
  static final AlertService instance = AlertService._();

  final _store = LocalStorageService.instance;
  final _gemini = GeminiService.instance;
  final _uuid = const Uuid();

  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsInitialised = false;
  int _notifId = 0;

  Future<void> initNotifications() async {
    if (_notificationsInitialised) return;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(
          android: androidSettings, iOS: iosSettings),
    );
    _notificationsInitialised = true;
  }

  Future<List<AlertLogModel>> getAlerts() async => _store.getAlerts();

  Future<void> markRead(String alertId) => _store.markAlertRead(alertId);

  Future<void> markAllRead() => _store.markAllAlertsRead();

  /// Core algorithm: evaluate budget status and fire alert if needed.
  Future<void> evaluateBudget({
    required String userId,
    required BudgetStatus status,
    String? locationName,
  }) async {
    if (status.severity == AlertSeverity.green) return;

    final last = _store.getLastAlertForCategory(status.budget.categoryId);
    if (last != null) {
      final hoursSince = DateTime.now().difference(last.createdAt).inHours;
      if (hoursSince < AppConstants.alertCooldownHours) return;
    }

    String title;
    String message;
    String type;

    if (status.severity == AlertSeverity.yellow) {
      type = 'yellow';
      title = '⚠️ Budget Warning — ${status.categoryName}';
      message =
          'You\'ve used ${(status.percentUsed * 100).toStringAsFixed(0)}% of your RM ${status.budget.amount.toStringAsFixed(2)} ${status.categoryName} budget. '
          'RM ${status.remaining.toStringAsFixed(2)} remaining this month.';
    } else {
      type = 'red';
      final overspend = status.spent - status.budget.amount;
      title = '🔴 Budget Exceeded — ${status.categoryName}';
      final aiAdvice = await _gemini.getBudgetOverrunAdvice(
        spent: status.spent,
        budgetAmount: status.budget.amount,
        categoryName: status.categoryName,
        locationName: locationName,
      );
      message =
          'You\'ve exceeded your ${status.categoryName} budget by RM ${overspend.toStringAsFixed(2)}.\n\n💡 $aiAdvice';
    }

    if (locationName != null) {
      type = 'location';
      title = '📍 Spending Alert at $locationName';
    }

    final alert = AlertLogModel(
      id: _uuid.v4(),
      userId: userId,
      type: type,
      title: title,
      message: message,
      categoryId: status.budget.categoryId,
      createdAt: DateTime.now(),
    );

    await _store.insertAlert(alert);
    await _pushNotification(title, message);
  }

  /// Fire a location-context alert when the user dwells at a known spending spot.
  Future<void> fireLocationAlert({
    required String userId,
    required String locationName,
    required String categoryName,
    required double budgetRemaining,
    required String budgetCategoryId,
  }) async {
    final last = _store.getLastAlertForCategory(budgetCategoryId);
    if (last != null) {
      final hoursSince = DateTime.now().difference(last.createdAt).inHours;
      if (hoursSince < AppConstants.alertCooldownHours) return;
    }

    final tip = await _gemini.getLocationSpendingTip(
      locationName: locationName,
      categoryName: categoryName,
      budgetRemaining: budgetRemaining,
    );

    const title = '📍 Spending Heads-Up!';
    final message =
        'You\'re at $locationName. RM ${budgetRemaining.toStringAsFixed(2)} left in your $categoryName budget.\n\n💡 $tip';

    final alert = AlertLogModel(
      id: _uuid.v4(),
      userId: userId,
      type: 'location',
      title: title,
      message: message,
      categoryId: budgetCategoryId,
      createdAt: DateTime.now(),
    );

    await _store.insertAlert(alert);
    await _pushNotification(title, message);
  }

  Future<void> _pushNotification(String title, String body) async {
    await _notifications.show(
      _notifId++,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'smartspend_alerts',
          'SmartSpend Alerts',
          channelDescription: 'Budget and spending alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}

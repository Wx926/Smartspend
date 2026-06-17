import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../features/alerts/services/alert_service.dart';
import '../../../shared/models/alert_log_model.dart';
import '../../../shared/theme/app_colors.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<AlertLogModel> _alerts = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _alerts = await AlertService.instance.getAlerts();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markAllRead() async {
    await AlertService.instance.markAllRead();
    setState(() {
      _alerts = _alerts.map((a) => a.markRead()).toList();
    });
  }

  Color _bgColor(String type) {
    switch (type) {
      case 'red':
        return AppColors.alertRedBg;
      case 'yellow':
        return AppColors.alertYellowBg;
      case 'location':
        return const Color(0xFFE3F2FD);
      default:
        return AppColors.alertGreenBg;
    }
  }

  Color _iconColor(String type) {
    switch (type) {
      case 'red':
        return AppColors.budgetRed;
      case 'yellow':
        return AppColors.budgetYellow;
      case 'location':
        return const Color(0xFF1976D2);
      default:
        return AppColors.budgetGreen;
    }
  }

  IconData _icon(String type) {
    switch (type) {
      case 'red':
        return Icons.warning_rounded;
      case 'yellow':
        return Icons.warning_amber_rounded;
      case 'location':
        return Icons.location_on;
      default:
        return Icons.check_circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = _alerts.where((a) => !a.isRead).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('Alerts${unread > 0 ? ' ($unread)' : ''}'),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: _markAllRead,
              child: const Text('Mark all read',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _alerts.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.notifications_off_outlined,
                          size: 64, color: AppColors.textSecondary),
                      SizedBox(height: 16),
                      Text('No alerts yet',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 16)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _alerts.length,
                    itemBuilder: (context, i) {
                      final alert = _alerts[i];
                      return _AlertCard(
                        alert: alert,
                        bgColor: _bgColor(alert.type),
                        iconColor: _iconColor(alert.type),
                        iconData: _icon(alert.type),
                        onTap: () async {
                          if (!alert.isRead) {
                            await AlertService.instance
                                .markRead(alert.id);
                            setState(() {
                              _alerts[i] = alert.markRead();
                            });
                          }
                          if (context.mounted) {
                            _showAlertDetail(context, alert);
                          }
                        },
                      );
                    },
                  ),
                ),
    );
  }

  void _showAlertDetail(BuildContext context, AlertLogModel alert) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(alert.title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              DateFormat('d MMM yyyy, h:mm a').format(alert.createdAt),
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Text(alert.message,
                style: const TextStyle(fontSize: 15, height: 1.6)),
          ],
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlertLogModel alert;
  final Color bgColor;
  final Color iconColor;
  final IconData iconData;
  final VoidCallback onTap;

  const _AlertCard({
    required this.alert,
    required this.bgColor,
    required this.iconColor,
    required this.iconData,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: alert.isRead ? Colors.white : bgColor,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.15),
          child: Icon(iconData, color: iconColor, size: 22),
        ),
        title: Text(
          alert.title,
          style: TextStyle(
            fontWeight:
                alert.isRead ? FontWeight.normal : FontWeight.bold,
            fontSize: 14,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              alert.message.split('\n').first,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('d MMM, h:mm a').format(alert.createdAt),
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
        trailing: alert.isRead
            ? null
            : Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              ),
        onTap: onTap,
      ),
    );
  }
}

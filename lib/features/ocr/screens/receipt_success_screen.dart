import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/budget_model.dart';

/// Confirmation screen shown right after a receipt scan, PDF upload, or
/// voice-entered expense is saved — every field here is the actual data just
/// written to the database (merchant/amount/category/date) plus the
/// recomputed post-save budget status, never placeholder/hardcoded values.
class ReceiptSuccessScreen extends StatelessWidget {
  final String? merchantName;
  final double amount;
  final String categoryName;
  final String categoryIcon;
  final DateTime date;
  final String method;
  /// Null when the category has no budget set for this month — the budget
  /// card is simply omitted in that case rather than showing fake numbers.
  final BudgetStatus? budgetStatus;
  /// True when this confirms edits to a previously saved receipt/voice entry
  /// rather than a brand-new scan — swaps the headline copy accordingly.
  final bool isEdit;

  const ReceiptSuccessScreen({
    super.key,
    required this.merchantName,
    required this.amount,
    required this.categoryName,
    required this.categoryIcon,
    required this.date,
    required this.method,
    required this.budgetStatus,
    this.isEdit = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF5EF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.budgetGreen, width: 3),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppColors.budgetGreen,
                  size: 44,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isEdit ? 'Changes Saved!' : 'Expense Saved!',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.budgetGreen,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isEdit
                    ? 'Your changes have been saved and\nyour budget has been updated.'
                    : 'Your expense has been logged and\nyour budget has been updated.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),
              _detailsCard(),
              if (budgetStatus != null) ...[
                const SizedBox(height: 14),
                _budgetCard(budgetStatus!),
              ],
              const Spacer(),
              _buttons(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailsCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            _row(
              'Merchant',
              (merchantName?.trim().isNotEmpty ?? false) ? merchantName! : '—',
            ),
            const SizedBox(height: 12),
            _row('Amount', 'RM ${amount.toStringAsFixed(2)}',
                valueColor: AppColors.primaryDark, bold: true),
            const SizedBox(height: 12),
            _row('Category', '$categoryIcon $categoryName'),
            const SizedBox(height: 12),
            _row('Date', DateFormat('dd MMM yyyy').format(date)),
            const SizedBox(height: 12),
            _row('Method', '${_methodIcon(method)} $method'),
          ],
        ),
      );

  String _methodIcon(String method) {
    switch (method) {
      case 'Voice Input':
        return '🎤';
      case 'PDF Upload':
        return '📄';
      default:
        return '🧾';
    }
  }

  Widget _row(String label, String value, {Color? valueColor, bool bold = false}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: bold ? 16 : 14,
                fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      );

  Widget _budgetCard(BudgetStatus status) {
    final progressColor = switch (status.severity) {
      AlertSeverity.red => AppColors.budgetRed,
      AlertSeverity.yellow => AppColors.budgetYellow,
      AlertSeverity.green => AppColors.budgetGreen,
    };
    final remaining = status.remaining.clamp(0.0, double.infinity);
    final percent = status.budget.amount > 0
        ? (status.spent / status.budget.amount).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Updated $categoryName Budget',
            style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.primaryDark),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('RM ${status.spent.toStringAsFixed(2)} spent',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              Text('RM ${remaining.toStringAsFixed(2)} left',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 8,
              backgroundColor: Colors.white,
              valueColor: AlwaysStoppedAnimation(progressColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buttons(BuildContext context) => Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryDark,
                side: const BorderSide(color: AppColors.primaryDark),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(isEdit ? 'Back to History' : '+ Add More'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.popUntil(context, (r) => r.isFirst),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryDark,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Go Home'),
            ),
          ),
        ],
      );
}

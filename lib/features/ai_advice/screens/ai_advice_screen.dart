import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/services/gemini_service.dart';
import '../../../shared/theme/app_colors.dart';

class AiAdviceScreen extends StatefulWidget {
  const AiAdviceScreen({super.key});

  @override
  State<AiAdviceScreen> createState() => _AiAdviceScreenState();
}

class _AiAdviceScreenState extends State<AiAdviceScreen> {
  String? _greeting;
  bool _loadingGreeting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGreeting());
  }

  Future<void> _loadGreeting() async {
    if (_loaded) return;
    final bp = context.read<BudgetProvider>();
    final ep = context.read<ExpenseProvider>();
    final now = DateTime.now();
    final statuses = bp.statuses;

    setState(() => _loadingGreeting = true);

    if (statuses.isNotEmpty) {
      final topStatus = statuses.reduce((a, b) => a.spent > b.spent ? a : b);
      final insight = await GeminiService.instance.getMonthlySummaryInsight(
        totalSpent: ep.forMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount),
        totalBudget: bp.totalBudget,
        topCategory: topStatus.categoryName,
        topCategorySpent: topStatus.spent,
        month: DateFormat('MMMM yyyy').format(now),
      );
      if (mounted) setState(() => _greeting = insight);
    } else {
      if (mounted) {
        setState(() =>
            _greeting = 'Add some expenses and set budgets to get personalised AI advice!');
      }
    }

    if (mounted) setState(() { _loadingGreeting = false; _loaded = true; });
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    final statuses = bp.statuses;

    final criticals = statuses.where((s) => s.severity == AlertSeverity.red).toList();
    final warnings = statuses.where((s) => s.severity == AlertSeverity.yellow).toList();
    final onTrack = statuses.where((s) => s.severity == AlertSeverity.green).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildHeader(),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildGreetingBubble(),
                const SizedBox(height: 24),
                const Text('This week\'s insights',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                ...criticals.map((s) => _InsightCard(
                      badge: 'Critical',
                      badgeColor: AppColors.budgetRed,
                      title: '${s.categoryName} nearly exhausted',
                      body:
                          'Only RM ${s.remaining.toStringAsFixed(0)} left with ${_daysLeft()} days to go. Consider cutting back.',
                    )),
                ...warnings.map((s) => _InsightCard(
                      badge: 'Warning',
                      badgeColor: AppColors.budgetYellow,
                      title: '${s.categoryName} spending rising',
                      body:
                          'You\'ve used ${(s.percentUsed * 100).toStringAsFixed(0)}% of your RM ${s.budget.amount.toStringAsFixed(0)} ${s.categoryName} budget.',
                    )),
                ...onTrack.map((s) => _InsightCard(
                      badge: 'Good job',
                      badgeColor: AppColors.budgetGreen,
                      title: '${s.categoryName} spending on track',
                      body:
                          '${(s.percentUsed * 100).toStringAsFixed(0)}% used at the midpoint. Keep this pace!',
                    )),
                if (statuses.isEmpty)
                  _InsightCard(
                    badge: 'Tip',
                    badgeColor: AppColors.primary,
                    title: 'Set your first budget',
                    body: 'Go to the Home screen → Budget Overview to set monthly category budgets.',
                  ),
                const SizedBox(height: 80),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return SliverAppBar(
      expandedHeight: 110,
      pinned: true,
      backgroundColor: AppColors.primaryDark,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.primaryDark, AppColors.primary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(20, 52, 20, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('AI Financial Advisor',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 2),
                    Text('Powered by Gemini AI',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white38),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Color(0xFF4ADE80), size: 8),
                    SizedBox(width: 4),
                    Text('LIVE',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGreetingBubble() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.amber, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _loadingGreeting
                ? const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                        color: Colors.white54, backgroundColor: Colors.white24),
                  )
                : Text(
                    _greeting ?? 'Analysing your spending patterns...',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, height: 1.5),
                  ),
          ),
        ],
      ),
    );
  }

  int _daysLeft() {
    final now = DateTime.now();
    return DateTime(now.year, now.month + 1, 0).day - now.day;
  }
}

class _InsightCard extends StatelessWidget {
  final String badge;
  final Color badgeColor;
  final String title;
  final String body;

  const _InsightCard({
    required this.badge,
    required this.badgeColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      badge == 'Good job'
                          ? Icons.check_circle_outline
                          : badge == 'Warning'
                              ? Icons.warning_amber_outlined
                              : badge == 'Tip'
                                  ? Icons.lightbulb_outline
                                  : Icons.circle,
                      color: badgeColor,
                      size: 12,
                    ),
                    const SizedBox(width: 4),
                    Text(badge,
                        style: TextStyle(
                            color: badgeColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(body,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
}

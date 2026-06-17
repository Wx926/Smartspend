import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../shared/theme/app_colors.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _touchedIndex = -1;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final ep = context.read<ExpenseProvider>();
    final bp = context.read<BudgetProvider>();
    await ep.load();
    bp.setMonth(_month);
    await bp.load(ep.forMonth(_month.month, _month.year));
  }

  void _prevMonth() {
    setState(() => _month = DateTime(_month.year, _month.month - 1));
    _reload();
  }

  void _nextMonth() {
    final now = DateTime.now();
    if (_month.year == now.year && _month.month == now.month) return;
    setState(() => _month = DateTime(_month.year, _month.month + 1));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    final ep = context.watch<ExpenseProvider>();
    final totalSpent =
        ep.forMonth(_month.month, _month.year).fold(0.0, (s, e) => s + e.amount);
    final fmt = NumberFormat('#,##0', 'en_MY');
    final isCurrent = _month.year == DateTime.now().year &&
        _month.month == DateTime.now().month;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverAppBar(
            expandedHeight: 175,
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primaryDark, AppColors.primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Column(children: [
                    const SizedBox(height: 6),
                    const Text('Spending Analytics',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                          icon: const Icon(Icons.chevron_left, color: Colors.white70),
                          onPressed: _prevMonth),
                      Text(DateFormat('MMMM yyyy').format(_month),
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      IconButton(
                          icon: Icon(Icons.chevron_right,
                              color: isCurrent ? Colors.white30 : Colors.white70),
                          onPressed: isCurrent ? null : _nextMonth),
                    ]),
                    Text('Total spent',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Text('RM ${fmt.format(totalSpent)}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold)),
                    if (bp.totalBudget > 0)
                      Text('of RM ${fmt.format(bp.totalBudget)} budget',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                  ]),
                ),
              ),
            ),
            bottom: TabBar(
              controller: _tabs,
              indicatorColor: Colors.white,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              tabs: const [Tab(text: 'Expenses'), Tab(text: 'Income'), Tab(text: 'Forecast')],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: [
            _buildExpenses(bp, ep, fmt),
            _buildIncome(),
            _buildForecast(bp),
          ],
        ),
      ),
    );
  }

  Widget _buildExpenses(BudgetProvider bp, ExpenseProvider ep, NumberFormat fmt) {
    final statuses = bp.statuses.where((s) => s.spent > 0).toList();
    if (statuses.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.bar_chart, size: 56, color: AppColors.textSecondary),
        SizedBox(height: 12),
        Text('No expenses this month', style: TextStyle(color: AppColors.textSecondary)),
      ]));
    }

    final total = statuses.fold(0.0, (s, e) => s + e.spent);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      children: [
        SizedBox(
          height: 220,
          child: Stack(alignment: Alignment.center, children: [
            PieChart(PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (event, response) => setState(() =>
                    _touchedIndex =
                        response?.touchedSection?.touchedSectionIndex ?? -1),
              ),
              sections: statuses.asMap().entries.map((entry) {
                final i = entry.key;
                final s = entry.value;
                final touched = i == _touchedIndex;
                return PieChartSectionData(
                  value: s.spent,
                  color: AppColors.fromHex(s.categoryColorHex),
                  radius: touched ? 72 : 58,
                  title: '',
                  badgeWidget: touched
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                              color: AppColors.fromHex(s.categoryColorHex),
                              borderRadius: BorderRadius.circular(6)),
                          child: Text('RM ${fmt.format(s.spent)}',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        )
                      : null,
                  badgePositionPercentageOffset: 1.3,
                );
              }).toList(),
              sectionsSpace: 3,
              centerSpaceRadius: 52,
            )),
            Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('RM', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              Text(fmt.format(total), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
            ]),
          ]),
        ),
        const SizedBox(height: 20),
        ...statuses.map((s) {
          final pct = total > 0 ? s.spent / total * 100 : 0.0;
          final color = AppColors.fromHex(s.categoryColorHex);
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Text(s.categoryName, style: const TextStyle(fontSize: 14))),
              Text('${pct.toStringAsFixed(0)}%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(width: 16),
              Text('RM ${fmt.format(s.spent)}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          );
        }),
      ],
    );
  }

  Widget _buildIncome() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.account_balance_wallet_outlined, size: 56, color: AppColors.textSecondary),
      SizedBox(height: 12),
      Text('Income tracking coming soon', style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
    ]),
  );

  Widget _buildForecast(BudgetProvider bp) {
    if (bp.statuses.isEmpty) {
      return const Center(child: Text('Set budgets to see forecast', style: TextStyle(color: AppColors.textSecondary)));
    }
    final now = DateTime.now();
    final daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day;
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      children: [
        Text('$daysLeft days remaining this month',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const SizedBox(height: 12),
        ...bp.statuses.map((s) {
          final projColor = s.projectedSpending > s.budget.amount
              ? AppColors.budgetRed
              : AppColors.budgetGreen;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Text(s.categoryIcon, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.categoryName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                Text('RM ${fmt.format(s.dailyBurnRate)}/day · Projected: RM ${fmt.format(s.projectedSpending)}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: projColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(s.projectedSpending > s.budget.amount ? 'Over' : 'On track',
                    style: TextStyle(color: projColor, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ]),
          );
        }),
      ],
    );
  }
}

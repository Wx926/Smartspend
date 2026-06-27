import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../features/location/providers/location_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../../analytics/screens/analytics_screen.dart';
import '../../location/screens/location_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Transaction filter state
  DateTime _txStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _txEnd = DateTime.now();
  String _filterLabel = 'This Month';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final ep = context.read<ExpenseProvider>();
    final bp = context.read<BudgetProvider>();
    await ep.load();
    final now = DateTime.now();
    await bp.load(ep.expensesForMonth(now.month, now.year));
  }

  void _prevMonth() {
    setState(() {
      _txStart = DateTime(_txStart.year, _txStart.month - 1, 1);
      _txEnd = DateTime(_txStart.year, _txStart.month + 1, 0);
      _filterLabel = DateFormat('MMM yyyy').format(_txStart);
    });
  }

  void _nextMonth() {
    final now = DateTime.now();
    final nextStart = DateTime(_txStart.year, _txStart.month + 1, 1);
    if (nextStart.isAfter(DateTime(now.year, now.month, 1))) return;
    setState(() {
      _txStart = nextStart;
      _txEnd = nextStart.month == now.month && nextStart.year == now.year
          ? now
          : DateTime(nextStart.year, nextStart.month + 1, 0);
      _filterLabel = nextStart.month == now.month && nextStart.year == now.year
          ? 'This Month'
          : DateFormat('MMM yyyy').format(nextStart);
    });
  }

  void _showFilterSheet() {
    final now = DateTime.now();
    final presets = [
      {'label': 'Last 7 days', 'start': now.subtract(const Duration(days: 6)), 'end': now},
      {'label': 'This Month', 'start': DateTime(now.year, now.month, 1), 'end': now},
      {'label': 'Last Month', 'start': DateTime(now.year, now.month - 1, 1), 'end': DateTime(now.year, now.month, 0)},
      {'label': 'Last 3 Months', 'start': DateTime(now.year, now.month - 2, 1), 'end': now},
      {'label': 'Last 6 Months', 'start': DateTime(now.year, now.month - 5, 1), 'end': now},
      {'label': 'Last Year', 'start': DateTime(now.year - 1, now.month, 1), 'end': now},
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Filter Period',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ...presets.map((p) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(p['label'] as String),
                  trailing: _filterLabel == p['label']
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () {
                    setState(() {
                      _txStart = p['start'] as DateTime;
                      _txEnd = p['end'] as DateTime;
                      _filterLabel = p['label'] as String;
                    });
                    Navigator.pop(ctx);
                  },
                )),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Custom Range'),
              trailing: const Icon(Icons.calendar_month_outlined,
                  color: AppColors.primary, size: 20),
              onTap: () async {
                Navigator.pop(ctx);
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: now,
                  initialDateRange: DateTimeRange(start: _txStart, end: _txEnd),
                  builder: (context, child) => Theme(
                    data: Theme.of(context).copyWith(
                        colorScheme: const ColorScheme.light(
                            primary: AppColors.primary)),
                    child: child!,
                  ),
                );
                if (range != null) {
                  setState(() {
                    _txStart = range.start;
                    _txEnd = range.end;
                    _filterLabel =
                        '${DateFormat('d MMM').format(range.start)} – ${DateFormat('d MMM yyyy').format(range.end)}';
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    if (parts[0].isNotEmpty) {
      return parts[0].substring(0, parts[0].length.clamp(0, 2)).toUpperCase();
    }
    return 'SS';
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ep = context.watch<ExpenseProvider>();
    final bp = context.watch<BudgetProvider>();
    final lp = context.watch<LocationProvider>();
    final now = DateTime.now();
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    final totalSpent = ep.expensesForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount);
    final totalIncome = ep.incomeForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount);
    final totalBudget = bp.totalBudget;
    final remaining = (totalBudget - totalSpent).clamp(0.0, double.infinity);
    final daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day;
    final displayName = auth.displayName.isEmpty ? 'Guest' : auth.displayName;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            // ── Green header ─────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primaryDark, AppColors.primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_greeting(),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                                Text(displayName,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                            GestureDetector(
                              onTap: () =>
                                  Navigator.pushNamed(context, '/profile'),
                              child: CircleAvatar(
                                radius: 22,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.25),
                                child: Text(_initials(displayName),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        // Budget summary card
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Total remaining budget',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                              const SizedBox(height: 4),
                              Text('RM ${fmt.format(remaining)}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 34,
                                      fontWeight: FontWeight.bold)),
                              Text(
                                totalBudget > 0
                                    ? 'of RM ${fmt.format(totalBudget)} monthly budget'
                                    : 'No budget set yet',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                              const SizedBox(height: 16),
                              Row(children: [
                                _StatChip(
                                    label: 'Spent',
                                    value: 'RM ${fmt.format(totalSpent)}'),
                                const SizedBox(width: 10),
                                _StatChip(
                                    label: 'Income',
                                    value: 'RM ${fmt.format(totalIncome)}'),
                                const SizedBox(width: 10),
                                _StatChip(
                                    label: 'Days left', value: '$daysLeft'),
                              ]),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── Location alert banner ─────────────────────────────────────
            if (lp.activeLocation != null)
              SliverToBoxAdapter(
                child: GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(
                          builder: (_) => const LocationScreen())),
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 6,
                            offset: const Offset(0, 2))
                      ],
                    ),
                    child: Row(children: [
                      const Icon(Icons.circle,
                          color: Color(0xFFF39C12), size: 10),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Location alert — ${lp.activeLocation!.name}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              Text(
                                  '${lp.activeDwellMinutes} min · Tap to view',
                                  style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 11)),
                            ]),
                      ),
                      const Icon(Icons.chevron_right,
                          color: AppColors.textSecondary, size: 18),
                    ]),
                  ),
                ),
              ),

            // ── Quick actions ─────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(children: [
                  Expanded(
                      child: _QuickAction(
                          icon: Icons.add,
                          label: 'Add Record',
                          filled: true,
                          onTap: () =>
                              Navigator.pushNamed(context, '/add-expense'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _QuickAction(
                          icon: Icons.bar_chart_outlined,
                          label: 'Analytics',
                          filled: false,
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const AnalyticsScreen())))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _QuickAction(
                          icon: Icons.auto_awesome_outlined,
                          label: 'AI Advice',
                          filled: false,
                          onTap: () =>
                              Navigator.pushNamed(context, '/ai-advice'))),
                ]),
              ),
            ),

            // ── Budget overview ────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Budget Overview',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      TextButton(
                          onPressed: () =>
                              Navigator.pushNamed(context, '/budget'),
                          child: const Text('See All')),
                    ]),
              ),
            ),

            bp.statuses.isEmpty
                ? SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14)),
                        child: Column(children: [
                          const Icon(Icons.pie_chart_outline,
                              size: 48, color: AppColors.textSecondary),
                          const SizedBox(height: 8),
                          const Text('No budgets set yet',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text(
                              'Set monthly budgets to track your spending',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                          const SizedBox(height: 12),
                          ElevatedButton(
                              onPressed: () =>
                                  Navigator.pushNamed(context, '/budget'),
                              child: const Text('Set Budget')),
                        ]),
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                        (_, i) => _BudgetCard(status: bp.statuses[i]),
                        childCount: bp.statuses.length)),

            // ── Transactions header with month nav + filter ───────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Row(children: [
                  const Text('Transactions',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.chevron_left,
                        color: AppColors.textSecondary, size: 22),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _prevMonth,
                  ),
                  GestureDetector(
                    onTap: _showFilterSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(_filterLabel,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right,
                        color: AppColors.textSecondary, size: 22),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _nextMonth,
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: _showFilterSheet,
                    child: const Icon(Icons.tune,
                        color: AppColors.primary, size: 20),
                  ),
                ]),
              ),
            ),

            // ── Period income/expense summary ─────────────────────────────
            SliverToBoxAdapter(
              child: Builder(builder: (context) {
                final periodTx = ep.expenses.where((e) =>
                    !e.date.isBefore(_txStart) &&
                    !e.date.isAfter(_txEnd)).toList();
                final periodIncome = periodTx
                    .where((e) => e.type == 'income')
                    .fold(0.0, (s, e) => s + e.amount);
                final periodExpense = periodTx
                    .where((e) => e.type == 'expense')
                    .fold(0.0, (s, e) => s + e.amount);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(children: [
                    _PeriodStat(
                        label: 'Income',
                        value: '+RM ${fmt.format(periodIncome)}',
                        color: AppColors.budgetGreen),
                    const SizedBox(width: 10),
                    _PeriodStat(
                        label: 'Expenses',
                        value: '-RM ${fmt.format(periodExpense)}',
                        color: AppColors.budgetRed),
                  ]),
                );
              }),
            ),

            // ── Transaction list for selected period ──────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              sliver: Builder(builder: (context) {
                final allCats = [...bp.categories, ...bp.incomeCategories];
                final periodTx = ep.expenses
                    .where((e) =>
                        !e.date.isBefore(_txStart) &&
                        !e.date.isAfter(_txEnd))
                    .toList();

                if (periodTx.isEmpty) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('No transactions in this period',
                            style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 14)),
                      ),
                    ),
                  );
                }

                // Group by date
                final byDate = <String, List<dynamic>>{};
                for (final e in periodTx) {
                  final key = DateFormat('d MMM yyyy').format(e.date);
                  byDate.putIfAbsent(key, () => []).add(e);
                }

                final days = byDate.keys.toList();
                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, di) {
                      final dayKey = days[di];
                      final dayTx = byDate[dayKey]!;
                      final dayIncome = dayTx
                          .where((e) => e.type == 'income')
                          .fold(0.0, (s, e) => s + e.amount);
                      final dayExpense = dayTx
                          .where((e) => e.type == 'expense')
                          .fold(0.0, (s, e) => s + e.amount);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Day header
                          Padding(
                            padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
                            child: Row(children: [
                              Text(dayKey,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textSecondary)),
                              const Spacer(),
                              if (dayIncome > 0)
                                Text('+RM ${fmt.format(dayIncome)}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.budgetGreen,
                                        fontWeight: FontWeight.w500)),
                              if (dayIncome > 0 && dayExpense > 0)
                                const SizedBox(width: 8),
                              if (dayExpense > 0)
                                Text('-RM ${fmt.format(dayExpense)}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.budgetRed,
                                        fontWeight: FontWeight.w500)),
                            ]),
                          ),
                          // Transactions for this day
                          ...dayTx.map((e) {
                            final cat = allCats
                                .where((c) => c.id == e.categoryId)
                                .firstOrNull;
                            final col = AppColors.fromHex(
                                cat?.colorHex ?? '6B7280');
                            final isIncome = e.type == 'income';
                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12)),
                              child: Row(children: [
                                CircleAvatar(
                                    radius: 20,
                                    backgroundColor:
                                        col.withValues(alpha: 0.15),
                                    child: Text(
                                        cat?.icon ??
                                            (isIncome ? '💰' : '📦'),
                                        style: const TextStyle(
                                            fontSize: 16))),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(
                                          e.description.isEmpty
                                              ? (cat?.name ??
                                                  (isIncome
                                                      ? 'Income'
                                                      : 'Expense'))
                                              : e.description,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14)),
                                      Text(cat?.name ?? '',
                                          style: const TextStyle(
                                              color:
                                                  AppColors.textSecondary,
                                              fontSize: 12)),
                                    ])),
                                Text(
                                    isIncome
                                        ? '+RM ${e.amount.toStringAsFixed(2)}'
                                        : '-RM ${e.amount.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        color: isIncome
                                            ? AppColors.budgetGreen
                                            : AppColors.budgetRed,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                              ]),
                            );
                          }),
                        ],
                      );
                    },
                    childCount: days.length,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _PeriodStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _PeriodStat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(color: color, fontSize: 11)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ]),
        ),
      );
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(label,
                style:
                    const TextStyle(color: Colors.white60, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
          ]),
        ),
      );
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _QuickAction(
      {required this.icon,
      required this.label,
      required this.filled,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: filled ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border:
                filled ? null : Border.all(color: const Color(0xFFE0E0E0)),
            boxShadow: filled
                ? [
                    BoxShadow(
                        color:
                            AppColors.primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3))
                  ]
                : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: filled ? Colors.white : AppColors.primary,
                size: 22),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    color: filled
                        ? Colors.white
                        : AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
          ]),
        ),
      );
}

class _BudgetCard extends StatelessWidget {
  final BudgetStatus status;
  const _BudgetCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0', 'en_MY');
    final color = status.severity == AlertSeverity.red
        ? AppColors.budgetRed
        : status.severity == AlertSeverity.yellow
            ? AppColors.budgetYellow
            : AppColors.budgetGreen;
    final pct = status.percentUsed.clamp(0.0, 1.0);
    final lbl = status.severity == AlertSeverity.red
        ? 'Running low'
        : status.severity == AlertSeverity.yellow
            ? 'Getting high'
            : '✓ On track';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2))
          ]),
      child: Column(children: [
        Row(children: [
          Text(status.categoryIcon,
              style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(status.categoryName,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14))),
          Text(
              'RM ${fmt.format(status.spent)} / RM ${fmt.format(status.budget.amount)}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: pct,
                backgroundColor: color.withValues(alpha: 0.12),
                color: color,
                minHeight: 7)),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
          Text(lbl,
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          Text('${(pct * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
        ]),
      ]),
    );
  }
}

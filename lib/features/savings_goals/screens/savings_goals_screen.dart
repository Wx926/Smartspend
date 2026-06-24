import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../providers/savings_goal_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';

class SavingsGoalsScreen extends StatefulWidget {
  const SavingsGoalsScreen({super.key});

  @override
  State<SavingsGoalsScreen> createState() => _SavingsGoalsScreenState();
}

class _SavingsGoalsScreenState extends State<SavingsGoalsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<SavingsGoalProvider>().load());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SavingsGoalProvider>();
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Savings Goals'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showGoalSheet(context),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : provider.goals.isEmpty
              ? _emptyState()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Summary card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.primaryDark,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _summaryItem('Total Saved',
                              'RM ${fmt.format(provider.totalSaved)}'),
                          Container(
                              width: 1, height: 40, color: Colors.white24),
                          _summaryItem('Total Target',
                              'RM ${fmt.format(provider.totalTarget)}'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...provider.goals
                        .map((g) => _goalCard(context, g, fmt)),
                    const SizedBox(height: 80),
                  ],
                ),
    );
  }

  Widget _summaryItem(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ],
      );

  Widget _emptyState() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.track_changes_outlined,
                size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('No savings goals yet',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('Tap + to create your first goal',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );

  Widget _goalCard(
      BuildContext context, SavingsGoalModel goal, NumberFormat fmt) {
    final pct = (goal.progress * 100).toStringAsFixed(0);
    final remaining = goal.targetAmount - goal.currentAmount;
    final isComplete = goal.isCompleted || goal.progress >= 1.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(goal.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              if (isComplete)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.budgetGreen.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('Completed',
                      style: TextStyle(
                          color: AppColors.budgetGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'add') _showAddFundsSheet(context, goal, fmt);
                  if (v == 'edit') _showGoalSheet(context, goal: goal);
                  if (v == 'delete') _confirmDelete(context, goal);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'add', child: Text('Add funds')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(
                      value: 'delete',
                      child:
                          Text('Delete', style: TextStyle(color: Colors.red))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('RM ${fmt.format(goal.currentAmount)}',
                  style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14)),
              Text('RM ${fmt.format(goal.targetAmount)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: goal.progress,
              minHeight: 8,
              backgroundColor: AppColors.textSecondary.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(
                  isComplete ? AppColors.budgetGreen : AppColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$pct% reached',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              if (!isComplete)
                Text('RM ${fmt.format(remaining)} to go',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              if (goal.deadline != null)
                Text(
                    'Due ${DateFormat('d MMM yyyy').format(goal.deadline!)}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  void _showGoalSheet(BuildContext context, {SavingsGoalModel? goal}) {
    final nameCtrl = TextEditingController(text: goal?.name ?? '');
    final targetCtrl = TextEditingController(
        text: goal != null ? goal.targetAmount.toStringAsFixed(2) : '');
    final currentCtrl = TextEditingController(
        text: goal != null ? goal.currentAmount.toStringAsFixed(2) : '');
    DateTime? deadline = goal?.deadline;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(goal == null ? 'New Savings Goal' : 'Edit Goal',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Goal name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: targetCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Target amount (RM)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currentCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Current amount (RM)'),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: deadline ?? DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (picked != null) {
                    setSheetState(() => deadline = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_outlined,
                          size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(
                        deadline != null
                            ? 'Deadline: ${DateFormat('d MMM yyyy').format(deadline!)}'
                            : 'Set deadline (optional)',
                        style: TextStyle(
                            color: deadline != null
                                ? AppColors.textPrimary
                                : AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final target = double.tryParse(targetCtrl.text) ?? 0;
                    final current = double.tryParse(currentCtrl.text) ?? 0;
                    if (name.isEmpty || target <= 0) return;

                    final provider = context.read<SavingsGoalProvider>();
                    final auth = context.read<AuthProvider>();

                    if (goal == null) {
                      await provider.add(SavingsGoalModel(
                        id: '',
                        userId: auth.userId,
                        name: name,
                        targetAmount: target,
                        currentAmount: current,
                        deadline: deadline,
                        createdAt: DateTime.now(),
                      ));
                    } else {
                      await provider.update(goal.copyWith(
                        name: name,
                        targetAmount: target,
                        currentAmount: current,
                        deadline: deadline,
                        clearDeadline: deadline == null,
                      ));
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(goal == null ? 'Create Goal' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddFundsSheet(
      BuildContext context, SavingsGoalModel goal, NumberFormat fmt) {
    final amountCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add Funds to "${goal.name}"',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            Text('Current: RM ${fmt.format(goal.currentAmount)}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: amountCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount to add (RM)'),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final amount = double.tryParse(amountCtrl.text) ?? 0;
                  if (amount <= 0) return;
                  final newAmount = goal.currentAmount + amount;
                  await context.read<SavingsGoalProvider>().update(
                        goal.copyWith(
                          currentAmount: newAmount,
                          isCompleted: newAmount >= goal.targetAmount,
                        ),
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Add Funds'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, SavingsGoalModel goal) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Goal'),
        content: Text('Delete "${goal.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              context.read<SavingsGoalProvider>().delete(goal.id);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

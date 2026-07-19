import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/gemini_service.dart';
import '../../../shared/theme/app_colors.dart';

const _transferCategoryIds = {'savings_transfer', 'wallet_transfer'};

String _categoryNameFor(String categoryId, List<CategoryModel> categories) {
  if (_transferCategoryIds.contains(categoryId)) return 'transfer';
  return categories
      .firstWhere(
        (c) => c.id == categoryId,
        orElse: () => CategoryModel(
          id: categoryId,
          name: categoryId,
          icon: '',
          colorHex: '',
          type: 'expense',
        ),
      )
      .name;
}

/// One line per transaction so the AI can answer date/item-specific
/// questions instead of only seeing month-level totals.
String _formatTransactionLine(ExpenseModel e, List<CategoryModel> categories) {
  final categoryName = _categoryNameFor(e.categoryId, categories);
  final label = e.description.isNotEmpty
      ? e.description
      : (e.merchantName ?? categoryName);
  final sign = e.type == 'income' ? '+' : '-';
  return '- ${DateFormat('MMM d').format(e.date)}: $label ($categoryName), $sign RM ${e.amount.toStringAsFixed(2)}';
}

class _ChatMessage {
  final String text;
  final bool isUser;
  _ChatMessage({required this.text, required this.isUser});
}

class AiAdviceScreen extends StatefulWidget {
  final VoidCallback? onBack;
  const AiAdviceScreen({super.key, this.onBack});

  @override
  State<AiAdviceScreen> createState() => _AiAdviceScreenState();
}

class _AiAdviceScreenState extends State<AiAdviceScreen> {
  String? _greeting;
  bool _loadingGreeting = false;
  bool _loaded = false;
  final List<_ChatMessage> _messages = [];
  bool _sendingMessage = false;
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // This screen is built eagerly at app startup (MainShell keeps every tab
    // alive inside an IndexedStack), so BudgetProvider is very likely still
    // mid-load on the first frame. Listen for it to finish rather than
    // deciding "no budgets" from a snapshot that just hasn't loaded yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<BudgetProvider>().addListener(_onBudgetProviderChanged);
      _maybeLoadGreeting();
    });
  }

  @override
  void dispose() {
    context.read<BudgetProvider>().removeListener(_onBudgetProviderChanged);
    _chatController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onBudgetProviderChanged() => _maybeLoadGreeting();

  Future<void> _maybeLoadGreeting() async {
    if (_loaded) return;
    final bp = context.read<BudgetProvider>();
    // BudgetProvider.load() may not have even been called yet at this point
    // (HomeScreen awaits expenses/wallets/savings-goals loads first) — wait
    // for it to genuinely finish once, rather than treating a not-yet-loaded
    // empty list as "user has no budgets".
    if (!bp.hasLoadedOnce) return;

    final ep = context.read<ExpenseProvider>();
    final now = DateTime.now();
    final statuses = bp.statuses;

    setState(() => _loadingGreeting = true);

    if (statuses.isNotEmpty) {
      final topStatus = statuses.reduce((a, b) => a.spent > b.spent ? a : b);
      final insight = await GeminiService.instance.getMonthlySummaryInsight(
        totalSpent: ep.expensesForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount),
        totalBudget: bp.totalBudget,
        totalIncome: ep.incomeForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount),
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

  Future<void> _sendMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty || _sendingMessage) return;

    final bp = context.read<BudgetProvider>();
    final ep = context.read<ExpenseProvider>();
    final now = DateTime.now();
    final totalSpent =
        ep.expensesForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount);
    final totalIncome =
        ep.incomeForMonth(now.month, now.year).fold(0.0, (s, e) => s + e.amount);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final monthTxns = ep.forMonth(now.month, now.year)
      ..sort((a, b) => b.date.compareTo(a.date));
    final totalTransfers = monthTxns
        .where((e) => _transferCategoryIds.contains(e.categoryId))
        .fold(0.0, (s, e) => s + e.amount);
    final transactionLines = monthTxns
        .take(200)
        .map((e) => _formatTransactionLine(e, bp.categories))
        .toList();

    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _sendingMessage = true;
    });
    _chatController.clear();
    _scrollToBottom();

    final categoryBreakdown = bp.statuses
        .map((s) =>
            '- ${s.categoryName}: spent RM ${s.spent.toStringAsFixed(2)} of RM ${s.budget.amount.toStringAsFixed(2)} budget (${(s.percentUsed * 100).toStringAsFixed(0)}% used)')
        .toList();

    final reply = await GeminiService.instance.askFinancialQuestion(
      question: text,
      totalSpent: totalSpent,
      totalBudget: bp.totalBudget,
      totalIncome: totalIncome,
      totalTransfers: totalTransfers,
      daysElapsedInMonth: now.day,
      daysInMonth: daysInMonth,
      categoryBreakdown: categoryBreakdown,
      transactions: transactionLines,
      month: DateFormat('MMMM yyyy').format(now),
    );

    if (mounted) {
      setState(() {
        _messages.add(_ChatMessage(text: reply, isUser: false));
        _sendingMessage = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
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
                          body:
                              'Go to the Home screen → Budget Overview to set monthly category budgets.',
                        ),
                      if (_messages.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        const Text('Chat with AI',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 12),
                        ..._messages.map((m) => _ChatBubble(message: m)),
                      ],
                      if (_sendingMessage)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: _TypingIndicator(),
                        ),
                      const SizedBox(height: 16),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          _buildChatInput(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: AppColors.primaryDark,
      automaticallyImplyLeading: false,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primaryDark, AppColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: widget.onBack ?? () => Navigator.pop(context),
      ),
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('AI Financial Advisor',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          Text('Powered by Gemini AI',
              style: TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 16),
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

  Widget _buildChatInput() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
          16, 10, 12, MediaQuery.of(context).padding.bottom + 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              enabled: !_sendingMessage,
              decoration: InputDecoration(
                hintText: 'Ask about your spending...',
                hintStyle:
                    const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: AppColors.background,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onSubmitted: (_) => _sendMessage(),
              textInputAction: TextInputAction.send,
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: AppColors.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _sendMessage,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
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

class _ChatBubble extends StatelessWidget {
  final _ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: message.isUser ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(message.isUser ? 16 : 4),
            bottomRight: Radius.circular(message.isUser ? 4 : 16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!message.isUser) ...[
              const Icon(Icons.auto_awesome,
                  color: AppColors.primary, size: 14),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                message.text,
                style: TextStyle(
                  color: message.isUser ? Colors.white : AppColors.textPrimary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, color: AppColors.primary, size: 14),
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              child: LinearProgressIndicator(
                color: AppColors.primary,
                backgroundColor: AppColors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(body,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
}

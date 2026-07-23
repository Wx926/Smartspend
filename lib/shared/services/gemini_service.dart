import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';

class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  Future<String> _generate(
    String prompt, {
    int maxTokens = 250,
    String? errorMessage,
  }) async {
    final result = await _generateWithStatus(
      prompt,
      maxTokens: maxTokens,
      errorMessage: errorMessage,
    );
    return result.text;
  }

  /// Same as [_generate] but also reports whether [text] is a genuine Gemini
  /// response or the generic fallback/error string — so callers that show
  /// this as "AI advice" in the UI can label a fallback honestly instead of
  /// presenting a canned tip as if it were personalized.
  Future<({String text, bool isFallback})> _generateWithStatus(
    String prompt, {
    int maxTokens = 250,
    String? errorMessage,
  }) async {
    if (AppConstants.geminiApiKey.isEmpty ||
        AppConstants.geminiApiKey == 'your-gemini-api-key') {
      return (text: errorMessage ?? _fallbackAdvice(), isFallback: true);
    }
    try {
      final uri = Uri.parse(AppConstants.geminiEndpoint);
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': AppConstants.geminiApiKey,
            },
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt},
                  ],
                },
              ],
              'generationConfig': {
                'maxOutputTokens': maxTokens,
                'temperature': 0.7,
                // Flash models "think" by default, returning the reasoning
                // as extra response parts before the real answer. We just
                // want a direct short reply, so turn that off — otherwise
                // parts[0] can be a stray thinking fragment instead of text.
                'thinkingConfig': {'thinkingBudget': 0},
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final parts =
            data['candidates']?[0]?['content']?['parts'] as List?;
        final text = parts
            ?.where((p) => p['thought'] != true && p['text'] != null)
            .map((p) => p['text'] as String)
            .join()
            .trim();
        if (text != null && text.isNotEmpty) {
          return (text: text, isFallback: false);
        }
        debugPrint(
          '[GeminiService] 200 response but no usable text in parts: ${response.body}',
        );
      } else {
        debugPrint(
          '[GeminiService] Gemini request failed: HTTP ${response.statusCode} — ${response.body}',
        );
      }
      return (text: errorMessage ?? _fallbackAdvice(), isFallback: true);
    } catch (e) {
      debugPrint('[GeminiService] Gemini request threw: $e');
      return (text: errorMessage ?? _fallbackAdvice(), isFallback: true);
    }
  }

  /// Called when a budget exceeds the red threshold.
  Future<String> getBudgetOverrunAdvice({
    required double spent,
    required double budgetAmount,
    required String categoryName,
    String? locationName,
  }) async {
    final overspend = spent - budgetAmount;
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

The user has EXCEEDED their monthly budget for "$categoryName".
- Budget: RM ${budgetAmount.toStringAsFixed(2)}
- Spent: RM ${spent.toStringAsFixed(2)}
- Overspent by: RM ${overspend.toStringAsFixed(2)}
${locationName != null ? '- Current location: $locationName' : ''}

Give 2-3 short, practical, encouraging sentences of advice.
Use Malaysian Ringgit (RM). Keep it friendly, actionable, and specific. No headers or bullet points.
''';
    return _generate(prompt);
  }

  /// Called for monthly spending summary on the analytics screen.
  Future<String> getMonthlySummaryInsight({
    required double totalSpent,
    required double totalBudget,
    required double totalIncome,
    required String topCategory,
    required double topCategorySpent,
    required String month,
  }) async {
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

User's summary for $month (these figures are already correct and final — use them as-is, do not recompute or second-guess them):
- Income: RM ${totalIncome.toStringAsFixed(2)}
- Total spent: RM ${totalSpent.toStringAsFixed(2)} out of RM ${totalBudget.toStringAsFixed(2)} budget
- Left in budget: RM ${(totalBudget - totalSpent).toStringAsFixed(2)}
- Net saved so far (income minus spent): RM ${(totalIncome - totalSpent).toStringAsFixed(2)}
- Biggest spending category: $topCategory (RM ${topCategorySpent.toStringAsFixed(2)})

Write a 2-3 sentence personalised financial insight: acknowledge their overall performance, mention the top spending area, and give one actionable tip.
Use Malaysian Ringgit (RM). Keep it conversational. No headers or bullet points.
''';
    return _generate(prompt);
  }

  /// Called when a user visits a known shopping location.
  Future<String> getLocationSpendingTip({
    required String locationName,
    required String categoryName,
    required double budgetRemaining,
  }) async {
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

The user just arrived at "$locationName" (a $categoryName location).
They have RM ${budgetRemaining.toStringAsFixed(2)} remaining in their $categoryName budget this month.

Write one short, friendly, context-aware reminder (1-2 sentences) to help them spend mindfully here.
Use Malaysian Ringgit (RM). Be specific and encouraging, not preachy. No headers.
''';
    return _generate(prompt);
  }

  /// Algorithm 3 Step 4: called when a genuine (dwelled ≥15min, non-routine)
  /// venue visit is confirmed and at least one relevant budget category is
  /// Caution or Critical.
  Future<({String text, bool isFallback})> getVenueVisitAdvice({
    required String venueName,
    required String categorySummary,
    required double overallBudgetRemaining,
    required int daysLeftInMonth,
    double? averageSpendAtVenue,
    int pastVisitCount = 0,
  }) async {
    final history = (averageSpendAtVenue != null && pastVisitCount > 0)
        ? '- Based on $pastVisitCount past visit(s) here, they usually spend about RM ${averageSpendAtVenue.toStringAsFixed(2)}.'
        : '- No past visit history recorded at this venue yet.';
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

The user has just arrived at "$venueName" and stayed long enough to count as a genuine visit, not just passing by.

Relevant budget status for the category/categories this venue is tagged with (already correct and final — use these figures as-is, do not recompute or invent other numbers):
$categorySummary
$history
- Overall budget remaining across all their categories this month: RM ${overallBudgetRemaining.toStringAsFixed(2)}
- $daysLeftInMonth day(s) left in the month

Write a short, specific, contextual warning (2-3 sentences) about spending here today. Reference the remaining budget for the relevant category, mention how many days until it runs out at the current pace if that figure is given, and factor in their usual spend at this venue if given. Only mention the overall/all-category budget if it adds useful context (e.g. it's also low) — don't force it in otherwise.
Use Malaysian Ringgit (RM). Be direct but not preachy. No headers or bullet points.
''';
    return _generateWithStatus(prompt);
  }

  /// Called on the analytics screen for a personalised savings tip.
  Future<String> getSavingsTip({
    required double monthlyIncome,
    required double monthlySpending,
  }) async {
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

This month:
- Income: RM ${monthlyIncome.toStringAsFixed(2)}
- Spending: RM ${monthlySpending.toStringAsFixed(2)}
- Net savings: RM ${(monthlyIncome - monthlySpending).toStringAsFixed(2)}

Give one specific, actionable savings tip for a Malaysian user in 2 sentences.
Use Malaysian Ringgit (RM). No headers.
''';
    return _generate(prompt);
  }

  Future<String> askFinancialQuestion({
    required String question,
    required double totalSpent,
    required double totalBudget,
    required double totalIncome,
    required double totalTransfers,
    required int daysElapsedInMonth,
    required int daysInMonth,
    required List<String> categoryBreakdown,
    required List<String> transactions,
    required String month,
    required double netAsset,
    required List<String> walletBreakdown,
    required double totalSaved,
    required List<String> savingsGoals,
    required double totalOwed,
    required List<String> loans,
  }) async {
    final breakdown = categoryBreakdown.isNotEmpty
        ? categoryBreakdown.join('\n')
        : 'No budget categories set yet.';
    final transactionList = transactions.isNotEmpty
        ? transactions.join('\n')
        : 'No transactions recorded yet this month.';
    final walletList = walletBreakdown.isNotEmpty
        ? walletBreakdown.join('\n')
        : 'No wallets set up yet.';
    final savingsGoalList = savingsGoals.isNotEmpty
        ? savingsGoals.join('\n')
        : 'No savings goals set up yet.';
    final loanList = loans.isNotEmpty
        ? loans.join('\n')
        : 'No loans/debts recorded.';
    // Computed here (not left to the model) so projections are exact, not
    // an LLM guess: a simple linear run-rate off spending-so-far.
    final projectedMonthEndSpend = daysElapsedInMonth > 0
        ? totalSpent / daysElapsedInMonth * daysInMonth
        : totalSpent;
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app. You have access to the user's COMPLETE financial picture below — spending, budgets, wallets, savings goals, and loans/debts. Use whichever parts are relevant to answer their question; you're not limited to just this month's spending.

── Spending & budget for $month (already correct and final — use these figures as-is, do not recompute totals yourself or invent other numbers) ──
- Income: RM ${totalIncome.toStringAsFixed(2)}
- Total budget: RM ${totalBudget.toStringAsFixed(2)}
- Total spent so far (real spending only — excludes transfers below): RM ${totalSpent.toStringAsFixed(2)}
- Remaining in budget: RM ${(totalBudget - totalSpent).toStringAsFixed(2)}
- Net saved so far (income minus spent): RM ${(totalIncome - totalSpent).toStringAsFixed(2)}
- Savings/wallet/loan transfers this month: RM ${totalTransfers.toStringAsFixed(2)} — this is money the user MOVED between their own wallets, savings goals, or loans, not money they spent. It never counts against the budget or "total spent" above, no matter how large.
- Day $daysElapsedInMonth of $daysInMonth days in this month
- Projected total spend by month end at the current daily pace: RM ${projectedMonthEndSpend.toStringAsFixed(2)}
Category breakdown:
$breakdown

Individual transactions this month, most recent first (use this list to answer questions about a specific date, item, or transaction — lines marked "transfer" are internal moves, not spending):
$transactionList

── Wallets & net worth (current, not month-specific) ──
- Net asset (real money across all wallets, does not include loan debt): RM ${netAsset.toStringAsFixed(2)}
$walletList

── Savings goals (current progress) ──
- Total saved across all goals: RM ${totalSaved.toStringAsFixed(2)}
$savingsGoalList

── Loans / debts owed (current) ──
- Total still owed across all loans: RM ${totalOwed.toStringAsFixed(2)}
$loanList
Note: a loan's principal was credited as income when it was added and its repayments are excluded from "Total spent" above — they show up here, not as budget spending.

User question: "$question"

Answer clearly and helpfully in 2-4 sentences based on their actual data above, drawing on whichever section(s) the question actually needs — e.g. a question about affordability or "should I take this loan" should weigh income, budget headroom, existing loan repayments, and savings goals together, not just this month's spending. If the question is about a future projection or trend, use the "Projected total spend by month end" figure given rather than estimating your own; if it's about a specific date or transaction, read it from the individual transactions list; if it's about whether a transfer counts as spending, the answer is always no. Use Malaysian Ringgit (RM). Be friendly, practical, and specific. No markdown formatting or bullet points.
''';
    return _generate(
      prompt,
      maxTokens: 350,
      errorMessage:
          'AI is not configured yet. Please add a Gemini API key in the app settings.',
    );
  }

  String _fallbackAdvice() =>
      'Keep tracking your spending consistently — small daily savings add up to big results over time. Review your budget at the end of each week to stay on track.';
}

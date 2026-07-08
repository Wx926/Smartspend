import 'dart:convert';
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
    if (AppConstants.geminiApiKey.isEmpty ||
        AppConstants.geminiApiKey == 'your-gemini-api-key') {
      return errorMessage ?? _fallbackAdvice();
    }
    try {
      final uri = Uri.parse(
        '${AppConstants.geminiEndpoint}?key=${AppConstants.geminiApiKey}',
      );
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
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
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates'][0]['content']['parts'][0]['text'] as String;
      }
      return errorMessage ?? _fallbackAdvice();
    } catch (_) {
      return errorMessage ?? _fallbackAdvice();
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
    required String topCategory,
    required double topCategorySpent,
    required String month,
  }) async {
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

User's spending summary for $month:
- Total spent: RM ${totalSpent.toStringAsFixed(2)} out of RM ${totalBudget.toStringAsFixed(2)} budget
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
  Future<String> getVenueVisitAdvice({
    required String venueName,
    required String categorySummary,
    double? averageSpendAtVenue,
    int pastVisitCount = 0,
  }) async {
    final history = (averageSpendAtVenue != null && pastVisitCount > 0)
        ? '- Based on $pastVisitCount past visit(s) here, they usually spend about RM ${averageSpendAtVenue.toStringAsFixed(2)}.'
        : '';
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

The user has just arrived at "$venueName" and stayed long enough to count as a genuine visit, not just passing by.

Relevant budget status:
$categorySummary
$history

Write a short, specific, contextual warning (2-3 sentences) about spending here today, referencing their remaining budget and their usual spend at this venue if given.
Use Malaysian Ringgit (RM). Be direct but not preachy. No headers or bullet points.
''';
    return _generate(prompt);
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
    required List<String> categoryBreakdown,
    required String month,
  }) async {
    final breakdown = categoryBreakdown.isNotEmpty
        ? categoryBreakdown.join('\n')
        : 'No budget categories set yet.';
    final prompt =
        '''
You are a friendly personal finance advisor for SmartSpend, a Malaysian budgeting app.

The user's financial data for $month:
- Total budget: RM ${totalBudget.toStringAsFixed(2)}
- Total spent: RM ${totalSpent.toStringAsFixed(2)}
- Remaining: RM ${(totalBudget - totalSpent).toStringAsFixed(2)}
Category breakdown:
$breakdown

User question: "$question"

Answer clearly and helpfully in 2-4 sentences based on their actual data. Use Malaysian Ringgit (RM). Be friendly, practical, and specific. No markdown formatting or bullet points.
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

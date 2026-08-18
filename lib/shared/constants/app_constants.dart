import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  // Loaded from .env at runtime — see .env.example for the required keys
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  static String get geminiApiKey => dotenv.env['GEMINI_API_KEY'] ?? '';
  static String get ocrBackendUrl =>
      dotenv.env['OCR_BACKEND_URL'] ?? 'http://10.0.2.2:5000';

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent';

  // Location tracking (Algorithm 1)
  static const double geofenceRadiusMeters = 100.0;
  static const int dwellTimeMinutes = 15; // should be 15 (15 minutes, spec value) — shortened 1 for easy testing
  static const int locationIntervalSeconds = 30;

  // Routine location learning - a visit this long, repeated on this many
  // distinct days, is treated as a candidate Home/Work location
  static const int routineMinDwellMinutes = 60;
  static const int routineMinDistinctDays = 3;

  // Spending habit detection (derived from expense history, not GPS)
  static const int habitMinOccurrences = 3;
  static const int habitLookbackWeeks = 8;

  // Budget alert thresholds (Algorithm 2 & 3)
  static const double yellowThreshold = 0.80;
  static const double redThreshold = 1.00;

  // Algorithm 3 Step 1/7: per-venue cooldown between repeat alerts, and a
  // hard daily cap so a long stay at one place can't spam indefinitely.
  static const double alertCooldownHours = 2; // should be 2 (2 hours, spec value) — 0.25 shortened for easy testing
  static const int maxAlertsPerVenuePerDay = 5; //should be 5 (min 5times per 24hour)100

  static const String appName = 'SmartSpend';


  // Category IDs used to tag internal money movement (wallet-to-wallet,
  // wallet-to-savings-goal, wallet-to-loan) that must never be counted as
  // real income/expense — moving your own money around isn't earning or
  // spending it.
  static const Set<String> internalCategoryIds = {
    'savings_transfer',
    'wallet_transfer',
    'loan_disbursement',
    'loan_repayment',
  };

  // Default expense categories with icon (emoji), color hex, and type
  static const List<Map<String, String>> defaultCategories = [
    {
      'name': 'Food & Dining',
      'icon': '🍔',
      'color': 'FF6B35',
      'type': 'expense',
    },
    {'name': 'Transport', 'icon': '🚗', 'color': '4ECDC4', 'type': 'expense'},
    {'name': 'Shopping', 'icon': '🛍️', 'color': 'A855F7', 'type': 'expense'},
    {
      'name': 'Entertainment',
      'icon': '🎬',
      'color': 'F59E0B',
      'type': 'expense',
    },
    {'name': 'Health', 'icon': '💊', 'color': '10B981', 'type': 'expense'},
    {'name': 'Utilities', 'icon': '💡', 'color': '3B82F6', 'type': 'expense'},
    {'name': 'Others', 'icon': '📦', 'color': '6B7280', 'type': 'expense'},
  ];

  static const List<Map<String, String>> defaultIncomeCategories = [
    {'name': 'Salary', 'icon': '💼', 'color': '27AE60'},
    {'name': 'Part-time Job', 'icon': '💻', 'color': '2980B9'},
    {'name': 'Investment', 'icon': '📈', 'color': 'F39C12'},
    {'name': 'Bonus', 'icon': '🎁', 'color': '8E44AD'},
  ];
}

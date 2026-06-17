import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  // Loaded from .env at runtime — see .env.example for the required keys
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  static String get geminiApiKey => dotenv.env['GEMINI_API_KEY'] ?? '';

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  // Location tracking (Algorithm 1)
  static const double geofenceRadiusMeters = 100.0;
  static const int dwellTimeMinutes = 15;
  static const int locationIntervalSeconds = 60;

  // Budget alert thresholds (Algorithm 2 & 3)
  static const double yellowThreshold = 0.80;
  static const double redThreshold = 1.00;

  // Alert cooldown - don't spam same category within 24 hours
  static const int alertCooldownHours = 24;

  static const String appName = 'SmartSpend';

  // Default expense categories with icon (emoji), color hex, and type
  static const List<Map<String, String>> defaultCategories = [
    {'name': 'Food & Dining', 'icon': '🍔', 'color': 'FF6B35', 'type': 'expense'},
    {'name': 'Transport', 'icon': '🚗', 'color': '4ECDC4', 'type': 'expense'},
    {'name': 'Shopping', 'icon': '🛍️', 'color': 'A855F7', 'type': 'expense'},
    {'name': 'Entertainment', 'icon': '🎬', 'color': 'F59E0B', 'type': 'expense'},
    {'name': 'Health', 'icon': '💊', 'color': '10B981', 'type': 'expense'},
    {'name': 'Utilities', 'icon': '💡', 'color': '3B82F6', 'type': 'expense'},
    {'name': 'Others', 'icon': '📦', 'color': '6B7280', 'type': 'expense'},
  ];

  static const List<Map<String, String>> defaultIncomeCategories = [
    {'name': 'Salary', 'icon': '💼', 'color': '27AE60'},
    {'name': 'Freelance', 'icon': '💻', 'color': '2980B9'},
    {'name': 'Investment', 'icon': '📈', 'color': 'F39C12'},
    {'name': 'Others', 'icon': '💰', 'color': '8E44AD'},
  ];
}

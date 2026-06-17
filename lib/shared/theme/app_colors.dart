import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFF1E8449);
  static const Color primaryLight = Color(0xFF27AE60);
  static const Color primaryDark = Color(0xFF145A32);
  static const Color primarySurface = Color(0xFFE8F5E9);

  static const Color budgetGreen = Color(0xFF27AE60);
  static const Color budgetYellow = Color(0xFFF39C12);
  static const Color budgetRed = Color(0xFFE74C3C);

  static const Color alertGreenBg = Color(0xFFD5F5E3);
  static const Color alertYellowBg = Color(0xFFFEF9C3);
  static const Color alertRedBg = Color(0xFFFEE2E2);

  static const Color background = Color(0xFFF5F6FA);
  static const Color cardBackground = Color(0xFFFFFFFF);
  static const Color darkHeader = Color(0xFF1A2332);

  static const Color textPrimary = Color(0xFF2C3E50);
  static const Color textSecondary = Color(0xFF7F8C8D);
  static const Color textWhite = Color(0xFFFFFFFF);

  // Category colours matching defaultCategories in AppConstants
  static const Color food = Color(0xFFFF6B35);
  static const Color transport = Color(0xFF4ECDC4);
  static const Color shopping = Color(0xFFA855F7);
  static const Color entertainment = Color(0xFFF59E0B);
  static const Color health = Color(0xFF10B981);
  static const Color utilities = Color(0xFF3B82F6);
  static const Color others = Color(0xFF6B7280);

  static Color fromHex(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }
}

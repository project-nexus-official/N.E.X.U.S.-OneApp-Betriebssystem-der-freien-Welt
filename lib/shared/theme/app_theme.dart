import 'package:flutter/material.dart';

class AppColors {
  static const deepBlue = Color(0xFF0A1628);
  static const gold = Color(0xFFD4AF37);
  static const goldLight = Color(0xFFE8C84A);
  static const surface = Color(0xFF121F38);
  static const surfaceVariant = Color(0xFF1A2D4A);
  static const onDark = Color(0xFFE8EAF0);
}

class AppTheme {
  static ThemeData get dark {
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.gold,
      brightness: Brightness.dark,
      primary: AppColors.gold,
      onPrimary: AppColors.deepBlue,
      secondary: AppColors.goldLight,
      surface: AppColors.surface,
      onSurface: AppColors.onDark,
    ).copyWith(
      surfaceContainerHighest: AppColors.surfaceVariant,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: AppColors.deepBlue,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.deepBlue,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: AppColors.gold, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: AppColors.gold),
        titleLarge: TextStyle(color: AppColors.onDark, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: AppColors.onDark),
        bodyMedium: TextStyle(color: AppColors.onDark),
      ),
    );
  }

  static ThemeData get light {
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.deepBlue,
      brightness: Brightness.light,
      primary: AppColors.deepBlue,
      onPrimary: Colors.white,
      secondary: AppColors.gold,
      surface: Colors.white,
      onSurface: AppColors.deepBlue,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.deepBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: AppColors.deepBlue.withValues(alpha: 0.15),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: AppColors.deepBlue, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: AppColors.deepBlue),
        titleLarge: TextStyle(color: AppColors.deepBlue, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: AppColors.deepBlue),
        bodyMedium: TextStyle(color: AppColors.deepBlue),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'survey_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SignalAtlasApp());
}

const ink = Color(0xFF203731);
const accent = Color(0xFF19785F);
const muted = Color(0xFF72817B);
const surface = Color(0xFFF4F6F2);

class SignalAtlasApp extends StatelessWidget {
  const SignalAtlasApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'iWAY+ RSSI Mapping',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        surface: Colors.white,
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: ink,
          letterSpacing: -1,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
        bodyMedium: TextStyle(fontSize: 14, color: ink),
        bodySmall: TextStyle(fontSize: 12, color: muted),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFE2E8E1)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFFE6EBE4), space: 28),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: const Color(0xFFD9EEE4),
        side: const BorderSide(color: Color(0xFFDBE6DF)),
        labelStyle: const TextStyle(
          fontSize: 12,
          color: ink,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: const BorderSide(color: Color(0xFFCCDCD2)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ),
    home: const SurveyScreen(),
  );
}

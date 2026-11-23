import 'package:material_ui/material_ui.dart';

/// Central place for the app's look and feel.
///
/// The palette is a deep ocean: near-black blue depths for surfaces, a teal
/// cyan for actions, and a soft aqua for highlights. It is deliberately dark
/// and low-contrast — a voice diary gets used at night and in quiet moments.
///
/// Colours are hand-picked instead of generated from a seed because Material's
/// tonal generator flattens very dark blues into grey. Tuning the surface ramp
/// by hand keeps the water feeling saturated all the way down.
abstract final class AppTheme {
  // --- Depths (dark scheme surfaces, darkest to lightest) ---
  static const _abyss = Color(0xFF050A14); // scaffold background
  static const _deep = Color(0xFF0A1524); // cards, app bar
  static const _mid = Color(0xFF0F1E33); // raised cards
  static const _shelf = Color(0xFF16293F); // highest surfaces
  static const _shoal = Color(0xFF1E3550);

  // --- Water ---
  static const _foam = Color(0xFFE8F3FF); // primary text
  static const _mist = Color(0xFFA8C4DE); // secondary text
  static const _current = Color(0xFF5FD3E8); // primary accent, cyan
  static const _currentDeep = Color(0xFF0B3B4A); // accent container
  static const _seagrass = Color(0xFF7FE3C4); // tertiary, mint
  static const _seagrassDeep = Color(0xFF0C3A31);

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _current,
      onPrimary: Color(0xFF00202A),
      primaryContainer: _currentDeep,
      onPrimaryContainer: Color(0xFFB8EEF8),
      secondary: Color(0xFF8FB8D9),
      onSecondary: Color(0xFF06202F),
      secondaryContainer: Color(0xFF15293C),
      onSecondaryContainer: _foam,
      tertiary: _seagrass,
      onTertiary: Color(0xFF00281F),
      tertiaryContainer: _seagrassDeep,
      onTertiaryContainer: Color(0xFFB6F2E0),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: _abyss,
      onSurface: _foam,
      onSurfaceVariant: _mist,
      surfaceDim: _abyss,
      surfaceBright: _shoal,
      surfaceContainerLowest: Color(0xFF030710),
      surfaceContainerLow: _deep,
      surfaceContainer: _mid,
      surfaceContainerHigh: _shelf,
      surfaceContainerHighest: _shoal,
      outline: Color(0xFF3A5570),
      outlineVariant: Color(0xFF1B3149),
      inverseSurface: _foam,
      onInverseSurface: _abyss,
      inversePrimary: Color(0xFF00687A),
      surfaceTint: _current,
    );

    return ThemeData(
      colorScheme: scheme,
      brightness: Brightness.dark,
      // Transparent so the app-wide ocean gradient shows through every screen.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }

  /// Light mode is not a priority for a night-time diary, but keeping a
  /// coherent version avoids a jarring flash if the system is set to light.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7490),
      brightness: Brightness.light,
    );

    return ThemeData(
      colorScheme: scheme,
      // Transparent so the app-wide ocean gradient shows through.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

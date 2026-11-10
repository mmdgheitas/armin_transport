/// The look of the app: the palette of the web client, the Vazirmatn font and bordered, compact inputs.
library;

import 'package:material_ui/material_ui.dart';

const String appFontFamily = 'Vazirmatn';

/// The colours of the web client (`web/src/assets/css/app.css`), so that both look like one product.
abstract final class AppColors {
  static const Color background = Color(0xFFF3F5F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFF8FAFC);
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderStrong = Color(0xFFCBD5E1);
  static const Color text = Color(0xFF0F172A);
  static const Color muted = Color(0xFF5B6B82);
  static const Color primary = Color(0xFF1D4ED8);
  static const Color primaryDark = Color(0xFF1E40AF);
  static const Color primarySoft = Color(0xFFEEF4FF);
  static const Color accent = Color(0xFFF59E0B);
  static const Color success = Color(0xFF15803D);
  static const Color successSoft = Color(0xFFECFDF3);
  static const Color danger = Color(0xFFB91C1C);
  static const Color dangerSoft = Color(0xFFFEF2F2);
  static const Color warning = Color(0xFFA16207);
  static const Color warningSoft = Color(0xFFFEFCE8);
  static const Color infoSoft = Color(0xFFEFF6FF);
  static const Color sidebar = Color(0xFF0F1B33);
  static const Color sidebarHover = Color(0xFF1B2A4A);
  static const Color sidebarText = Color(0xFFC7D2E5);
}

const double radiusLarge = 12;
const double radiusSmall = 8;

const ColorScheme _scheme = ColorScheme(
  brightness: Brightness.light,
  primary: AppColors.primary,
  onPrimary: Colors.white,
  primaryContainer: AppColors.primarySoft,
  onPrimaryContainer: AppColors.primaryDark,
  secondary: AppColors.muted,
  onSecondary: Colors.white,
  secondaryContainer: AppColors.primarySoft,
  onSecondaryContainer: AppColors.primaryDark,
  tertiary: AppColors.accent,
  onTertiary: AppColors.text,
  error: AppColors.danger,
  onError: Colors.white,
  errorContainer: AppColors.dangerSoft,
  onErrorContainer: AppColors.danger,
  surface: AppColors.surface,
  onSurface: AppColors.text,
  onSurfaceVariant: AppColors.muted,
  surfaceContainerLowest: AppColors.surface,
  surfaceContainerLow: AppColors.surfaceAlt,
  surfaceContainer: AppColors.surfaceAlt,
  surfaceContainerHigh: AppColors.background,
  surfaceContainerHighest: AppColors.border,
  outline: AppColors.borderStrong,
  outlineVariant: AppColors.border,
  surfaceTint: Colors.transparent,
);

OutlineInputBorder _inputBorder(Color color, [double width = 1]) => OutlineInputBorder(
  borderRadius: const BorderRadius.all(Radius.circular(radiusSmall)),
  borderSide: BorderSide(color: color, width: width),
);

const RoundedRectangleBorder _buttonShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(radiusSmall)),
);

const TextStyle _buttonText = TextStyle(fontFamily: appFontFamily, fontSize: 14, fontWeight: FontWeight.w500);

ThemeData buildAppTheme() {
  return ThemeData(
    colorScheme: _scheme,
    fontFamily: appFontFamily,
    scaffoldBackgroundColor: AppColors.background,
    // The same density on a phone and on a desktop: the forms are laid out once.
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarThemeData(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: appFontFamily,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusLarge)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radiusLarge))),
      titleTextStyle: TextStyle(
        fontFamily: appFontFamily,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: _inputBorder(AppColors.borderStrong),
      enabledBorder: _inputBorder(AppColors.borderStrong),
      disabledBorder: _inputBorder(AppColors.border),
      focusedBorder: _inputBorder(AppColors.primary, 2),
      errorBorder: _inputBorder(AppColors.danger),
      focusedErrorBorder: _inputBorder(AppColors.danger, 2),
      // Persian messages are long: never cut them off.
      errorMaxLines: 4,
      helperMaxLines: 4,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(64, 44), shape: _buttonShape, textStyle: _buttonText),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: _buttonShape,
        textStyle: _buttonText,
        side: const BorderSide(color: AppColors.borderStrong),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 40), shape: _buttonShape, textStyle: _buttonText),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 1),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      contentTextStyle: TextStyle(fontFamily: appFontFamily, fontSize: 14, color: Colors.white),
    ),
    dataTableTheme: const DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll<Color>(AppColors.surfaceAlt),
      headingTextStyle: TextStyle(
        fontFamily: appFontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.muted,
      ),
      dataTextStyle: TextStyle(fontFamily: appFontFamily, fontSize: 14, color: AppColors.text),
      dividerThickness: 1,
      horizontalMargin: 16,
      columnSpacing: 28,
    ),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.muted),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary),
  );
}

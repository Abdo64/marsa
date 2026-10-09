import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Per-device preferences. Not secret, so they sit beside the vaults as plain
/// JSON rather than inside one.
class AppSettings extends ChangeNotifier {
  AppSettings(this._file);
  final File _file;

  ThemeMode themeMode = ThemeMode.system;

  /// A key of [terminalThemes], or `auto` to follow the app theme.
  String terminalTheme = 'auto';
  double fontSize = 13;

  Future<void> load() async {
    if (!await _file.exists()) return;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.firstWhere((m) => m.name == j['themeMode'],
          orElse: () => ThemeMode.system);
      terminalTheme = j['terminalTheme'] as String? ?? 'auto';
      fontSize = (j['fontSize'] as num?)?.toDouble() ?? 13;
    } on FormatException {
      // A damaged preferences file just means defaults.
    }
  }

  void update(void Function() change) {
    change();
    notifyListeners();
    _file.writeAsString(jsonEncode({
      'themeMode': themeMode.name,
      'terminalTheme': terminalTheme,
      'fontSize': fontSize,
    }));
  }
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF14B8A6),
    brightness: brightness,
  ).copyWith(
    surface: dark ? const Color(0xFF12161C) : const Color(0xFFF7F8FA),
    surfaceContainerLowest: dark ? const Color(0xFF0C0F14) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF171C23) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF1B2129) : const Color(0xFFF0F2F5),
    surfaceContainerHigh:
        dark ? const Color(0xFF222932) : const Color(0xFFE8EBEF),
    surfaceContainerHighest:
        dark ? const Color(0xFF2A323D) : const Color(0xFFDFE3E8),
    outlineVariant: dark ? const Color(0xFF2A323D) : const Color(0xFFDDE1E6),
  );
  final radius = BorderRadius.circular(10);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(
          borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating, width: 420),
  );
}

TerminalTheme _t(
  int bg,
  int fg,
  int cursor,
  int selection,
  List<int> c,
) =>
    TerminalTheme(
      cursor: Color(cursor),
      selection: Color(selection),
      foreground: Color(fg),
      background: Color(bg),
      black: Color(c[0]),
      red: Color(c[1]),
      green: Color(c[2]),
      yellow: Color(c[3]),
      blue: Color(c[4]),
      magenta: Color(c[5]),
      cyan: Color(c[6]),
      white: Color(c[7]),
      brightBlack: Color(c[8]),
      brightRed: Color(c[9]),
      brightGreen: Color(c[10]),
      brightYellow: Color(c[11]),
      brightBlue: Color(c[12]),
      brightMagenta: Color(c[13]),
      brightCyan: Color(c[14]),
      brightWhite: Color(c[15]),
      searchHitBackground: const Color(0xFFFFE08A),
      searchHitBackgroundCurrent: const Color(0xFFFFB454),
      searchHitForeground: const Color(0xFF000000),
    );

final Map<String, TerminalTheme> terminalThemes = {
  'Marsa Dark': _t(0xFF0C0F14, 0xFFD5DCE5, 0xFF2DD4BF, 0x5514B8A6, const [
    0xFF1B2129, 0xFFF47067, 0xFF57C785, 0xFFE0AF68, //
    0xFF6CB6FF, 0xFFC792EA, 0xFF39C5CF, 0xFFC9D1D9,
    0xFF5C6773, 0xFFFF938A, 0xFF7EE2A8, 0xFFF2CC8F,
    0xFF96D0FF, 0xFFDCBDFB, 0xFF76E3EA, 0xFFFFFFFF,
  ]),
  'Marsa Light': _t(0xFFFFFFFF, 0xFF1F2933, 0xFF0D9488, 0x4414B8A6, const [
    0xFF24292F, 0xFFCF222E, 0xFF116329, 0xFF7D4E00, //
    0xFF0969DA, 0xFF8250DF, 0xFF1B7C83, 0xFF6E7781,
    0xFF57606A, 0xFFA40E26, 0xFF1A7F37, 0xFF633C01,
    0xFF218BFF, 0xFFA475F9, 0xFF3192AA, 0xFF8C959F,
  ]),
  'Dracula': _t(0xFF282A36, 0xFFF8F8F2, 0xFFF8F8F2, 0x6644475A, const [
    0xFF21222C, 0xFFFF5555, 0xFF50FA7B, 0xFFF1FA8C, //
    0xFFBD93F9, 0xFFFF79C6, 0xFF8BE9FD, 0xFFF8F8F2,
    0xFF6272A4, 0xFFFF6E6E, 0xFF69FF94, 0xFFFFFFA5,
    0xFFD6ACFF, 0xFFFF92DF, 0xFFA4FFFF, 0xFFFFFFFF,
  ]),
  'Solarized Dark': _t(0xFF002B36, 0xFF93A1A1, 0xFF93A1A1, 0x66586E75, const [
    0xFF073642, 0xFFDC322F, 0xFF859900, 0xFFB58900, //
    0xFF268BD2, 0xFFD33682, 0xFF2AA198, 0xFFEEE8D5,
    0xFF586E75, 0xFFCB4B16, 0xFF93A1A1, 0xFF839496,
    0xFF6C71C4, 0xFFD33682, 0xFF2AA198, 0xFFFDF6E3,
  ]),
};

TerminalTheme resolveTerminalTheme(String name, Brightness brightness) =>
    terminalThemes[name] ??
    terminalThemes[
        brightness == Brightness.dark ? 'Marsa Dark' : 'Marsa Light']!;

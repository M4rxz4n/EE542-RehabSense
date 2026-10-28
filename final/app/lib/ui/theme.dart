/// Visual language for the patient view.
///
/// Designed for someone mid-exercise: holding a phone propped up a metre
/// away, arm under load, reading at a glance rather than studying. That
/// drives every choice here — large type, few colours, and meaning carried by
/// position and size rather than by hue alone.
///
/// Colour is never the only signal. A patient may be colourblind, the room
/// may be badly lit, and the phone may be at an angle; so "on target" also
/// means a filled shape, and "off target" also means a label.
library;

// FontFeature lives in dart:ui. Whether Flutter re-exports it has varied, so
// it is named explicitly rather than relied on coming through material.dart.
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

abstract final class RehabColors {
  // A cool dark base. Dark because a bright phone at arm's length during
  // exercise is tiring, and because the pose drawing reads better as light
  // strokes on dark than the reverse.
  static const Color bg = Color(0xFF101418);
  static const Color surface = Color(0xFF181D23);
  static const Color surfaceHigh = Color(0xFF212830);
  static const Color divider = Color(0xFF2C343D);

  static const Color ink = Color(0xFFF2F5F7);
  static const Color inkSoft = Color(0xFFA7B2BD);
  static const Color inkFaint = Color(0xFF6B7681);

  /// Where the arm is now.
  static const Color actual = Color(0xFF4FC3F7);

  /// Where it should be. Deliberately dimmer than [actual]: the ghost is
  /// reference, not the subject.
  static const Color target = Color(0xFF5A6B7A);

  static const Color good = Color(0xFF66BB6A);
  static const Color warn = Color(0xFFFFB74D);
  static const Color bad = Color(0xFFEF5350);

  /// Muscle activity. Warm, so it never reads as a position cue.
  static const Color muscle = Color(0xFFFF8A65);

  static const Color hold = Color(0xFFBA68C8);
}

abstract final class RehabText {
  /// The angle and rep count. Tabular figures so the number does not jitter
  /// sideways as digits change twenty times a second — a surprisingly large
  /// part of whether a live readout feels calm or frantic.
  static const TextStyle hero = TextStyle(
    fontSize: 64,
    height: 1.0,
    fontWeight: FontWeight.w300,
    color: RehabColors.ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle big = TextStyle(
    fontSize: 34,
    height: 1.1,
    fontWeight: FontWeight.w400,
    color: RehabColors.ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle label = TextStyle(
    fontSize: 12,
    height: 1.2,
    letterSpacing: 0.8,
    fontWeight: FontWeight.w600,
    color: RehabColors.inkFaint,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.35,
    color: RehabColors.inkSoft,
  );

  static const TextStyle numeric = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w500,
    color: RehabColors.ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData buildRehabTheme() {
  const scheme = ColorScheme.dark(
    surface: RehabColors.surface,
    primary: RehabColors.actual,
    secondary: RehabColors.muscle,
    error: RehabColors.bad,
    onSurface: RehabColors.ink,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: RehabColors.bg,
    dividerColor: RehabColors.divider,
    appBarTheme: const AppBarTheme(
      backgroundColor: RehabColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    // No cardTheme on purpose. Nothing here uses the Card widget — the
    // panels are Containers with explicit decoration — and the type of
    // ThemeData.cardTheme changed between Flutter versions (CardTheme then
    // CardThemeData), so naming it would pin the project to one of them for
    // no benefit.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: RehabColors.ink,
        side: const BorderSide(color: RehabColors.divider),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: RehabColors.surfaceHigh,
      contentTextStyle: TextStyle(color: RehabColors.ink),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Grades a number against a band, for the one-glance colour.
///
/// Returns [RehabColors.good] inside the band, [RehabColors.warn] just
/// outside, [RehabColors.bad] well outside.
Color gradeColor(double value, double lo, double hi, {double slack = 0.25}) {
  if (value >= lo && value <= hi) return RehabColors.good;
  final span = (hi - lo).abs();
  final margin = span * slack;
  if (value >= lo - margin && value <= hi + margin) return RehabColors.warn;
  return RehabColors.bad;
}

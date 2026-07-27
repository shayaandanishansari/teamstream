import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette carried over from teamstream.html.
class AppColors {
  static const bg = Color(0xFFF3FBFA);
  static const card = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0F1F1D);
  static const inkDim = Color(0xFF5C6D6A);
  static const teal = Color(0xFF00A896);
  static const tealSoft = Color(0xFFD6F5EF);
  static const amber = Color(0xFFFFB238);
  static const cobalt = Color(0xFF3A5AFF);
  static const line = Color(0xFFE1EFEC);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.teal).copyWith(
      surface: AppColors.card,
    ),
    scaffoldBackgroundColor: AppColors.bg,
  );
  return base.copyWith(
    textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme).apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
  );
}

/// Fraunces — the display/serif face used for headings.
TextStyle displayFont({
  double size = 32,
  FontWeight weight = FontWeight.w700,
  Color? color,
}) =>
    GoogleFonts.fraunces(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.ink,
      letterSpacing: -0.5,
    );

/// IBM Plex Mono — for eyebrows, labels, timers.
TextStyle monoFont({
  double size = 11,
  Color? color,
  FontWeight weight = FontWeight.w500,
}) =>
    GoogleFonts.ibmPlexMono(
      fontSize: size,
      color: color ?? AppColors.inkDim,
      fontWeight: weight,
      letterSpacing: 1.0,
    );

/// #RRGGBB or #AARRGGBB -> Color.
Color hexToColor(String hex) {
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  return Color(int.tryParse(h, radix: 16) ?? 0xFF00A896);
}

/// mm:ss, or hh:mm:ss once past an hour. For a LIVE, ticking timer.
String fmtDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Compact accumulated total — "45s", "17m", "2h", "1h 20m". For time already
/// banked on a task, where second-by-second precision is just noise.
String fmtTotal(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
}

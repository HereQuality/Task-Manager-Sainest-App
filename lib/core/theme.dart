import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ── Design tokens ────────────────────────────────────────────────────────
/// A confident, cool-toned "operations console" palette instead of default
/// Material purple or a generic warm/dark theme — this is a tool people
/// triage tasks and tickets in all day, so it stays calm and legible rather
/// than decorative. Ink (near-black navy) does the heavy lifting for text
/// and structure; Indigo is the one accent, used sparingly for actions and
/// selection state; status colors are desaturated so they read as
/// information, not alarm.
class AppColors {
  AppColors._();

  static const ink = Color(0xFF12172B); // primary text / headings
  static const inkMuted = Color(0xFF5B6478); // secondary text
  static const indigo = Color(0xFF4F46E5); // single accent — actions, selection
  static const indigoSoft = Color(0xFFEDEBFC); // accent surfaces / chips
  static const canvas = Color(0xFFF6F7FB); // app background
  static const surface = Color(0xFFFFFFFF); // cards
  static const line = Color(0xFFE6E8F0); // hairlines / dividers

  static const success = Color(0xFF1A9C6B);
  static const successSoft = Color(0xFFE3F6EE);
  static const warning = Color(0xFFB5760A);
  static const warningSoft = Color(0xFFFBF0DC);
  static const danger = Color(0xFFD1435B);
  static const dangerSoft = Color(0xFFFAE7EA);
  static const neutralSoft = Color(0xFFEEF0F5);
}

/// Status → color mapping used consistently across Tasks, Tickets, and the
/// notification feed, so a color always means the same thing everywhere in
/// the app.
class StatusStyle {
  final Color fg;
  final Color bg;
  const StatusStyle(this.fg, this.bg);

  static StatusStyle of(String status) {
    switch (status.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')) {
      case 'complete': // backend Task.status enum is "TO DO"/"IN PROGRESS"/"COMPLETE"
      case 'completed':
      case 'done':
      case 'resolved':
      case 'closed':
        return const StatusStyle(AppColors.success, AppColors.successSoft);
      case 'completelate': // finished after its own due date -- still done, but flagged
        return const StatusStyle(AppColors.warning, AppColors.warningSoft);
      case 'inprogress':
      case 'open':
        return const StatusStyle(AppColors.indigo, AppColors.indigoSoft);
      case 'overdue':
      case 'urgent':
      case 'high':
        return const StatusStyle(AppColors.danger, AppColors.dangerSoft);
      case 'pending':
      case 'onhold':
      case 'waiting':
      case 'delegated': // completionApproval.status === "PENDING" (Task.js) --
      // the assignee marked it done, waiting on the delegator's decision.
        return const StatusStyle(AppColors.warning, AppColors.warningSoft);
      case 'rejected': // completionApproval.status === "REJECTED" -- sent
      // back to the assignee; needs their attention, so styled like overdue.
        return const StatusStyle(AppColors.danger, AppColors.dangerSoft);
      default:
        return const StatusStyle(AppColors.inkMuted, AppColors.neutralSoft);
    }
  }
}

/// Priority → color mapping for the small flag/chip shown on task rows
/// (Tasks list, etc). Separate from StatusStyle above: that maps a task's
/// STATUS (including "urgent"/"high" when used as an overdue-style status
/// keyword elsewhere), this maps the task's PRIORITY field specifically,
/// with all four levels distinguished rather than the two StatusStyle
/// bothers with.
class PriorityStyle {
  final Color fg;
  final Color bg;
  final IconData icon;
  const PriorityStyle(this.fg, this.bg, this.icon);

  static PriorityStyle of(String priority) {
    switch (priority.toLowerCase()) {
      case 'urgent':
        return const PriorityStyle(AppColors.danger, AppColors.dangerSoft, Icons.flag_rounded);
      case 'high':
        return const PriorityStyle(AppColors.warning, AppColors.warningSoft, Icons.flag_rounded);
      case 'low':
        return const PriorityStyle(AppColors.inkMuted, AppColors.neutralSoft, Icons.outlined_flag_rounded);
      case 'normal':
      default:
        return const PriorityStyle(AppColors.indigo, AppColors.indigoSoft, Icons.flag_outlined);
    }
  }
}

/// Spacing scale — reach for these instead of arbitrary numbers so rhythm
/// stays consistent across screens.
class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

class AppRadius {
  static const card = 16.0;
  static const chip = 100.0;
  static const field = 12.0;
}

/// Manrope for headings — a geometric grotesque with enough character to
/// feel considered, without tipping into "marketing site" territory.
/// Inter for body/data — built for UI legibility at small sizes and has
/// tabular figures, which matters for stat cards and due dates.
ThemeData buildAppTheme() {
  final base = ThemeData(useMaterial3: true, colorSchemeSeed: AppColors.indigo);

  final headingFont = GoogleFonts.manropeTextTheme();
  final bodyFont = GoogleFonts.interTextTheme();

  final textTheme = bodyFont.copyWith(
    headlineMedium: headingFont.headlineMedium?.copyWith(
      color: AppColors.ink,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    ),
    headlineSmall: headingFont.headlineSmall?.copyWith(
      color: AppColors.ink,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
    ),
    titleLarge: headingFont.titleLarge?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w700),
    titleMedium: headingFont.titleMedium?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w700),
    bodyLarge: bodyFont.bodyLarge?.copyWith(color: AppColors.ink),
    bodyMedium: bodyFont.bodyMedium?.copyWith(color: AppColors.inkMuted),
    labelLarge: bodyFont.labelLarge?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600),
    labelMedium: bodyFont.labelMedium?.copyWith(color: AppColors.inkMuted, fontWeight: FontWeight.w600),
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.canvas,
    textTheme: textTheme,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.indigo,
      surface: AppColors.surface,
      error: AppColors.danger,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.headlineSmall,
      iconTheme: const IconThemeData(color: AppColors.ink),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.line),
      ),
      margin: EdgeInsets.zero,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.lg),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: const BorderSide(color: AppColors.indigo, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.inkMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.indigo,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.indigoSoft,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 66,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.indigo : AppColors.inkMuted,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? AppColors.indigo : AppColors.inkMuted);
      }),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? AppColors.indigo : AppColors.neutralSoft,
      ),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
  );
}

import 'package:flutter/material.dart';
import '../core/theme.dart';

/// A small, quiet status label — used on task cards, ticket cards, and the
/// notification feed. Color is the only variable; shape/weight stay fixed
/// so scanning a list for "what's urgent" is fast.
class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final style = StatusStyle.of(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm + 2, vertical: 5),
      decoration: BoxDecoration(color: style.bg, borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Text(
        status,
        style: TextStyle(color: style.fg, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.1),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';

/// Shared DD/MM/YYYY due-date format for task rows -- used wherever a task
/// row appears (Tasks screen, Home's Today's tasks) so the format stays
/// identical everywhere rather than each screen picking its own.
final taskDueDateFormat = DateFormat('dd/MM/yyyy');

/// A small icon+label chip for a task row's metadata (due date, assignee) --
/// see EntityCard.metaRow. Shared across every screen that renders a task
/// row (Tasks screen, Home's Today's tasks) so a row looks identical no
/// matter where it's shown.
class MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const MetaChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppColors.inkMuted),
        const SizedBox(width: 3),
        Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted)),
      ],
    );
  }
}

/// Priority flag chip, color-coded via PriorityStyle -- same metaRow slot
/// as MetaChip above, just with the priority's own color instead of the
/// neutral ink-muted used for due date/assignee.
class PriorityChip extends StatelessWidget {
  final String priority;
  const PriorityChip({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    final style = PriorityStyle.of(priority);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: style.bg, borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 12, color: style.fg),
          const SizedBox(width: 3),
          Text(priority, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: style.fg, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Builds the standard metaRow (due date, priority, assigned-by,
/// assigned-to) for a task Map straight off the API -- shared so every
/// screen's task row shows exactly the same chips in the same order.
/// [currentUserId] swaps a matching name for "Me", same shorthand used
/// throughout the app.
List<Widget> taskMetaRow(Map<String, dynamic> t, {String? currentUserId}) {
  String? refId(dynamic v) {
    if (v is Map) return (v['_id'] ?? v['id'])?.toString();
    return v?.toString();
  }

  String? refName(dynamic v, String nameKey) => v is Map ? v[nameKey]?.toString() : null;

  final dueRaw = t['dueDate'];
  final due = dueRaw != null ? DateTime.tryParse(dueRaw.toString())?.toLocal() : null;
  final dueText = due != null ? taskDueDateFormat.format(due) : 'No due date';

  final assigneeId = refId(t['assigneeId']);
  final assigneeName =
      assigneeId != null && assigneeId == currentUserId ? 'Me' : refName(t['assigneeId'], 'employeeName');

  final createdById = refId(t['createdBy']);
  final assignedByName = createdById != null && createdById == currentUserId
      ? 'Me'
      : (refName(t['createdBy'], 'employeeName') ?? refName(t['createdBy'], 'name'));

  final priority = t['priority']?.toString();

  return [
    MetaChip(icon: Icons.event_rounded, label: dueText),
    if (priority != null && priority.isNotEmpty) PriorityChip(priority: priority),
    if (assignedByName != null && assignedByName.isNotEmpty) MetaChip(icon: Icons.north_east_rounded, label: 'By $assignedByName'),
    if (assigneeName != null && assigneeName.isNotEmpty) MetaChip(icon: Icons.person_outline_rounded, label: 'To $assigneeName'),
  ];
}

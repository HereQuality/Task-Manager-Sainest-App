/// Whole days a task is (or was) late by -- mirrors the web app's own
/// per-task "delayed by Nd" badge (client/src/Components/Common/
/// TaskListView.jsx#daysLate), but computed off the SAME raw-dueDate
/// comparison tasks_screen.dart's own `_isOverdue`/`_isDelayed` already use
/// (not the web's end-of-day-adjusted effectiveDueDeadline) -- so this
/// number can never disagree with whichever OVERDUE/COMPLETE (LATE) bucket
/// this app itself already puts the task in.
///
/// - Still open (not COMPLETE) and past its dueDate: days from the
///   deadline to now (keeps growing every day it stays open).
/// - COMPLETE, but finished after its dueDate: days from the deadline to
///   whenever it actually got marked complete (fixed once closed).
/// - On time, still not due yet, or missing a dueDate: 0 (not late at
///   all -- callers should only show a badge when this is > 0).
///
/// Floored at 1, not 0, once a task genuinely is late -- a task 20 minutes
/// past its deadline is already late, "delayed by 0 days" would read as
/// not late at all.
int taskDaysLate(Map<String, dynamic> task) {
  final dueRaw = task['dueDate'];
  if (dueRaw == null) return 0;
  final due = DateTime.tryParse(dueRaw.toString());
  if (due == null) return 0;

  final status = task['status']?.toString();
  DateTime reference;
  if (status == 'COMPLETE') {
    final completedRaw = task['completedAt'];
    if (completedRaw == null) return 0;
    final completed = DateTime.tryParse(completedRaw.toString());
    if (completed == null) return 0;
    reference = completed;
  } else {
    reference = DateTime.now();
  }

  final diffMs = reference.difference(due).inMilliseconds;
  if (diffMs <= 0) return 0;
  final days = (diffMs / (24 * 60 * 60 * 1000)).ceil();
  return days < 1 ? 1 : days;
}

/// Mirrors the web app's effectiveDueDeadline (client/src/Components/
/// Common/TaskListView.jsx, itself mirroring server/utils/atsCalculator.js):
/// a due date with no time-of-day picked means "sometime that day", so its
/// real deadline is the END of that day (the next local midnight), not its
/// stored midnight -- a due date/time of "3 Aug, 5:00 PM" goes overdue the
/// moment 5:00 PM passes, but a bare "3 Aug" only goes overdue once the 4th
/// starts. Read in the device's own local time, same as the web
/// implementation reads the viewer's local time (not the business-tz
/// reading notification_schedule.dart uses for a different purpose --
/// office-hours/holiday gating, not this). Shared by _isOverdue/_isDelayed
/// (tasks_screen.dart) and taskDaysLate below so none of the three can
/// disagree with the server-computed OTC/ATS columns on what counts as
/// on-time.
DateTime effectiveDueDeadline(DateTime due) {
  final local = due.toLocal();
  final hasTime = local.hour != 0 || local.minute != 0 || local.second != 0;
  if (hasTime) return local;
  return DateTime(local.year, local.month, local.day + 1);
}

/// Whole days a task is (or was) late by -- mirrors the web app's own
/// per-task "delayed by Nd" badge (TaskListView.jsx#daysLate), now using
/// the same end-of-day-adjusted effectiveDueDeadline above (previously
/// compared against the raw dueDate instant, which could read a task as
/// late up to a full day earlier than the web app would for a bare,
/// time-of-day-less due date).
///
/// - Still open (not COMPLETE) and past its deadline: days from the
///   deadline to now (keeps growing every day it stays open).
/// - COMPLETE, but finished after its deadline: days from the deadline to
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
  final deadline = effectiveDueDeadline(due);

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

  final diffMs = reference.difference(deadline).inMilliseconds;
  if (diffMs <= 0) return 0;
  final days = (diffMs / (24 * 60 * 60 * 1000)).ceil();
  return days < 1 ? 1 : days;
}

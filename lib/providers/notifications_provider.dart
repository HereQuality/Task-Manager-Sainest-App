import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/notification_service.dart';
import '../core/task_update_tracker.dart';
import '../models/notification_item.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import 'tasks_provider.dart';
import 'tickets_provider.dart';

const _alertedOverdueIdsKey = 'overdue_alerted_task_ids';
const _seenNotificationIdsKey = 'seen_notification_ids';
const _alertedEscalationIdsKey = 'escalation_alerted_task_ids';
const _alertedApprovalIdsKey = 'approval_alerted_task_ids';
// Same key notification_service.dart's snoozeOverdueAlarm writes to -- see
// its doc comment for why a snoozed task must be excluded from the
// "already alerted" re-fire check below until its snooze window passes.
const _snoozedUntilKey = 'overdue_snoozed_until_task_ids';

/// Which feed items the person has already looked at, by AppNotification.id
/// -- what the Home bell's badge count subtracts out. This is a real
/// "seen" set (not a timestamp cutoff) so a due-soon item, whose
/// timestamp sits in the future, still gets acknowledged correctly:
/// comparing against "seen before time X" would never mark a
/// future-dated item as seen no matter how many times it's been opened.
///
/// Note this can only ever reflect opening the in-app Notifications
/// screen, not swiping away the OS-level notification in the tray --
/// Android doesn't hand a swipe-dismiss event back to a regular
/// notification's owning app (that needs a NotificationListenerService,
/// a much heavier, separately-granted permission), so there's no signal
/// to react to there.
Future<Set<String>> _loadSeenIds() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_seenNotificationIdsKey) ?? []).toSet();
}

Future<void> _saveSeenIds(Set<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_seenNotificationIdsKey, ids.toList());
}

/// Called by NotificationsScreen once it's actually shown the current
/// feed. Replaces the whole seen-set with exactly what's showing right
/// now -- anything that drops out later (task completed, ticket aged out
/// of the 3-day window) is naturally dropped too, so this never grows
/// unbounded.
Future<void> markNotificationsSeen(List<AppNotification> currentFeed) async {
  await _saveSeenIds(currentFeed.map((n) => n.id).toSet());
}

/// Which overdue tasks have already had their first "just became overdue"
/// alarm fired -- without this, every time this provider refreshes (pull
/// to refresh, switching tabs, etc.) it would re-ring the alarm on top of
/// whatever snooze/complete state is already sitting in the notification
/// tray. Persisted since the provider itself is `autoDispose` and loses
/// in-memory state constantly.
Future<Set<String>> _loadAlertedIds() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_alertedOverdueIdsKey) ?? []).toSet();
}

Future<void> _saveAlertedIds(Set<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_alertedOverdueIdsKey, ids.toList());
}

Future<Set<String>> _loadAlertedEscalationIds() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_alertedEscalationIdsKey) ?? []).toSet();
}

Future<void> _saveAlertedEscalationIds(Set<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_alertedEscalationIdsKey, ids.toList());
}

Future<Set<String>> _loadAlertedApprovalIds() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_alertedApprovalIdsKey) ?? []).toSet();
}

Future<void> _saveAlertedApprovalIds(Set<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_alertedApprovalIdsKey, ids.toList());
}

/// Builds the in-app notification feed from data the app already has
/// (tasks due soon/overdue, recently-updated tickets) rather than a
/// server-pushed feed, since no notifications endpoint exists yet. Also
/// schedules device-local reminders for due tasks, and arms/fires the
/// overdue alarm (see NotificationService), when those settings are on.
final notificationsFeedProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) async {
  final settings = ref.watch(settingsProvider);
  final items = <AppNotification>[];

  if (!settings.masterEnabled) return items;

  final now = DateTime.now();
  final tasks = await ref.watch(myTasksProvider.future);

  // New task assignments and any edit to an existing task -- independent
  // of taskDueReminders below, which only governs the due-date-specific
  // reminder/overdue-alarm logic. See task_update_tracker.dart: the same
  // detection function background_watcher_service.dart's polling isolate
  // calls, sharing one persisted record so a change caught by whichever
  // path runs first isn't re-announced by the other.
  final currentUserId = ref.watch(authProvider).user?.id;
  for (final change in await detectTaskChanges(tasks, currentUserId: currentUserId)) {
    // "New task assigned to you" and "an existing task changed" are
    // separately controllable (see settings_provider.dart's own doc
    // comment on taskAssigned/taskUpdates) -- a fresh assignment is
    // usually worth knowing about even for someone who's muted the
    // noisier "every edit" stream, or vice versa.
    if (change.isNew ? !settings.taskAssigned : !settings.taskUpdates) continue;
    final body = change.activityMessage ??
        (change.isNew ? 'Assigned to you' : 'Task updated') +
            (change.spaceName.isNotEmpty ? ' · ${change.spaceName}' : '');
    await NotificationService.instance.showTaskUpdateNotification(
      taskId: change.taskId,
      title: change.isNew ? 'New task: ${change.title}' : change.title,
      body: body,
    );
  }

  // Manager-side alert: any of MY direct reports' tasks that are overdue
  // AND still incomplete by 24h+ -- see fetchTeamOverdueEscalations. Empty
  // for anyone with no direct reports, so this is safe to run for every
  // logged-in person, not just managers. Independent of the server's own
  // email-escalation flag (oneDayOverdueEscalatedAt) -- this app keeps
  // its own "already alerted" record instead, same pattern as
  // _alertedOverdueIdsKey above. Its own toggle (teamEscalations) rather
  // than taskDueReminders -- this is about a REPORT's task, not the
  // viewer's own due dates, so it belongs with the other "someone else's
  // activity" toggles below, not the personal due-date reminder one.
  if (settings.teamEscalations) {
    final escalations = await fetchTeamOverdueEscalations();
    final alertedEscalationIds = await _loadAlertedEscalationIds();
    final stillEscalatedIds = <String>{};
    for (final t in escalations) {
      final id = (t['_id'] ?? '').toString();
      if (id.isEmpty) continue;
      stillEscalatedIds.add(id);
      if (alertedEscalationIds.contains(id)) continue;
      final title = (t['name'] ?? 'Untitled task').toString();
      final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
      final spaceName = (t['spaceName'] ?? '').toString();
      await NotificationService.instance.showTaskUpdateNotification(
        taskId: 'escalation_$id',
        title: 'Team overdue: $title',
        body: '$assigneeName · 1 day overdue${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
      );
    }
    await _saveAlertedEscalationIds(stillEscalatedIds);
  }

  // Delegator-side alert: a delegate asked to mark a delegated task
  // complete, and it's waiting on THIS person's approval -- see
  // fetchPendingApprovals. Its own toggle (approvalAlerts) -- this isn't
  // a due-date concept at all, it's an approval workflow.
  if (settings.approvalAlerts) {
    final approvals = await fetchPendingApprovals();
    final alertedApprovalIds = await _loadAlertedApprovalIds();
    final stillPendingIds = <String>{};
    for (final t in approvals) {
      final id = (t['_id'] ?? '').toString();
      if (id.isEmpty) continue;
      stillPendingIds.add(id);
      if (alertedApprovalIds.contains(id)) continue;
      final title = (t['name'] ?? 'Untitled task').toString();
      final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
      final spaceName = (t['spaceName'] ?? '').toString();
      await NotificationService.instance.showTaskUpdateNotification(
        taskId: 'approval_$id',
        title: 'Approval needed: $title',
        body: '$assigneeName marked this complete${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
      );
    }
    await _saveAlertedApprovalIds(stillPendingIds);
  }

  if (settings.taskDueReminders) {
    final alertedIds = await _loadAlertedIds();
    final stillOverdueIds = <String>{};
    // Separate from stillOverdueIds (which drives the feed's "Overdue: X"
    // items and should keep listing a snoozed task) -- this is what
    // actually gets persisted as "already alerted", so a still-snoozed
    // task must be excluded from it. See the doc comment at its one
    // populating site below.
    final stillAlertedIds = <String>{};

    final prefsForSnooze = await SharedPreferences.getInstance();
    final rawSnoozeMap = prefsForSnooze.getString(_snoozedUntilKey);
    Map<String, dynamic> snoozedUntil = {};
    if (rawSnoozeMap != null) {
      try {
        snoozedUntil = jsonDecode(rawSnoozeMap) as Map<String, dynamic>;
      } catch (_) {}
    }
    var snoozeMapChanged = false;

    for (final t in tasks) {
      final status = (t['status'] ?? '').toString().toLowerCase();
      final isComplete = status.contains('complete') || status.contains('done');
      final title = (t['title'] ?? t['name'] ?? 'Untitled task').toString();
      final id = (t['_id'] ?? t['id'] ?? title).toString();
      final spaceName = (t['spaceName'] ?? '').toString();
      // The loud full-screen alarm (sound, lock-screen takeover,
      // Snooze/Complete) is reserved for Urgent tasks only -- High/Normal/
      // Low overdue tasks still show in this feed and still get the
      // quieter due-soon reminder below, just never the alarm treatment.
      final isUrgent = (t['priority'] ?? '').toString() == 'Urgent';
      // `tasks` (myTasksProvider) includes subordinates' tasks too for a
      // manager/senior (see task.controller.js#listMyTasksAll), so without
      // this check a junior's Urgent overdue task would also ring the
      // full-screen alarm on their senior's phone -- the alarm is meant
      // to be assignee-only; a senior's own alert for their team's overdue
      // work is the quieter escalation notification instead (see
      // fetchTeamOverdueEscalations above).
      final assigneeIdRaw = t['assigneeId'];
      final taskAssigneeId = (assigneeIdRaw is Map ? assigneeIdRaw['_id'] : assigneeIdRaw)?.toString();
      final isMine = taskAssigneeId != null && taskAssigneeId == currentUserId;

      if (isComplete) {
        // Done -- stop any pending/ringing alarm for it.
        await NotificationService.instance.cancelOverdueAlarm(id);
        continue;
      }

      final dueRaw = t['dueDate'];
      if (dueRaw == null) continue;
      final due = DateTime.tryParse(dueRaw.toString());
      if (due == null) continue;

      if (due.isBefore(now)) {
        stillOverdueIds.add(id);
        items.add(AppNotification(
          id: 'overdue_$id',
          kind: NotificationKind.taskOverdue,
          title: 'Overdue: $title',
          body: 'Was due ${_relative(due, now)}',
          timestamp: due,
          spaceName: spaceName.isNotEmpty ? spaceName : null,
        ));

        // Snoozed and still within the window -- see
        // notification_service.dart's snoozeOverdueAlarm doc comment.
        // `alertedIds` was deliberately cleared for this id on snooze, so
        // without this check the block below would treat it as a fresh
        // catch-up case and re-ring immediately instead of waiting out the
        // snooze duration.
        final snoozeUntilMs = snoozedUntil[id] as int?;
        final stillSnoozed = snoozeUntilMs != null && now.millisecondsSinceEpoch < snoozeUntilMs;
        if (snoozeUntilMs != null && !stillSnoozed) {
          snoozedUntil.remove(id);
          snoozeMapChanged = true;
        }

        // Deliberately NOT added to stillAlertedIds while still snoozed --
        // stillAlertedIds is what gets persisted as the "already alerted"
        // record below, and marking a still-snoozed task as alerted before
        // it actually rings again would make the `!alertedIds.contains(id)`
        // check just below silently skip it forever once the snooze window
        // passes (confirmed live: this exact bug was why a snoozed alarm
        // never came back). stillOverdueIds above still gets it, since the
        // feed item itself should keep showing regardless of snooze state.
        if (!stillSnoozed) stillAlertedIds.add(id);

        // Catch-up path: this task became overdue without the alarm ever
        // having been armed for it (e.g. it was created/assigned from
        // the web app, so this device never had a chance to schedule
        // it ahead of time via the `else` branch below). Fires once;
        // `alertedIds` stops it from re-ringing on every feed refresh.
        if (isUrgent && isMine && !stillSnoozed && !alertedIds.contains(id)) {
          await NotificationService.instance.showOverdueAlarmNow(taskId: id, taskName: title, spaceName: spaceName);
          // Posting the notification above only gets Android to launch
          // the full-screen intent when the app is backgrounded/closed
          // or the device is locked -- while the app is open and in the
          // foreground (e.g. this ran because the person pulled to
          // refresh the Notifications screen), Android just shows it as
          // a plain heads-up banner instead of re-launching over
          // whatever's already on screen. Setting this directly is what
          // actually takes the person to the full-screen Alarm view in
          // that case, since the app can just navigate itself instead of
          // waiting on the OS to do it.
          pendingAlarmNotifier.value = {'taskId': id, 'taskName': title, 'spaceName': spaceName};
        }
      } else {
        // Not overdue yet -- arm the alarm for the exact moment it
        // becomes overdue (exact-time AlarmManager scheduling, so this
        // still fires even if the app gets closed before then). Urgent
        // AND assignee-only -- the quieter due-soon reminder just below
        // still applies to every priority (and to a senior's view of
        // their team's tasks too).
        if (isUrgent && isMine) {
          await NotificationService.instance.scheduleOverdueAlarmAt(
            taskId: id,
            taskName: title,
            spaceName: spaceName,
            when: due,
          );
        }

        if (due.difference(now).inHours <= 48) {
          items.add(AppNotification(
            id: 'duesoon_$id',
            kind: NotificationKind.taskDueSoon,
            title: 'Due soon: $title',
            body: 'Due ${_relative(due, now)}',
            timestamp: due,
            spaceName: spaceName.isNotEmpty ? spaceName : null,
          ));

          // Schedule an actual device reminder ahead of the due time, so
          // this surfaces even if the person isn't in the app when it
          // matters.
          final remindAt = due.subtract(Duration(hours: settings.reminderHoursBefore));
          await NotificationService.instance.scheduleAt(
            id: id.hashCode & 0x7fffffff,
            title: 'Task due soon',
            body: spaceName.isNotEmpty ? '$title · $spaceName' : title,
            when: remindAt,
          );
        }
      }
    }

    await _saveAlertedIds(stillAlertedIds);
    if (snoozeMapChanged) {
      await prefsForSnooze.setString(_snoozedUntilKey, jsonEncode(snoozedUntil));
    }
  }

  if (settings.ticketUpdates) {
    final tickets = await ref.watch(ticketsProvider.future);
    for (final t in tickets) {
      final status = (t['status'] ?? '').toString();
      if (status.isEmpty) continue;
      final updatedRaw = t['updatedAt'] ?? t['updated_at'];
      final updated = updatedRaw != null ? DateTime.tryParse(updatedRaw.toString()) : null;
      if (updated == null || now.difference(updated).inDays > 3) continue;

      final title = t['title'] ?? 'Ticket';
      final id = (t['_id'] ?? t['id'] ?? title).toString();
      items.add(AppNotification(
        id: 'ticket_$id',
        kind: NotificationKind.ticketUpdate,
        title: title,
        body: 'Status: $status',
        timestamp: updated,
      ));
    }
  }

  items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return items;
});

final unreadNotificationCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final items = await ref.watch(notificationsFeedProvider.future);
  final seen = await _loadSeenIds();
  return items.where((n) => !seen.contains(n.id)).length;
});

String _relative(DateTime target, DateTime now) {
  final diff = target.difference(now);
  final absHours = diff.inHours.abs();
  if (absHours < 1) return diff.isNegative ? 'moments ago' : 'in moments';
  if (absHours < 24) {
    return diff.isNegative ? '$absHours h ago' : 'in $absHours h';
  }
  final days = (absHours / 24).round();
  return diff.isNegative ? '$days d ago' : 'in $days d';
}

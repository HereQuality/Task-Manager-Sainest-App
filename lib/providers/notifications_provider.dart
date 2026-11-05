import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_client.dart';
import '../core/notification_schedule.dart';
import '../core/notification_service.dart';
import '../core/task_update_tracker.dart';
import '../models/notification_item.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import 'spaces_provider.dart';
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
Future<Set<String>> _loadSeenIds(String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(scopedKey(_seenNotificationIdsKey, currentUserId)) ?? []).toSet();
}

Future<void> _saveSeenIds(Set<String> ids, String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(scopedKey(_seenNotificationIdsKey, currentUserId), ids.toList());
}

/// Called by NotificationsScreen once it's actually shown the current
/// feed. Replaces the whole seen-set with exactly what's showing right
/// now -- anything that drops out later (task completed, ticket aged out
/// of the 3-day window) is naturally dropped too, so this never grows
/// unbounded.
Future<void> markNotificationsSeen(List<AppNotification> currentFeed) async {
  final currentUserId = await ApiClient.instance.readCurrentUserId();
  await _saveSeenIds(currentFeed.map((n) => n.id).toSet(), currentUserId);
}

/// Which overdue tasks have already had their first "just became overdue"
/// alarm fired -- without this, every time this provider refreshes (pull
/// to refresh, switching tabs, etc.) it would re-ring the alarm on top of
/// whatever snooze/complete state is already sitting in the notification
/// tray. Persisted since the provider itself is `autoDispose` and loses
/// in-memory state constantly.
Future<Set<String>> _loadAlertedIds(String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(scopedKey(_alertedOverdueIdsKey, currentUserId)) ?? []).toSet();
}

Future<void> _saveAlertedIds(Set<String> ids, String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(scopedKey(_alertedOverdueIdsKey, currentUserId), ids.toList());
}

/// Called by alarm_screen.dart's "End" button the instant someone
/// dismisses a ringing/pending alarm, so this task is recorded as
/// "already alerted" right away -- previously that recording only
/// happened on the NEXT feed/watcher poll after the alarm fired (see the
/// catch-up loop below), which never ran at all if the person logged out
/// shortly after tapping End. On a later login (even months later), the
/// catch-up loop would then treat that same already-handled task as
/// brand new and ring its alarm again. This makes End itself durable,
/// independent of whether another poll ever runs afterward.
Future<void> markOverdueAlarmHandled(String taskId) async {
  final currentUserId = await ApiClient.instance.readCurrentUserId();
  final ids = await _loadAlertedIds(currentUserId);
  ids.add(taskId);
  await _saveAlertedIds(ids, currentUserId);
}

Future<Set<String>> _loadAlertedEscalationIds(String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(scopedKey(_alertedEscalationIdsKey, currentUserId)) ?? []).toSet();
}

Future<void> _saveAlertedEscalationIds(Set<String> ids, String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(scopedKey(_alertedEscalationIdsKey, currentUserId), ids.toList());
}

Future<Set<String>> _loadAlertedApprovalIds(String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(scopedKey(_alertedApprovalIdsKey, currentUserId)) ?? []).toSet();
}

Future<void> _saveAlertedApprovalIds(Set<String> ids, String? currentUserId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(scopedKey(_alertedApprovalIdsKey, currentUserId), ids.toList());
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
  // tasks/schedule/visibleSpaceIds are three independent network reads with
  // no shared state and no side effects of their own -- fetching them one
  // after another (the previous shape here) just stacks their latencies for
  // no reason. Running them together is what actually cuts the feed's
  // worst-case load time; everything past this point still runs in the same
  // order as before, since every side-effect loop below only starts once
  // all three are already in hand.
  final results = await Future.wait([
    ref.watch(myTasksProvider.future),
    // The company-wide holidays/weekly-off/office-hours window (see
    // notification_schedule.dart) -- fetched once per feed build and reused
    // below for every OS-level notification this function might fire
    // (including the full-screen alarm), same rule email.service.js
    // already applies server-side to task emails. Feed LIST items further
    // down (the in-app "Overdue"/"Due soon" entries) are deliberately NOT
    // gated by this -- it only suppresses actual push/alarm notifications,
    // not what shows when the person opens the app themselves.
    fetchNotificationSchedule(),
    // Gates the "team task" branch below to Spaces this viewer can
    // actually see -- moved up here (it used to be fetched later, after
    // `changes`) purely so it's part of this same parallel batch; nothing
    // below depends on fetch order between these three.
    fetchMyVisibleSpaceIds(),
  ]);
  final tasks = results[0] as List<Map<String, dynamic>>;
  final schedule = results[1] as NotificationSchedule;
  final visibleSpaceIds = results[2] as Set<String>;
  final withinWindow = schedule.isWithinWindow(now);

  // New task assignments and any edit to an existing task -- independent
  // of taskDueReminders below, which only governs the due-date-specific
  // reminder/overdue-alarm logic. See task_update_tracker.dart: the same
  // detection function background_watcher_service.dart's polling isolate
  // calls, sharing one persisted record so a change caught by whichever
  // path runs first isn't re-announced by the other. Deliberately still
  // calls detectTaskChanges even while a toggle below is off, rather than
  // skipping this whole block -- that call is what advances its own
  // persisted "already seen" snapshot, so skipping it entirely while
  // muted would let changes pile up and all flood in at once the moment
  // notifications are turned back on (a deliberate "drop forever while
  // muted" design).
  //
  // NOT gated by `withinWindow` (unlike the overdue-alarm logic further
  // down this function) -- server/utils/notificationSchedule.js's own doc
  // comment is explicit that the company's quiet-hours window "never
  // touches in-app real-time updates or the mobile push feed, only
  // email." A plain "assigned to you"/"task updated" notification is
  // exactly that case, so it used to be wrongly held back until the
  // window reopened (often landing right at midnight if office hours ran
  // late) -- fixed by always calling detectTaskChanges here, same as
  // background_watcher_service.dart's matching fix.
  final currentUserId = ref.watch(authProvider).user?.id;
  final changes = await detectTaskChanges(tasks, currentUserId: currentUserId);
  // visibleSpaceIds (gates the "team task" branch below to Spaces this
  // viewer can actually see -- member, SuperAdmin, or Full Access; see
  // TaskChangeResult.spaceId's own doc comment for why listMyTasksAll's
  // broader "every report's task, any Space" visibility isn't the right
  // scope for a push) was already fetched above, alongside tasks/schedule.
  // myTasksProvider ("/tasks/mine/all") mixes a manager/senior's own
  // tasks together with every subordinate's (see
  // task.controller.js#listMyTasksAll) -- this map is what tells "my
  // task changed" apart from "a team member's task changed" below, since
  // TaskChangeResult itself only carries the raw assigneeId.
  final assigneeNameByTaskId = {
    for (final t in tasks)
      (t['_id'] ?? t['id'] ?? '').toString(): (t['assigneeId'] is Map ? t['assigneeId']['employeeName'] : null)?.toString(),
  };
  // Companion to assigneeNameByTaskId above, for the iOS team-task guard
  // further down -- listMyTasksAll's own populate carries this alongside
  // employeeName/profilePic now specifically so this lookup is possible.
  final assigneeManagerIdByTaskId = {
    for (final t in tasks)
      (t['_id'] ?? t['id'] ?? '').toString():
          (t['assigneeId'] is Map ? t['assigneeId']['reportingManagerId'] : null)?.toString(),
  };
  for (final change in changes) {
    final isMine = currentUserId != null && change.assigneeId == currentUserId;
    if (isMine) {
      if (!settings.myTaskNotifications) continue;
      // "New task assigned to you" and "an existing task changed" are
      // separately controllable (see settings_provider.dart's own doc
      // comment on taskAssigned/taskUpdates) -- a fresh assignment is
      // usually worth knowing about even for someone who's muted the
      // noisier "every edit" stream, or vice versa.
      if (change.isNew ? !settings.taskAssigned : !settings.taskUpdates) continue;
      // iOS only: task.controller.js's sendPushToUser sends a real FCM
      // push for every one of these (new assignment or edit) straight to
      // this same assignee, and push_service.dart's setForegroundNotification-
      // PresentationOptions call now makes iOS auto-display that push's
      // banner itself while foregrounded -- a single OS-wide setting, so
      // it applies to any notification reaching UNUserNotificationCenter,
      // not just ones from that source. Posting this local notification
      // too would put a second, Dart-invisible-to-native-side banner on
      // screen for the exact same event. Android has no such auto-display
      // (see push_service.dart's _showForeground), so this remains its
      // only path. The team-task branch below has no server push
      // counterpart at all (task.controller.js only pushes to the
      // assignee) and always needs this regardless of platform.
      final body = change.activityMessage ??
          (change.isNew ? 'Assigned to you' : 'Task updated') +
              (change.spaceName.isNotEmpty ? ' · ${change.spaceName}' : '');
      if (!Platform.isIOS) {
        await NotificationService.instance.showTaskUpdateNotification(
          taskId: change.taskId,
          title: change.isNew ? 'New task: ${change.title}' : change.title,
          body: body,
        );
      }
    } else {
      // Unlike the "isMine" branch above, still skip a change the viewer
      // made themselves to someone ELSE's task (e.g. reassigning a
      // teammate's task) -- see TaskChangeResult.isSelfMade's doc comment.
      if (change.isSelfMade) continue;
      // A report's task can sit in a Space this viewer isn't a member of
      // (listMyTasksAll surfaces it anyway, for oversight) -- but a push
      // about it shouldn't reach someone who couldn't even open that
      // Space themselves. change.spaceId is null defensively falls open
      // (still notifies) rather than silently dropping a legitimate one
      // if the field's ever missing from a task payload.
      if (change.spaceId != null && !visibleSpaceIds.contains(change.spaceId)) continue;
      if (!settings.teamTaskNotifications) continue;
      if (change.isNew ? !settings.teamTaskAssigned : !settings.teamTaskUpdates) continue;
      // iOS only, and only a partial overlap with the server push added
      // to task.controller.js's createTask/createTaskInSpace/updateTask:
      // that one only ever reaches the assignee's DIRECT manager (same
      // "1 level up" convention as jobs/overdueEscalation.js), whereas
      // this branch can fire for ANY subordinate at ANY depth (myTasksProvider
      // -- "/tasks/mine/all" -- mixes in every subordinate for a senior
      // role, not just direct reports; see its own doc comment). Skipping
      // this unconditionally on iOS would silence a senior/SuperAdmin's
      // multi-level reports entirely, so it only skips when this viewer
      // IS that direct manager (the one case the new push actually
      // covers) -- everyone deeper in the chain still needs this local
      // path since no push reaches them.
      final isDirectReportOfViewer =
          currentUserId != null && assigneeManagerIdByTaskId[change.taskId] == currentUserId;
      if (Platform.isIOS && isDirectReportOfViewer) continue;
      final assigneeName = assigneeNameByTaskId[change.taskId] ?? 'A team member';
      final body = change.activityMessage ??
          (change.isNew ? 'Assigned to $assigneeName' : 'Updated') +
              (change.spaceName.isNotEmpty ? ' · ${change.spaceName}' : '');
      await NotificationService.instance.showTaskUpdateNotification(
        taskId: change.taskId,
        title: change.isNew ? 'New team task: ${change.title}' : 'Team task updated: ${change.title}',
        body: body,
      );
    }
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
    final alertedEscalationIds = await _loadAlertedEscalationIds(currentUserId);
    final stillEscalatedIds = <String>{};
    // See consumeFirstRunBaseline's doc comment: without this, every
    // already-1-day-overdue report's task on a brand new device (or a
    // never-before-seen account on this one) would fire as a fresh "Team
    // overdue" alert the instant this ran, instead of just the ones that
    // become newly escalated from here on. legacyDataExists read before
    // _saveAlertedEscalationIds below writes to this key this tick.
    final escalationPrefs = await SharedPreferences.getInstance();
    final isFirstRun = await peekFirstRunBaseline(
      'escalation',
      currentUserId,
      legacyDataExists: escalationPrefs.containsKey(scopedKey(_alertedEscalationIdsKey, currentUserId)),
    );
    for (final t in escalations) {
      final id = (t['_id'] ?? '').toString();
      if (id.isEmpty) continue;
      final title = (t['name'] ?? 'Untitled task').toString();
      final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
      final spaceName = (t['spaceName'] ?? '').toString();
      // Added to the in-app feed unconditionally, every build, same as
      // taskOverdue/taskDueSoon below -- unlike the one-shot banner further
      // down (gated by alreadyAlerted so it only ever fires once), this
      // list item is meant to keep showing for as long as the escalation
      // itself is still live, not just the instant it was first noticed.
      // Previously this whole block only ever posted the OS banner and
      // never added anything here at all -- confirmed as a real gap:
      // swipe the banner away (or it's missed entirely), and there was no
      // way to find "Team overdue: ..." again from inside the app itself.
      final dueRaw = t['dueDate'];
      final due = dueRaw == null ? null : DateTime.tryParse(dueRaw.toString());
      items.add(AppNotification(
        id: 'escalation_$id',
        kind: NotificationKind.teamOverdue,
        title: 'Team overdue: $title',
        body: '$assigneeName · 1 day overdue',
        timestamp: due ?? now,
        refId: id,
        spaceName: spaceName.isNotEmpty ? spaceName : null,
      ));
      if (isFirstRun) {
        stillEscalatedIds.add(id);
        continue;
      }
      final alreadyAlerted = alertedEscalationIds.contains(id);
      // Once genuinely alerted, stays recorded as alerted regardless of
      // the notification window -- only a NOT-yet-alerted one is left
      // out of stillEscalatedIds while suppressed, so it's still treated
      // as pending (not "already handled") once a later poll runs back
      // inside the window. Marking it alerted here without ever having
      // shown the notification would silence it permanently instead.
      if (!alreadyAlerted && !withinWindow) continue;
      stillEscalatedIds.add(id);
      if (alreadyAlerted) continue;
      // iOS only: jobs/overdueEscalation.js now sends this manager a real
      // FCM push ("Team overdue: ...") the same moment it stamps
      // oneDayOverdueEscalatedAt server-side -- iOS already auto-displays
      // that push's banner (see the isMine-branch guard above for why).
      // stillEscalatedIds/alreadyAlerted bookkeeping above still has to
      // run on every platform regardless, so only the local re-post is
      // skipped here, not the loop itself.
      if (!Platform.isIOS) {
        await NotificationService.instance.showTaskUpdateNotification(
          taskId: 'escalation_$id',
          title: 'Team overdue: $title',
          body: '$assigneeName · 1 day overdue${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
        );
      }
    }
    await _saveAlertedEscalationIds(stillEscalatedIds, currentUserId);
    // Written only now, after the ids above are already saved -- see
    // peekFirstRunBaseline's own doc comment for why the order matters.
    if (isFirstRun) await markFirstRunBaselineDone('escalation', currentUserId);
  }

  // Delegator-side alert: a delegate asked to mark a delegated task
  // complete, and it's waiting on THIS person's approval -- see
  // fetchPendingApprovals. Its own toggle (approvalAlerts) -- this isn't
  // a due-date concept at all, it's an approval workflow.
  if (settings.approvalAlerts) {
    final approvals = await fetchPendingApprovals();
    final alertedApprovalIds = await _loadAlertedApprovalIds(currentUserId);
    final stillPendingIds = <String>{};
    // See consumeFirstRunBaseline's doc comment / the matching guard on
    // the escalations block above.
    final approvalPrefs = await SharedPreferences.getInstance();
    final isFirstRunApprovals = await peekFirstRunBaseline(
      'approval',
      currentUserId,
      legacyDataExists: approvalPrefs.containsKey(scopedKey(_alertedApprovalIdsKey, currentUserId)),
    );
    for (final t in approvals) {
      final id = (t['_id'] ?? '').toString();
      if (id.isEmpty) continue;
      final title = (t['name'] ?? 'Untitled task').toString();
      final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
      final spaceName = (t['spaceName'] ?? '').toString();
      // Added to the in-app feed unconditionally, every build -- same
      // reasoning as the escalations block above, which this mirrors.
      final requestedRaw = t['requestedAt'];
      final requested = requestedRaw == null ? null : DateTime.tryParse(requestedRaw.toString());
      items.add(AppNotification(
        id: 'approval_$id',
        kind: NotificationKind.approvalNeeded,
        title: 'Approval needed: $title',
        body: '$assigneeName marked this complete',
        timestamp: requested ?? now,
        refId: id,
        spaceName: spaceName.isNotEmpty ? spaceName : null,
      ));
      if (isFirstRunApprovals) {
        stillPendingIds.add(id);
        continue;
      }
      final alreadyAlerted = alertedApprovalIds.contains(id);
      // Same "stays recorded once genuinely alerted, otherwise left
      // pending while suppressed" reasoning as the team-escalations loop
      // above.
      if (!alreadyAlerted && !withinWindow) continue;
      stillPendingIds.add(id);
      if (alreadyAlerted) continue;
      // iOS only: task.controller.js's requestingCompletionAsDelegate
      // branch already sends the delegator a real "Approval needed" FCM
      // push the moment this happens -- same reasoning as the isMine-
      // branch and team-escalations guards above.
      if (!Platform.isIOS) {
        await NotificationService.instance.showTaskUpdateNotification(
          taskId: 'approval_$id',
          title: 'Approval needed: $title',
          body: '$assigneeName marked this complete${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
        );
      }
    }
    await _saveAlertedApprovalIds(stillPendingIds, currentUserId);
    if (isFirstRunApprovals) await markFirstRunBaselineDone('approval', currentUserId);
  }

  // "A task was just assigned to you" -- deliberately its OWN loop, not
  // nested inside the `if (settings.taskDueReminders)` block below: that
  // setting is specifically about due-date/overdue reminders and the
  // alarm, entirely unrelated to "was I just assigned something". It used
  // to live inside that block (simpler, one fewer pass over `tasks`), but
  // that silently gated assignment notifications on the due-reminders
  // toggle too -- someone with "Task due reminders" off but "Task
  // assigned" on never saw a new-assignment notification at all.
  for (final t in tasks) {
    final assigneeIdRaw = t['assigneeId'];
    final taskAssigneeId = (assigneeIdRaw is Map ? assigneeIdRaw['_id'] : assigneeIdRaw)?.toString();
    final isMine = taskAssigneeId != null && taskAssigneeId == currentUserId;
    if (!isMine || !settings.myTaskNotifications || !settings.taskAssigned) continue;

    final title = (t['title'] ?? t['name'] ?? 'Untitled task').toString();
    final id = (t['_id'] ?? t['id'] ?? title).toString();
    final spaceName = (t['spaceName'] ?? '').toString();
    // Recomputed from the task's own createdAt every build (same pattern
    // as the overdue/due-soon items below), rather than from the one-shot
    // `changes` diff above, so it keeps showing here across refreshes
    // instead of only appearing once and then vanishing the moment
    // detectTaskChanges advances its own "already seen" snapshot. Capped
    // to the last 2 days, same window taskDueReminders' own "due soon"
    // check uses, so this doesn't just accumulate forever.
    final createdRaw = t['createdAt'];
    final created = createdRaw == null ? null : DateTime.tryParse(createdRaw.toString());
    if (created != null && now.difference(created).inHours <= 48) {
      items.add(AppNotification(
        id: 'assigned_$id',
        kind: NotificationKind.taskAssigned,
        title: 'New task: $title',
        body: spaceName.isNotEmpty ? 'Assigned to you · $spaceName' : 'Assigned to you',
        timestamp: created,
        refId: id,
        spaceName: spaceName.isNotEmpty ? spaceName : null,
      ));
    }
  }

  if (settings.taskDueReminders) {
    final alertedIds = await _loadAlertedIds(currentUserId);
    // What actually gets persisted as "already alerted" (see
    // _alertedOverdueIdsKey doc comment) -- a still-snoozed task is
    // deliberately excluded from it below.
    final stillAlertedIds = <String>{};
    final prefsForSnooze = await SharedPreferences.getInstance();
    // See consumeFirstRunBaseline's doc comment -- without this, every
    // Urgent task whose reminderAt had already passed on a brand new
    // device (or a never-before-seen account on this one) rang the full-
    // screen alarm for its ENTIRE backlog the instant this ran, instead of
    // only ringing for reminders that pass from here on. legacyDataExists
    // must be read BEFORE anything below writes to _alertedOverdueIdsKey
    // this tick.
    final isFirstRunOverdueLegacy = await peekFirstRunBaseline(
      'overdue_alarm',
      currentUserId,
      legacyDataExists: prefsForSnooze.containsKey(scopedKey(_alertedOverdueIdsKey, currentUserId)),
    );
    // Separate one-time baseline for the Urgent-only -> any-priority alarm
    // change: an existing device already has overdue_alarm's own legacy
    // data (so the check above is never "first run" for it), but that data
    // only ever recorded Urgent tasks -- every non-Urgent task with a past
    // reminderAt was always `continue`d before it could reach alertedIds.
    // Without this, every one of those now-newly-eligible tasks reads as
    // brand new the first time this broadened logic runs and rings its
    // catch-up alarm immediately, all in the same pass -- confirmed live as
    // a flood of alarms/notifications landing right after login (this pass
    // is one of the first things to run then). legacyDataExists is
    // deliberately always false here: no install, old or new, could
    // possibly have already baselined THIS category, so every account
    // needs exactly one silent baselining pass under this new key.
    final isFirstRunAnyPriority = await peekFirstRunBaseline(
      'overdue_alarm_any_priority',
      currentUserId,
      legacyDataExists: false,
    );
    final isFirstRunOverdue = isFirstRunOverdueLegacy || isFirstRunAnyPriority;

    final rawSnoozeMap = prefsForSnooze.getString(scopedKey(_snoozedUntilKey, currentUserId));
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
        // Done -- stop any pending/ringing alarm for it. Assignee-only --
        // `tasks` (myTasksProvider) includes a manager/senior's
        // subordinates' tasks too (see isMine's own doc comment above),
        // and the full-screen alarm has always been assignee-only, so a
        // manager never has a local alarm armed for a subordinate's task
        // in the first place. Without this check, EVERY completed
        // subordinate task on EVERY feed rebuild called
        // cancelOverdueAlarm, which (see its own doc comment) also syncs
        // reminderAt: null to the server -- PUT /tasks/:id/reminder
        // correctly rejects that with 403 ("Only this task's assignee can
        // change its reminder") since the manager isn't the assignee.
        // Confirmed live in production server logs: hundreds of repeated
        // 403s on this exact endpoint, one per completed subordinate
        // task, on every single feed refresh -- pure server-log noise
        // (and a wasted network call) with no actual effect, since the
        // request was always going to be rejected, but it ran on every
        // poll for every manager/senior account regardless.
        if (isMine) {
          // ignore: avoid_print
          print('[FEED] taskId=$id isComplete=true, cancelling any pending/ringing alarm');
          await NotificationService.instance.cancelOverdueAlarm(id);
        }
        continue;
      }

      // Feed items ("Overdue: X" / "Due soon: X") stay tied to dueDate --
      // that's still what the task is actually due by. Only the loud
      // full-screen alarm itself has moved to reminderAt below.
      final dueRaw = t['dueDate'];
      final due = dueRaw == null ? null : DateTime.tryParse(dueRaw.toString());
      if (due != null) {
        if (due.isBefore(now)) {
          items.add(AppNotification(
            id: 'overdue_$id',
            kind: NotificationKind.taskOverdue,
            title: 'Overdue: $title',
            body: 'Was due ${_relative(due, now)}',
            timestamp: due,
            refId: id,
            spaceName: spaceName.isNotEmpty ? spaceName : null,
          ));
        } else if (due.difference(now).inHours <= 48) {
          items.add(AppNotification(
            id: 'duesoon_$id',
            kind: NotificationKind.taskDueSoon,
            title: 'Due soon: $title',
            body: 'Due ${_relative(due, now)}',
            timestamp: due,
            refId: id,
            spaceName: spaceName.isNotEmpty ? spaceName : null,
          ));

          // Schedule an actual device reminder ahead of the due time, so
          // this surfaces even if the person isn't in the app when it
          // matters -- deferred to the next allowed moment if the raw
          // due-minus-N-hours instant itself would land outside the
          // notification window (a holiday, a weekly off day, or outside
          // office hours). Assignee-only, same as the extraReminders loop
          // and the full-screen alarm below -- `tasks` includes a
          // manager/senior's subordinates' tasks too (for the in-app feed
          // item above, which IS meant to show those), but the actual OS
          // push belongs only on the person it's assigned to.
          if (isMine) {
            final remindAt = schedule.resolveNextAllowedInstant(
              due.subtract(Duration(hours: settings.reminderHoursBefore)),
            );
            await NotificationService.instance.scheduleAt(
              id: id.hashCode & 0x7fffffff,
              title: 'Task due soon',
              body: spaceName.isNotEmpty ? '$title · $spaceName' : title,
              when: remindAt,
            );
          }
        }
      }

      // Extra, plain reminders -- added from the Add/Edit Task screen's
      // "+" next to Reminder date/time (see Task.js's extraReminders doc
      // comment). Assignee-only (same as the alarm below), but NOT
      // Urgent-only: any task can carry these, they just post a normal
      // "Reminder: <task>" notification at each moment, no ring/snooze/
      // end. Each slot is scheduled under a stable id derived from this
      // task's id AND its position in the array (NOT its timestamp) --
      // re-running this loop (every feed refresh) re-registers the exact
      // same OS alarm under the same id instead of stacking a duplicate.
      // Using the position rather than the timestamp is what lets a
      // changed/removed reminder actually cancel its old OS notification
      // below, instead of just silently abandoning it under an id that's
      // never addressed again.
      if (isMine) {
        final rawExtra = t['extraReminders'];
        final extraList = rawExtra is List ? rawExtra : const [];
        for (var i = 0; i < extraList.length; i++) {
          final slotId = '${id}_extra_$i'.hashCode & 0x7fffffff;
          final when = DateTime.tryParse(extraList[i].toString());
          if (when == null || when.isBefore(now)) {
            // No longer a future reminder (cleared, or already passed) --
            // cancel whatever was previously scheduled under this slot so
            // editing/removing a reminder actually stops the old alarm,
            // rather than leaving it armed under an id nothing re-touches.
            await NotificationService.instance.cancel(slotId);
            continue;
          }
          await NotificationService.instance.scheduleAt(
            id: slotId,
            title: 'Reminder: $title',
            body: spaceName.isNotEmpty ? spaceName : title,
            when: when,
          );
        }
        // Slots beyond the current (possibly shrunk) list length may still
        // hold a stale OS alarm from a previous, longer extraReminders
        // array -- cancel a bounded range past the current length so a
        // removed trailing reminder doesn't keep ringing either.
        for (var i = extraList.length; i < extraList.length + 10; i++) {
          await NotificationService.instance.cancel('${id}_extra_$i'.hashCode & 0x7fffffff);
        }
      }

      // The loud full-screen alarm (sound, lock-screen takeover, Snooze/
      // End) rings at reminderAt -- a date/time set independently of
      // dueDate specifically so the alarm doesn't have to match when the
      // work is actually due. Assignee-only -- deliberately NOT restricted
      // to Urgent any more: any task with a reminderAt set gets the full
      // alarm treatment, regardless of priority. (Previously Urgent-only;
      // removed per explicit request -- the alarm should fire purely off
      // the reminder date/time someone set, with no priority condition
      // layered on top.)
      if (!isMine) continue;
      final reminderRaw = t['reminderAt'];
      final reminder = reminderRaw == null ? null : DateTime.tryParse(reminderRaw.toString());
      if (reminder == null) continue;

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

      if (reminder.isBefore(now)) {
        final alreadyAlerted = alertedIds.contains(id);
        // Deliberately NOT added to stillAlertedIds while still snoozed --
        // stillAlertedIds is what gets persisted as the "already alerted"
        // record below, and marking a still-snoozed task as alerted before
        // it actually rings again would make the `!alertedIds.contains(id)`
        // check just below silently skip it forever once the snooze window
        // passes (confirmed live: this exact bug was why a snoozed alarm
        // never came back). Also NOT added while it's genuinely new
        // (never alerted) AND outside the notification window -- marking
        // it alerted without ever actually ringing it would silence this
        // alarm permanently instead of just deferring it to the next
        // allowed moment. An already-alerted task stays marked alerted
        // regardless of the window; it doesn't need to fire again.
        if (!stillSnoozed && (alreadyAlerted || withinWindow || isFirstRunOverdue)) stillAlertedIds.add(id);

        // Catch-up path: this task's reminder time passed without the
        // alarm ever having been armed for it (e.g. it was created/
        // assigned from the web app, so this device never had a chance to
        // schedule it ahead of time via the `else` branch below). Fires
        // once; `alertedIds` stops it from re-ringing on every feed
        // refresh. Suppressed entirely outside the notification window --
        // stays pending (not marked alerted, see above) so a later poll
        // inside the window catches it up instead of it ringing late for
        // one moment and then never again.
        if (!stillSnoozed && !alreadyAlerted && !isFirstRunOverdue && withinWindow) {
          // Re-checked fresh, right before actually ringing -- `alertedIds`
          // was snapshotted when this whole pass started, and myTasksProvider's
          // own network fetch (the very first thing this pass does) can
          // take a moment, during which a concurrent End tap on the Alarm
          // screen (markOverdueAlarmHandled) can land for this exact task.
          // Without this, the stale alreadyAlerted=false captured above
          // would still ring a SECOND alarm for a task the person just
          // dismissed seconds earlier.
          final freshlyAlerted = (await _loadAlertedIds(currentUserId)).contains(id);
          if (!freshlyAlerted) {
            // ignore: avoid_print
            print('[FEED] firing overdue alarm for taskId=$id "$title" (foreground feed pass)');
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
        }
      } else {
        // Not due yet -- arm the alarm for the exact reminder moment
        // (exact-time AlarmManager scheduling, so this still fires even
        // if the app gets closed before then). Deferred to the next
        // allowed instant if the reminder itself was set for a holiday,
        // a weekly off day, or outside office hours -- once armed at an
        // exact wall-clock moment, the OS rings it right on time no
        // matter what our own app logic thinks later, so this is the
        // only point that can actually prevent that.
        await NotificationService.instance.scheduleOverdueAlarmAt(
          taskId: id,
          taskName: title,
          spaceName: spaceName,
          when: schedule.resolveNextAllowedInstant(reminder),
        );
      }
    }

    // Re-check who's actually snoozed with a FRESH read, right before
    // persisting -- this whole pass can take a while (myTasksProvider's
    // own network fetch runs before any of the code above), so a Snooze
    // tap on the Alarm screen can land WHILE this pass is still in
    // flight, using data it captured before the snooze. Without this,
    // finishing this pass AFTER a concurrent snooze just cleared a
    // task's alerted flag would silently write it straight back in,
    // permanently undoing the snooze's re-fire. Confirmed live: a task
    // snoozed for 1 minute got marked "already alerted" again within ~2
    // seconds by an in-flight feed refresh that started fetching tasks
    // before the snooze completed, and never rang again.
    final freshSnoozePrefs = await SharedPreferences.getInstance();
    await freshSnoozePrefs.reload();
    final freshRawSnoozeMap = freshSnoozePrefs.getString(scopedKey(_snoozedUntilKey, currentUserId));
    final freshlySnoozedIds = <String>{};
    if (freshRawSnoozeMap != null) {
      try {
        final map = jsonDecode(freshRawSnoozeMap) as Map<String, dynamic>;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final entry in map.entries) {
          final untilMs = entry.value as int?;
          if (untilMs != null && nowMs < untilMs) freshlySnoozedIds.add(entry.key);
        }
      } catch (_) {}
    }
    // Merged with a FRESH read, not overwritten outright -- this whole
    // pass (myTasksProvider's own fetch runs first) can take a while,
    // during which markOverdueAlarmHandled (the Alarm screen's End
    // button) can write a task's id straight to disk. A plain
    // `_saveAlertedIds(stillAlertedIds...)` would silently erase that
    // mark for any task this pass's own (now-stale) view decided not to
    // include -- e.g. one outside the notification window -- making the
    // alarm this person just dismissed come right back. Only ids added
    // to disk AFTER this pass started are merged in (the "concurrent"
    // set below): an id that was already present in the `alertedIds`
    // snapshot at the top of this pass but isn't in stillAlertedIds was
    // deliberately pruned by this pass's own logic (task completed,
    // reminder changed) and must still be dropped.
    final latestAlertedIds = await _loadAlertedIds(currentUserId);
    final concurrentlyAdded = latestAlertedIds.difference(alertedIds);
    await _saveAlertedIds(stillAlertedIds.union(concurrentlyAdded).difference(freshlySnoozedIds), currentUserId);
    if (snoozeMapChanged) {
      await prefsForSnooze.setString(scopedKey(_snoozedUntilKey, currentUserId), jsonEncode(snoozedUntil));
    }
    if (isFirstRunOverdueLegacy) await markFirstRunBaselineDone('overdue_alarm', currentUserId);
    if (isFirstRunAnyPriority) await markFirstRunBaselineDone('overdue_alarm_any_priority', currentUserId);
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
        refId: id,
      ));
    }
  }

  items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return items;
});

final unreadNotificationCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final items = await ref.watch(notificationsFeedProvider.future);
  final currentUserId = ref.watch(authProvider).user?.id;
  final seen = await _loadSeenIds(currentUserId);
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

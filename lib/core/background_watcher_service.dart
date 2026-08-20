import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'notification_schedule.dart';
import 'notification_service.dart';
import 'task_update_tracker.dart';
import '../providers/tasks_provider.dart';

// Same key notifications_provider.dart uses for its own catch-up tracking
// -- kept identical on purpose so a task alerted from this polling loop
// isn't re-alerted again the next time the app is opened and that
// provider runs, and vice versa. Not imported directly since that file
// pulls in Riverpod/tasks_provider, which this background isolate has no
// use for and shouldn't need to initialize.
const _alertedOverdueIdsKey = 'overdue_alerted_task_ids';
// Same key notifications_provider.dart's manager-side escalation check
// uses -- kept identical so the two loops share one "already alerted"
// record for this category too.
const _alertedEscalationIdsKey = 'escalation_alerted_task_ids';
// Same key notifications_provider.dart's delegator-side approval check
// uses -- kept identical so the two loops share one "already alerted"
// record for this category too.
const _alertedApprovalIdsKey = 'approval_alerted_task_ids';
// Same key notification_service.dart's snoozeOverdueAlarm writes to --
// taskId -> epoch-millis "don't re-ring before this time" map, JSON-encoded.
// See that file's doc comment for why this exists: without it, a snoozed
// task's id sitting in _alertedOverdueIdsKey would make this loop think it
// was already handled and never bring the alarm back through this (the
// reliable) path once the snooze window passed.
const _snoozedUntilKey = 'overdue_snoozed_until_task_ids';
// businessDayKeyFor(...) of the last day a digest was actually sent --
// compared against today's key so the 5-minute detection window in
// isWithinOfficeStartWindow/isWithinOfficeEndWindow can't send more than
// one morning/evening digest per business day.
const _digestMorningSentKey = 'digest_morning_sent_day';
const _digestEveningSentKey = 'digest_evening_sent_day';

const _watcherChannelId = 'hqepl_watcher';

// Fixed id AndroidAlarmManager.periodic uses to identify this alarm --
// stable across app restarts so re-arming it (see armWatchdog below)
// reschedules the same alarm instead of stacking up duplicates.
const _watchdogAlarmId = 7250;
// Fixed id for the self-rescheduling tick alarm below -- same reasoning as
// _watchdogAlarmId, and deliberately a different number so the two never
// collide and cancel/overwrite each other.
const _tickAlarmId = 7251;

/// Why this exists: the overdue alarm was originally built entirely on
/// AlarmManager (via flutter_local_notifications' zonedSchedule), which
/// depends on the OS actually waking this app's process again at the
/// scheduled time. On this device (and OEM battery managers like it in
/// general), swiping the app away from Recents freezes the whole process
/// hard enough that even alarmClock-mode alarms never fire -- confirmed
/// by a live test where the alarm was scheduled correctly (right task,
/// right time, verified via logs) but Android still never delivered it.
/// Every available battery/autostart/exact-alarm permission was already
/// granted with no change, so this isn't fixable by asking for another
/// permission.
///
/// The fix is architectural: keep a lightweight Android foreground
/// service alive (a persistent, low-importance notification is the
/// unavoidable cost of this -- Android requires one for any foreground
/// service, it can't be hidden), and have IT poll this app's own backend
/// every minute for tasks that just became overdue, firing the same
/// full-screen alarm directly the moment it notices one. A foreground
/// service is a first-class Android component specifically meant to
/// survive exactly this kind of OEM process management, unlike a bare
/// scheduled alarm with no visible presence to protect it.
Future<void> initializeBackgroundWatcher() async {
  // This entire foreground-service + AlarmManager watchdog architecture is
  // Android-only -- android_alarm_manager_plus has no iOS implementation at
  // all (calling any of its methods there throws MissingPluginException),
  // and iOS has no equivalent of a persistent, self-reviving foreground
  // service to begin with. On iOS the app relies solely on
  // flutter_local_notifications' own OS-level zonedSchedule (see
  // notification_service.dart), which -- unlike Android -- keeps firing
  // even with the app fully killed and needs no background execution of
  // its own, so skipping this whole subsystem there costs nothing.
  if (!Platform.isAndroid) return;

  const channel = AndroidNotificationChannel(
    _watcherChannelId,
    'Task Watcher',
    description: 'Keeps checking for overdue tasks while the app is closed',
    importance: Importance.low,
  );
  await NotificationService.instance.rawPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: _watcherChannelId,
      initialNotificationTitle: 'Q Task360',
      initialNotificationContent: 'Watching for overdue tasks',
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

Future<void> startBackgroundWatcher() async {
  // Never configured on iOS (see initializeBackgroundWatcher) -- nothing to
  // start there.
  if (!Platform.isAndroid) return;
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) await service.startService();
}

Future<void> stopBackgroundWatcher() async {
  if (!Platform.isAndroid) return;
  final service = FlutterBackgroundService();
  if (await service.isRunning()) service.invoke('stopService');
  await AndroidAlarmManager.cancel(_watchdogAlarmId);
  await AndroidAlarmManager.cancel(_tickAlarmId);
}

/// Schedules the independent OS-level watchdog: every 2 hours, comfortably
/// under Android 15's ~6-hour hard limit on how long a "dataSync"
/// foreground service may run before the system force-stops it (the
/// underlying reason the watcher can go silent for hours with no error,
/// no crash, and nothing in the app's own UI to notice). AlarmManager is a
/// completely separate OS subsystem from that service's own process --
/// unlike a resume-triggered check (see main.dart), this keeps firing and
/// restarting the watcher even if the person never reopens the app at
/// all. `exact: true` + `wakeup: true` mirrors the overdue alarm's own
/// alarmClock-mode scheduling (see scheduleOverdueAlarmAt) so Doze can't
/// defer this either, and `rescheduleOnReboot: true` re-arms it after the
/// phone restarts, same as the watcher service's own autoStartOnBoot.
/// Safe to call on every cold start -- periodic() with the same id just
/// re-arms the existing alarm rather than stacking up duplicates.
Future<void> armWatchdog() async {
  // android_alarm_manager_plus has no iOS implementation -- calling
  // .initialize() there throws MissingPluginException. This was previously
  // called unconditionally from main.dart before runApp(), which crashed
  // the app on every iOS launch.
  if (!Platform.isAndroid) return;
  await AndroidAlarmManager.initialize();
  await AndroidAlarmManager.periodic(
    const Duration(hours: 2),
    _watchdogAlarmId,
    _watchdogTick,
    exact: true,
    wakeup: true,
    rescheduleOnReboot: true,
  );
}

// Runs in its own separate background isolate (distinct from the
// foreground service's own isolate above) -- has no app state alive, so
// it only does the one thing it needs to: check whether someone's
// actually signed in, and if so, make sure the watcher is running.
// startBackgroundWatcher()'s own isRunning() check keeps this a no-op
// the vast majority of the time, when the service never needed reviving.
@pragma('vm:entry-point')
void _watchdogTick() async {
  DartPluginRegistrant.ensureInitialized();
  final token = await ApiClient.instance.readToken();
  if (token == null) return;
  await startBackgroundWatcher();
}

@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.instance.init();

  if (service is AndroidServiceInstance) {
    service.on('stopService').listen((event) => service.stopSelf());
  }

  // A few seconds' grace before the very first tick's token read -- this
  // service is started right at the end of login() (see auth_provider.dart),
  // in a SEPARATE isolate from the one that just wrote that token to
  // flutter_secure_storage. Reading the exact same encrypted file from two
  // isolates in near lock-step, right when it was just written, is exactly
  // the kind of timing that can trip resetOnError's error-recovery path
  // (api_client.dart) into wiping the whole store over a transient
  // decrypt hiccup -- deleting a token that was, a second ago, perfectly
  // valid. Confirmed in practice: logging in showed the dashboard, then
  // kicked straight back to login with "session expired" 2-3 seconds
  // later. This delay only affects the FIRST tick after a fresh service
  // start (fresh login, cold-start restore, or watchdog revival) -- every
  // tick after it still runs on the normal ~60s cadence.
  await Future.delayed(const Duration(seconds: 5));
  await _runTick();
  await _scheduleNextTick();
}

// Chains one exact, wakeup-capable AlarmManager alarm after another instead
// of a plain Dart Timer.periodic -- a live test on this app's own Vivo test
// device showed the previous Timer-based loop go silent for 8+ minutes at a
// stretch even while the foreground service's own process stayed alive the
// whole time (same pid throughout, confirmed via logcat), which a bare
// in-process timer has no protection against. AlarmManager.setExactAndAllowWhileIdle
// (what exact+wakeup map to under the hood) is the same OS primitive real
// alarm-clock apps depend on to survive Doze/App Standby, and is a much
// harder thing for OEM battery management to defer than an arbitrary timer
// with no special standing. Re-scheduled from inside the callback itself
// (rather than a fixed `periodic`) so each tick only arms the next one once
// this one has actually finished -- a slow poll can't cause two ticks to
// overlap.
Future<void> _scheduleNextTick() => AndroidAlarmManager.oneShot(
      const Duration(minutes: 1),
      _tickAlarmId,
      _tickAlarmCallback,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );

// Runs in its own AlarmManager-callback isolate, same as _watchdogTick --
// has no app state alive, so it re-initializes what it needs (plugins via
// DartPluginRegistrant, the notification plugin itself) before doing any
// actual work, same reasoning as _onServiceStart's own init calls.
@pragma('vm:entry-point')
void _tickAlarmCallback() async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.instance.init();
  await _runTick();
  await _scheduleNextTick();
}

Future<void> _runTick() async {
  // Printed (not debugPrint-gated) and timestamped so `adb logcat` run
  // during a live screen-locked test shows exactly when each poll ran
  // and, on failure, why -- this loop's own errors were being swallowed
  // silently below, which made "the alarm just didn't ring" undiagnosable
  // beyond guessing at OS/OEM settings from the outside.
  final startedAt = DateTime.now();
  try {
    final tasks = await _fetchMyTasks();
    print('[WATCHER] tick ok at $startedAt, ${tasks.length} tasks fetched');
    // Company-wide holidays/weekly-off/office-hours window (see
    // notification_schedule.dart) -- fetched once per tick and reused by
    // every check below, same rule notifications_provider.dart's
    // foreground pass applies.
    final schedule = await fetchNotificationSchedule();
    // One SharedPreferences.getInstance() + .reload() for the whole tick,
    // not one per check (each of the five checks below used to call both
    // independently). .reload() is the expensive part on Android -- it
    // forces a full re-read from disk rather than returning the isolate's
    // already-cached copy -- so this was 5-6 separate disk reads every
    // single tick, every ~60 seconds, indefinitely, which is real,
    // avoidable I/O competing with whatever the person is actively doing
    // in the foreground app at the same moment. All five checks still see
    // one consistent, freshly-reloaded snapshot taken at the top of this
    // tick -- nothing here depends on seeing a write from mid-tick.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await _checkOverdueTasksOnce(tasks, schedule, prefs);
    await _checkTaskUpdatesOnce(tasks, schedule, prefs);
    await _checkTeamEscalationsOnce(schedule, prefs);
    await _checkPendingApprovalsOnce(schedule, prefs);
    await _checkDailyDigestOnce(tasks, schedule, prefs);
  } catch (e, st) {
    // Best-effort: a single failed poll (offline, expired token, server
    // hiccup) shouldn't kill the loop -- _scheduleNextTick() below still
    // runs regardless, so the next tick a minute later just tries again.
    // Still logged, not silently dropped -- see above.
    print('[WATCHER] tick FAILED at $startedAt: $e');
    print(st);
  }
}

Future<List<Map<String, dynamic>>> _fetchMyTasks() async {
  final res = await ApiClient.instance.dio.get('/tasks/mine/all');
  final data = res.data['data'] ?? res.data['tasks'] ?? [];
  return List<Map<String, dynamic>>.from(data);
}

Future<void> _checkOverdueTasksOnce(List<Map<String, dynamic>> tasks, NotificationSchedule schedule, SharedPreferences prefs) async {
  final alertedIds = (prefs.getStringList(_alertedOverdueIdsKey) ?? []).toSet();
  final stillOverdueIds = <String>{};
  final now = DateTime.now();
  var urgentCount = 0;
  final currentUserId = await ApiClient.instance.readCurrentUserId();

  final rawSnoozeMap = prefs.getString(_snoozedUntilKey);
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
    if (isComplete) continue;

    // The loud full-screen alarm is reserved for Urgent tasks only -- see
    // the matching check in notifications_provider.dart's foreground pass.
    if ((t['priority'] ?? '').toString() != 'Urgent') continue;
    // `tasks` (/tasks/mine/all) includes subordinates' tasks too for a
    // manager/senior -- without this, a junior's Urgent overdue task
    // would also ring the full-screen alarm on their senior's phone. The
    // alarm is assignee-only; see the matching guard in
    // notifications_provider.dart's foreground pass.
    final assigneeIdRaw = t['assigneeId'];
    final taskAssigneeId = (assigneeIdRaw is Map ? assigneeIdRaw['_id'] : assigneeIdRaw)?.toString();
    if (taskAssigneeId == null || taskAssigneeId != currentUserId) continue;
    urgentCount++;

    // The alarm rings at reminderAt now, not dueDate -- see the matching
    // change in notifications_provider.dart's foreground pass.
    final reminderRaw = t['reminderAt'];
    if (reminderRaw == null) continue;
    final due = DateTime.tryParse(reminderRaw.toString());
    if (due == null || !due.isBefore(now)) continue;

    final title = (t['title'] ?? t['name'] ?? 'Untitled task').toString();
    final id = (t['_id'] ?? t['id'] ?? title).toString();
    final spaceName = (t['spaceName'] ?? '').toString();

    final snoozeUntilMs = snoozedUntil[id] as int?;
    if (snoozeUntilMs != null && now.millisecondsSinceEpoch < snoozeUntilMs) {
      // Snoozed and still within the window -- hold off entirely, and
      // deliberately BEFORE stillOverdueIds.add(id) below: stillOverdueIds
      // gets merged into alertedIds ("already rang, don't ring again") at
      // the end of this function, so adding this id to it while still
      // snoozed would mark the task as alerted before it ever actually
      // rings again -- silently eating the re-fire the instant the snooze
      // window passes, since the `!alertedIds.contains(id)` check just
      // below would then see it as already handled. (This is exactly what
      // was happening before this fix -- confirmed live: the task showed
      // "already alerted, skipping re-fire" on the very first tick after
      // its snooze window ended, meaning it never actually rang again.)
      print('[WATCHER] taskId=$id snoozed until $snoozeUntilMs, skipping re-fire');
      continue;
    }
    if (snoozeUntilMs != null) {
      // Snooze window has passed -- clean up so this branch is skipped on
      // future ticks once the alarm below fires and re-populates alertedIds.
      snoozedUntil.remove(id);
      snoozeMapChanged = true;
    }

    final alreadyAlerted = alertedIds.contains(id);
    if (!alreadyAlerted && !schedule.isWithinWindow(now)) {
      // Outside the notification window and never actually alerted yet --
      // deliberately left OUT of stillOverdueIds so it stays pending
      // rather than getting marked "already alerted" for an alarm that
      // never rang; a later tick once back inside the window catches it
      // up instead. See notifications_provider.dart's foreground pass
      // for the same reasoning.
      print('[WATCHER] taskId=$id overdue but outside notification window, deferring');
      continue;
    }
    stillOverdueIds.add(id);

    if (!alreadyAlerted) {
      print('[WATCHER] firing overdue alarm for taskId=$id "$title" due=$due (now=$now)');
      await NotificationService.instance.showOverdueAlarmNow(taskId: id, taskName: title, spaceName: spaceName);
    } else {
      // Already fired for this task in an earlier tick -- expected on every
      // tick after the first for the same overdue task, not a failure.
      print('[WATCHER] taskId=$id already alerted this overdue period, skipping re-fire');
    }
  }

  if (snoozeMapChanged) {
    await prefs.setString(_snoozedUntilKey, jsonEncode(snoozedUntil));
  }
  // Printed every tick (not just on a hit) so a run with zero Urgent tasks,
  // or Urgent tasks that just aren't overdue yet, is distinguishable from
  // one where a task was overdue but something above silently swallowed it.
  print('[WATCHER] overdue check: $urgentCount urgent task(s) seen, ${stillOverdueIds.length} currently overdue');

  // Merge rather than replace: notifications_provider.dart's own foreground
  // pass writes this same key independently, and the two loops running at
  // different moments shouldn't be able to erase each other's "already
  // alerted" record for a task the other one is the one that saw.
  await prefs.setStringList(_alertedOverdueIdsKey, {...alertedIds, ...stillOverdueIds}.toList());
}

// "Compulsory" per-task notifications (new assignment, or any edit) --
// same detectTaskChanges() call notifications_provider.dart's foreground
// feed uses, sharing that function's persisted record so a change caught
// by whichever path runs first isn't re-announced by the other. Still
// respects the person's "Allow notifications" master toggle, read
// directly from SharedPreferences since this isolate has no Riverpod
// ProviderScope to watch settingsProvider through.
Future<void> _checkTaskUpdatesOnce(List<Map<String, dynamic>> tasks, NotificationSchedule schedule, SharedPreferences prefs) async {
  if (!(prefs.getBool('notif_master') ?? true)) return;
  // Same split as notifications_provider.dart's foreground pass -- see
  // settings_provider.dart's doc comment on taskAssigned/taskUpdates.
  // Deliberately still calls detectTaskChanges below even when muted by
  // the toggle, rather than returning early -- that call is what advances
  // its own persisted "already seen" snapshot (task_update_tracker.dart),
  // so skipping it entirely while muted would let changes pile up and all
  // flood in at once the moment notifications are turned back on (a
  // deliberate "drop forever while muted" design).
  //
  // Outside the notification window is different: those changes SHOULD
  // still be reported, just later -- so detectTaskChanges is skipped
  // ENTIRELY in that case (not called at all), leaving its snapshot
  // un-advanced, so the very next tick that runs back inside the window
  // sees them as still-unseen and reports them then instead of losing
  // them.
  final myTaskAllowed = prefs.getBool('notif_my_task') ?? true;
  // Same team-member mirror as notifications_provider.dart's foreground
  // pass -- see settings_provider.dart's doc comment on
  // teamTaskNotifications.
  final teamTaskAllowed = prefs.getBool('notif_team_task') ?? true;
  final anyTaskActivityWanted = myTaskAllowed || teamTaskAllowed;
  if (anyTaskActivityWanted && !schedule.isWithinWindow(DateTime.now())) return;

  final assignedAllowed = prefs.getBool('notif_task_assigned') ?? true;
  final updatesAllowed = prefs.getBool('notif_task_updates') ?? true;
  final teamAssignedAllowed = prefs.getBool('notif_team_task_assigned') ?? true;
  final teamUpdatesAllowed = prefs.getBool('notif_team_task_updates') ?? true;

  final currentUserId = await ApiClient.instance.readCurrentUserId();
  final assigneeNameByTaskId = {
    for (final t in tasks)
      (t['_id'] ?? t['id'] ?? '').toString(): (t['assigneeId'] is Map ? t['assigneeId']['employeeName'] : null)?.toString(),
  };
  for (final change in await detectTaskChanges(tasks, currentUserId: currentUserId)) {
    final isMine = currentUserId != null && change.assigneeId == currentUserId;
    if (isMine) {
      if (!myTaskAllowed) continue;
      if (change.isNew ? !assignedAllowed : !updatesAllowed) continue;
      final body = change.activityMessage ??
          (change.isNew ? 'Assigned to you' : 'Task updated') +
              (change.spaceName.isNotEmpty ? ' · ${change.spaceName}' : '');
      await NotificationService.instance.showTaskUpdateNotification(
        taskId: change.taskId,
        title: change.isNew ? 'New task: ${change.title}' : change.title,
        body: body,
      );
    } else {
      if (!teamTaskAllowed) continue;
      if (change.isNew ? !teamAssignedAllowed : !teamUpdatesAllowed) continue;
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
}

// Manager-side alert while the app is fully closed -- mirrors the
// foreground version in notifications_provider.dart, sharing the same
// _alertedEscalationIdsKey record so a manager isn't notified twice for
// the same overdue task once from each path. Safe to call for anyone;
// the endpoint just returns an empty list for a non-manager.
Future<void> _checkTeamEscalationsOnce(NotificationSchedule schedule, SharedPreferences prefs) async {
  final escalations = await fetchTeamOverdueEscalations();
  if (escalations.isEmpty) return;

  final alertedIds = (prefs.getStringList(_alertedEscalationIdsKey) ?? []).toSet();
  final stillEscalatedIds = <String>{};
  // Its own toggle -- see settings_provider.dart's doc comment on
  // teamEscalations.
  final escalationsAllowed = prefs.getBool('notif_team_escalations') ?? true;
  final withinWindow = schedule.isWithinWindow(DateTime.now());

  for (final t in escalations) {
    final id = (t['_id'] ?? '').toString();
    if (id.isEmpty) continue;
    final alreadyAlerted = alertedIds.contains(id);
    if (alreadyAlerted) {
      stillEscalatedIds.add(id);
      continue;
    }
    if (!escalationsAllowed) {
      // Muted by the toggle -- deliberately still marked seen (same
      // "drop forever while muted" reasoning as _checkTaskUpdatesOnce),
      // independent of the notification window: the person doesn't want
      // this at all, not "later instead of now".
      stillEscalatedIds.add(id);
      continue;
    }
    if (!withinWindow) continue; // allowed by the toggle, but outside the window -- leave pending
    stillEscalatedIds.add(id);
    final title = (t['name'] ?? 'Untitled task').toString();
    final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
    final spaceName = (t['spaceName'] ?? '').toString();
    await NotificationService.instance.showTaskUpdateNotification(
      taskId: 'escalation_$id',
      title: 'Team overdue: $title',
      body: '$assigneeName · 1 day overdue${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
    );
  }

  await prefs.setStringList(_alertedEscalationIdsKey, {...alertedIds, ...stillEscalatedIds}.toList());
}

// Delegator-side alert while the app is fully closed -- mirrors the
// foreground version in notifications_provider.dart, sharing the same
// _alertedApprovalIdsKey record. Safe to call for anyone; the endpoint
// just returns an empty list for someone with no pending delegated
// completions.
Future<void> _checkPendingApprovalsOnce(NotificationSchedule schedule, SharedPreferences prefs) async {
  final approvals = await fetchPendingApprovals();
  if (approvals.isEmpty) return;

  final alertedIds = (prefs.getStringList(_alertedApprovalIdsKey) ?? []).toSet();
  final stillPendingIds = <String>{};
  // Its own toggle -- see settings_provider.dart's doc comment on
  // approvalAlerts.
  final approvalsAllowed = prefs.getBool('notif_approval_alerts') ?? true;
  final withinWindow = schedule.isWithinWindow(DateTime.now());

  for (final t in approvals) {
    final id = (t['_id'] ?? '').toString();
    if (id.isEmpty) continue;
    final alreadyAlerted = alertedIds.contains(id);
    if (alreadyAlerted) {
      stillPendingIds.add(id);
      continue;
    }
    if (!approvalsAllowed) {
      // Muted by the toggle -- same "drop forever while muted" reasoning
      // as _checkTeamEscalationsOnce, independent of the window.
      stillPendingIds.add(id);
      continue;
    }
    if (!withinWindow) continue; // allowed by the toggle, but outside the window -- leave pending
    stillPendingIds.add(id);
    final title = (t['name'] ?? 'Untitled task').toString();
    final assigneeName = (t['assigneeId']?['employeeName'] ?? 'Someone').toString();
    final spaceName = (t['spaceName'] ?? '').toString();
    await NotificationService.instance.showTaskUpdateNotification(
      taskId: 'approval_$id',
      title: 'Approval needed: $title',
      body: '$assigneeName marked this complete${spaceName.isNotEmpty ? ' · $spaceName' : ''}',
    );
  }

  await prefs.setStringList(_alertedApprovalIdsKey, {...alertedIds, ...stillPendingIds}.toList());
}

// Morning "today's tasks" summary and end-of-day "how the day went"
// summary, anchored to the company's configured office start/end times
// (schedule.isWithinOfficeStartWindow/isWithinOfficeEndWindow) rather than
// a fixed hour -- same schedule the office-hours suppression elsewhere in
// this file already reads, so the digest naturally moves if the company's
// hours change. Deliberately Android-only (this whole file is, per
// initializeBackgroundWatcher's own doc comment) -- an iOS zonedSchedule
// equivalent can't compute live task counts at fire time the way a
// polling tick can, only whatever was true when it was scheduled, so it's
// left out rather than shipping a digest that's stale by definition.
//
// Scoped to tasks assigned directly to this device's own signed-in person
// (not the wider manager/subordinate mix `tasks` carries for
// _checkOverdueTasksOnce etc.) -- this is "your own day", not a
// team roll-up.
Future<void> _checkDailyDigestOnce(List<Map<String, dynamic>> tasks, NotificationSchedule schedule, SharedPreferences prefs) async {
  // No office hours configured means no anchor time to send at -- rather
  // than guessing a fallback hour, the digest simply stays off until a
  // Full Access person sets one on the Teams page.
  if (!schedule.officeHoursEnabled) return;

  final now = DateTime.now();
  final atStart = schedule.isWithinOfficeStartWindow(now);
  final atEnd = schedule.isWithinOfficeEndWindow(now);
  if (!atStart && !atEnd) return;

  if (!(prefs.getBool('notif_master') ?? true)) return;
  // Its own toggle -- see settings_provider.dart's doc comment on
  // dailyDigest.
  if (!(prefs.getBool('notif_daily_digest') ?? true)) return;

  final currentUserId = await ApiClient.instance.readCurrentUserId();
  if (currentUserId == null) return;

  final todayKey = businessDayKeyFor(now);
  final mine = tasks.where((t) {
    final raw = t['assigneeId'];
    final id = (raw is Map ? raw['_id'] : raw)?.toString();
    return id != null && id == currentUserId;
  }).toList();

  if (atStart && prefs.getString(_digestMorningSentKey) != todayKey) {
    await NotificationService.instance.showMorningDigest(
      title: 'Good morning',
      body: _buildMorningDigestBody(mine, now),
    );
    await prefs.setString(_digestMorningSentKey, todayKey);
  }

  if (atEnd && prefs.getString(_digestEveningSentKey) != todayKey) {
    await NotificationService.instance.showEveningDigest(
      title: "Today's summary",
      body: _buildEveningDigestBody(mine, now),
    );
    await prefs.setString(_digestEveningSentKey, todayKey);
  }
}

bool _statusContains(Map<String, dynamic> t, String needle) => (t['status'] ?? '').toString().toLowerCase().contains(needle);

bool _isTaskComplete(Map<String, dynamic> t) => _statusContains(t, 'complete') || _statusContains(t, 'done');

DateTime? _dueDateOf(Map<String, dynamic> t) {
  final raw = t['dueDate'] ?? t['reminderAt'];
  return raw == null ? null : DateTime.tryParse(raw.toString());
}

String _pluralTask(int n) => n == 1 ? '1 task' : '$n tasks';

String _buildMorningDigestBody(List<Map<String, dynamic>> mine, DateTime now) {
  final todayKey = businessDayKeyFor(now);
  final active = mine.where((t) => !_isTaskComplete(t));
  final dueToday = active.where((t) {
    final due = _dueDateOf(t);
    return due != null && businessDayKeyFor(due) == todayKey;
  }).length;
  final inProgress = active.where((t) => _statusContains(t, 'progress')).length;

  if (dueToday == 0 && inProgress == 0) {
    return "You've got a clear board this morning -- no tasks due today. Have a great day.";
  }
  final duePart = '${_pluralTask(dueToday)} due today';
  final progressPart = inProgress == 1 ? '1 already in progress' : '$inProgress already in progress';
  return 'You have $duePart, $progressPart. Wishing you a productive day ahead.';
}

String _buildEveningDigestBody(List<Map<String, dynamic>> mine, DateTime now) {
  final todayKey = businessDayKeyFor(now);
  final completedToday = mine.where((t) {
    if (!_isTaskComplete(t)) return false;
    final updatedRaw = t['updatedAt'];
    final updated = updatedRaw == null ? null : DateTime.tryParse(updatedRaw.toString());
    return updated != null && businessDayKeyFor(updated) == todayKey;
  }).length;
  final active = mine.where((t) => !_isTaskComplete(t));
  final inProgress = active.where((t) => _statusContains(t, 'progress')).length;
  final overdue = active.where((t) {
    final due = _dueDateOf(t);
    return due != null && due.isBefore(now);
  }).length;

  final summary = '${_pluralTask(completedToday)} completed, ${_pluralTask(inProgress)} in progress, ${_pluralTask(overdue)} overdue';
  if (overdue > 0) {
    return "Here's how today went: $summary. Worth a look before tomorrow.";
  }
  return "Here's how today went: $summary. Thank you for a productive day.";
}

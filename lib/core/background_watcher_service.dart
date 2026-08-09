import 'dart:async';
import 'dart:ui';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
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
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) await service.startService();
}

Future<void> stopBackgroundWatcher() async {
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
    await _checkOverdueTasksOnce(tasks);
    await _checkTaskUpdatesOnce(tasks);
    await _checkTeamEscalationsOnce();
    await _checkPendingApprovalsOnce();
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

Future<void> _checkOverdueTasksOnce(List<Map<String, dynamic>> tasks) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final alertedIds = (prefs.getStringList(_alertedOverdueIdsKey) ?? []).toSet();
  final stillOverdueIds = <String>{};
  final now = DateTime.now();
  var urgentCount = 0;

  for (final t in tasks) {
    final status = (t['status'] ?? '').toString().toLowerCase();
    final isComplete = status.contains('complete') || status.contains('done');
    if (isComplete) continue;

    // The loud full-screen alarm is reserved for Urgent tasks only -- see
    // the matching check in notifications_provider.dart's foreground pass.
    if ((t['priority'] ?? '').toString() != 'Urgent') continue;
    urgentCount++;

    final dueRaw = t['dueDate'];
    if (dueRaw == null) continue;
    final due = DateTime.tryParse(dueRaw.toString());
    if (due == null || !due.isBefore(now)) continue;

    final title = (t['title'] ?? t['name'] ?? 'Untitled task').toString();
    final id = (t['_id'] ?? t['id'] ?? title).toString();
    final spaceName = (t['spaceName'] ?? '').toString();

    stillOverdueIds.add(id);
    if (!alertedIds.contains(id)) {
      print('[WATCHER] firing overdue alarm for taskId=$id "$title" due=$due (now=$now)');
      await NotificationService.instance.showOverdueAlarmNow(taskId: id, taskName: title, spaceName: spaceName);
    } else {
      // Already fired for this task in an earlier tick -- expected on every
      // tick after the first for the same overdue task, not a failure.
      print('[WATCHER] taskId=$id already alerted this overdue period, skipping re-fire');
    }
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
Future<void> _checkTaskUpdatesOnce(List<Map<String, dynamic>> tasks) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (!(prefs.getBool('notif_master') ?? true)) return;

  final currentUserId = await ApiClient.instance.readCurrentUserId();
  for (final change in await detectTaskChanges(tasks, currentUserId: currentUserId)) {
    final body = change.activityMessage ??
        (change.isNew ? 'Assigned to you' : 'Task updated') +
            (change.spaceName.isNotEmpty ? ' · ${change.spaceName}' : '');
    await NotificationService.instance.showTaskUpdateNotification(
      taskId: change.taskId,
      title: change.isNew ? 'New task: ${change.title}' : change.title,
      body: body,
    );
  }
}

// Manager-side alert while the app is fully closed -- mirrors the
// foreground version in notifications_provider.dart, sharing the same
// _alertedEscalationIdsKey record so a manager isn't notified twice for
// the same overdue task once from each path. Safe to call for anyone;
// the endpoint just returns an empty list for a non-manager.
Future<void> _checkTeamEscalationsOnce() async {
  final escalations = await fetchTeamOverdueEscalations();
  if (escalations.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final alertedIds = (prefs.getStringList(_alertedEscalationIdsKey) ?? []).toSet();
  final stillEscalatedIds = <String>{};

  for (final t in escalations) {
    final id = (t['_id'] ?? '').toString();
    if (id.isEmpty) continue;
    stillEscalatedIds.add(id);
    if (alertedIds.contains(id)) continue;
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
Future<void> _checkPendingApprovalsOnce() async {
  final approvals = await fetchPendingApprovals();
  if (approvals.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final alertedIds = (prefs.getStringList(_alertedApprovalIdsKey) ?? []).toSet();
  final stillPendingIds = <String>{};

  for (final t in approvals) {
    final id = (t['_id'] ?? '').toString();
    if (id.isEmpty) continue;
    stillPendingIds.add(id);
    if (alertedIds.contains(id)) continue;
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

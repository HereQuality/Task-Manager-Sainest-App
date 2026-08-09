import 'dart:convert';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'api_client.dart';

const _askedBatteryOptKey = 'asked_battery_opt_once';
const _askedFullScreenIntentKey = 'asked_full_screen_intent_once';

/// Set whenever the overdue alarm needs the app's UI to jump straight to
/// the full-screen Alarm screen: a cold start via the full-screen-intent
/// notification (checked in main.dart via getLaunchDetails), or the
/// notification firing/being tapped while the app is already running (set
/// from _handleAlarmAction below). router.dart listens to this alongside
/// auth state and redirects to /home/alarm once both are ready; the Alarm
/// screen clears it back to null after reading it. Deliberately a plain
/// ValueNotifier rather than a Riverpod provider -- the background
/// isolate that can invoke this has no ProviderScope/BuildContext to
/// reach one through.
final pendingAlarmNotifier = ValueNotifier<Map<String, dynamic>?>(null);

/// Wraps flutter_local_notifications. This schedules notifications that fire
/// from the device itself at a given time (task due reminders, the overdue
/// alarm below, a daily digest) — it does NOT receive push messages from the
/// server, since the backend has no push infrastructure yet (see README).
/// Good enough for "remind me before/when this is due"; not a substitute for
/// server-triggered pushes like "someone assigned you a task" while the app
/// is closed.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Exposed for background_watcher_service.dart's one-off channel setup,
  // which needs the plugin instance directly rather than any method this
  // class wraps around it.
  FlutterLocalNotificationsPlugin get rawPlugin => _plugin;

  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false, // requested explicitly via requestPermission()
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationResponse,
    );
    _initialized = true;
  }

  /// Converts a wall-clock DateTime (from a date/time picker, or parsed
  /// from an ISO string) into the TZDateTime zonedSchedule needs, using
  /// its actual absolute instant rather than trusting package timezone's
  /// notion of "local". `.toUtc()` on a Dart DateTime is answered by the
  /// OS itself using the device's real timezone, so this is correct
  /// without ever having to look up or set tz.local (which, left unset,
  /// silently defaults to UTC and would otherwise register the alarm for
  /// the wrong real-world moment -- off by the device's UTC offset,
  /// which looked exactly like "the alarm just never fires").
  tz.TZDateTime _tzFrom(DateTime when) => tz.TZDateTime.from(when.toUtc(), tz.UTC);

  Future<bool> requestPermission() async {
    final ios = await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final android = await androidImpl?.requestNotificationsPermission();
    // Exact-time scheduling (used by the overdue alarm and due-soon
    // reminders below) needs this separately on Android 12+ -- without
    // it the OS silently downgrades zonedSchedule to an inexact timer
    // that can drift by tens of minutes.
    await androidImpl?.requestExactAlarmsPermission();
    return (ios ?? true) && (android ?? true);
  }

  /// Asks the OS to stop applying Doze/App Standby battery optimization to
  /// this app. Without this, Android can defer or entirely drop the
  /// overdue alarm's AlarmManager trigger once the app's been closed for a
  /// while (device idle, screen off) -- this is the single biggest reason
  /// "works while the app is open, silent once it's fully closed" happens,
  /// separate from the OEM-level (Vivo/Xiaomi/Oppo) "autostart"/"background
  /// app" toggle below, which no API can set programmatically. Shows the
  /// OS's own confirmation dialog; returns whether it's granted afterward.
  Future<bool> requestBatteryOptimizationExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return true;
    final result = await Permission.ignoreBatteryOptimizations.request();
    return result.isGranted;
  }

  /// Same request as above, but only ever shows the dialog once per
  /// install -- meant for main.dart's unconditional cold-start call. On
  /// some phones (this app's own test device included), the OS's
  /// standard "ignoring battery optimizations" flag never actually
  /// reports as granted even after the person allows an equivalent OEM
  /// toggle from that phone's own Settings, since the two aren't wired
  /// together on that ROM -- calling the plain method above on every
  /// single launch in that situation means the dialog nags on every open
  /// with no way to make it stop. The Settings screen's own "Allow
  /// background alarms" button still calls the un-gated version directly,
  /// so a person can always retry deliberately; this one just stops
  /// asking automatically after the first attempt regardless of the
  /// outcome.
  Future<void> requestBatteryOptimizationExemptionOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedBatteryOptKey) ?? false) return;
    await requestBatteryOptimizationExemption();
    await prefs.setBool(_askedBatteryOptKey, true);
  }

  Future<bool> isBatteryOptimizationExempt() async =>
      Permission.ignoreBatteryOptimizations.status.then((s) => s.isGranted);

  /// Whether exact/alarm-clock scheduling is actually available -- on
  /// Android 12+ this needs a person-granted "Alarms & reminders" toggle
  /// (SCHEDULE_EXACT_ALARM in the manifest only requests it, doesn't grant
  /// it); if this comes back false, every zonedSchedule call above has
  /// silently been downgraded to an inexact timer that can drift by
  /// tens of minutes to hours.
  Future<bool> canScheduleExactAlarms() async {
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await androidImpl?.canScheduleExactNotifications() ?? true;
  }

  /// Best-effort attempt to jump straight to the phone manufacturer's own
  /// "Autostart" / "Protected apps" / "Background app management" screen --
  /// there is no standard Android API for this, only per-OEM settings
  /// activities with known package/class names (reverse-engineered by the
  /// wider Flutter/Android community, same technique libraries like
  /// disable_battery_optimization use). Without the person enabling this
  /// by hand, phones like Vivo/Xiaomi/Oppo/Huawei/OnePlus can fully kill
  /// the app (cancelling its AlarmManager alarms outright, even
  /// alarmClock-mode ones) the moment it's swiped away from Recents --
  /// something no in-app permission request can prevent. Tries each known
  /// OEM screen in turn and stops at the first one that actually opens;
  /// returns false if none of them exist on this device (unknown/other
  /// OEM, or a stock-Android phone that doesn't need this at all).
  Future<bool> openAutoStartSettings() async {
    const candidates = [
      ['com.vivo.permissionmanager', 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'],
      ['com.vivo.permissionmanager', 'com.vivo.permissionmanager.activity.PurviewTabActivity'],
      ['com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'],
      ['com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.BgStartUpManagerActivity'],
      ['com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity'],
      ['com.coloros.safecenter', 'com.coloros.safecenter.permission.startup.StartupAppListActivity'],
      ['com.oppo.safe', 'com.oppo.safe.permission.startup.StartupAppListActivity'],
      ['com.coloros.safecenter', 'com.coloros.safecenter.startupapp.StartupAppListActivity'],
      ['com.huawei.systemmanager', 'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'],
      ['com.oneplus.security', 'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'],
    ];
    for (final c in candidates) {
      try {
        await AndroidIntent(action: 'android.intent.action.MAIN', package: c[0], componentName: c[1]).launch();
        return true;
      } on PlatformException {
        continue;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// Checks (and if needed, asks for) Android 14's dedicated "Full screen
  /// notifications" permission -- a SEPARATE toggle from the
  /// USE_FULL_SCREEN_INTENT manifest permission. Declaring the permission
  /// alone isn't enough on Android 14+: without this toggle explicitly
  /// turned on by the person, the OS silently downgrades every
  /// fullScreenIntent notification to a normal one that just sits in the
  /// shade -- it never launches the full-screen Alarm activity, and while
  /// the screen is off/locked it can be entirely invisible until the
  /// person unlocks the phone on their own and pulls down the shade
  /// (exactly "nothing while locked, a plain notification once
  /// unlocked"). Delegates to flutter_local_notifications' own native
  /// implementation rather than a hand-rolled intent: it checks
  /// NotificationManager.canUseFullScreenIntent() first and only
  /// navigates to the settings screen if it's actually not granted,
  /// returning the real outcome once the person comes back -- a blind
  /// "just open the settings screen" gives no way to tell whether it
  /// actually got granted. Always resolves true pre-Android-14, where
  /// this toggle doesn't exist and the manifest permission alone applies.
  Future<bool> requestFullScreenIntentPermission() async {
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await androidImpl?.requestFullScreenIntentPermission() ?? true;
  }

  /// Same request as above, but only ever shows/navigates once per
  /// install -- meant for main.dart's unconditional cold-start call, same
  /// reasoning as requestBatteryOptimizationExemptionOnce: this is the
  /// permission most people never knew to grant by hand (it's Android 14's
  /// own newest, least-known toggle), so asking automatically the first
  /// time is what actually gets it granted for anyone who upgrades into
  /// this fix rather than relying on them to find the Settings screen's
  /// button themselves.
  Future<void> requestFullScreenIntentPermissionOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedFullScreenIntentKey) ?? false) return;
    await requestFullScreenIntentPermission();
    await prefs.setBool(_askedFullScreenIntentKey, true);
  }

  static const _channel = AndroidNotificationDetails(
    'hqepl_reminders',
    'Task & Ticket Reminders',
    channelDescription: 'Reminders for due tasks and ticket updates',
    importance: Importance.high,
    priority: Priority.high,
  );

  // New task assignments and any change to an existing task -- see
  // task_update_tracker.dart for the detection logic this backs. Separate
  // from _channel above since these fire for every task edit (status,
  // due date, priority, reassignment, ...), a much higher-volume, less
  // urgent category than a due-date reminder -- keeping them on their own
  // channel lets the person mute this specifically without losing due
  // reminders too.
  static const _taskUpdatesChannel = AndroidNotificationDetails(
    'hqepl_task_updates',
    'Task Updates',
    channelDescription: 'New tasks assigned to you, and changes to your existing tasks',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<void> showTaskUpdateNotification({
    required String taskId,
    required String title,
    required String body,
  }) async {
    await _plugin.show(
      'taskupdate_$taskId'.hashCode & 0x7fffffff,
      title,
      body,
      const NotificationDetails(android: _taskUpdatesChannel, iOS: DarwinNotificationDetails()),
    );
  }

  // Separate, louder channel for tasks that have actually passed their due
  // date/time -- distinct from the quieter "due soon" reminder above.
  // fullScreenIntent + category.alarm + max importance is what makes
  // Android treat this like a real alarm clock: launches the app over
  // the lock screen (see MainActivity's showWhenLocked/turnScreenOn in
  // AndroidManifest.xml) instead of just posting a heads-up banner.
  // Still carries Snooze/Complete actions too, for whenever it's seen as
  // a normal notification instead (screen already on, tray pull-down).
  static const _overdueActions = [
    AndroidNotificationAction('snooze_action', 'Snooze', showsUserInterface: false, cancelNotification: true),
    AndroidNotificationAction('complete_action', 'Complete', showsUserInterface: false, cancelNotification: true),
  ];

  // '_v3' suffix is deliberate: Android notification channels are immutable
  // after their first creation on a device -- importance/sound/etc. set
  // here in code have NO effect on a device that already created an earlier
  // version of this channel during prior testing/installs. Bumping the id
  // forces a fresh channel with the settings actually defined below (in
  // particular, the sound/audio-attributes change below -- '_v2' still
  // played the OS's plain default *notification* sound over the
  // *notification* audio stream, which is why it sounded like a regular
  // ping rather than a real alarm). Bump again if channel settings change
  // and still don't seem to take effect on an already-installed device.
  static const _overdueChannel = AndroidNotificationDetails(
    'hqepl_overdue_alarm_v3',
    'Overdue Task Alarm',
    channelDescription: 'Rings full-screen when a task passes its due date/time, repeating every 5 minutes until snoozed or completed',
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.alarm,
    visibility: NotificationVisibility.public,
    fullScreenIntent: true,
    playSound: true,
    // The device's own built-in alarm-clock tone (Settings > Sound >
    // Alarm sound), rather than the default *notification* sound this
    // channel used before -- this is what makes it actually sound like an
    // alarm instead of a chat ping. Doesn't need any bundled audio asset;
    // it's the same tone every alarm-clock app on the phone already uses.
    sound: UriAndroidNotificationSound('content://settings/system/alarm_alert'),
    // Routes playback through the ALARM audio stream instead of the
    // NOTIFICATION stream -- plays at the phone's alarm volume (a separate
    // slider from notification/media volume) and, same as a real alarm
    // clock, ignores Do Not Disturb/silent-mode muting of notifications.
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    actions: _overdueActions,
  );

  Future<void> showNow({required int id, required String title, required String body}) async {
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
    );
  }

  /// Schedules a one-off reminder at [when]. Pass a stable [id] derived from
  /// the task id so re-scheduling the same task overwrites, rather than
  /// duplicates, its reminder.
  Future<void> scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    if (when.isBefore(DateTime.now())) return;
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      _tzFrom(when),
      const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // Stable per-task id so scheduling/firing/cancelling the same task's
  // alarm always targets the same underlying OS notification instead of
  // piling up duplicates.
  static int _alarmId(String taskId) => 'overdue_$taskId'.hashCode & 0x7fffffff;

  String _alarmPayload({required String taskId, required String taskName, required String spaceName}) =>
      jsonEncode({'taskId': taskId, 'taskName': taskName, 'spaceName': spaceName});

  /// Fires the overdue alarm immediately -- used when a task is discovered
  /// already overdue (e.g. the app was closed when its due time passed).
  Future<void> showOverdueAlarmNow({
    required String taskId,
    required String taskName,
    required String spaceName,
  }) async {
    await _plugin.show(
      _alarmId(taskId),
      'Overdue: $taskName',
      spaceName.isNotEmpty ? 'Space: $spaceName · tap Complete or Snooze' : 'Tap Complete or Snooze',
      const NotificationDetails(android: _overdueChannel, iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive)),
      payload: _alarmPayload(taskId: taskId, taskName: taskName, spaceName: spaceName),
    );
  }

  /// Schedules the overdue alarm to fire at [when] -- the task's exact due
  /// date/time -- so it rings the moment the task actually becomes overdue.
  /// Also what "Snooze" calls internally, 5 minutes out.
  Future<void> scheduleOverdueAlarmAt({
    required String taskId,
    required String taskName,
    required String spaceName,
    required DateTime when,
  }) async {
    final fireAt = _tzFrom(when);
    try {
      await _plugin.zonedSchedule(
        _alarmId(taskId),
        'Overdue: $taskName',
        spaceName.isNotEmpty ? 'Space: $spaceName · tap Complete or Snooze' : 'Tap Complete or Snooze',
        fireAt,
        const NotificationDetails(android: _overdueChannel, iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive)),
        // alarmClock (AlarmManager.setAlarmClock) is the same, most-privileged
        // mechanism real alarm-clock apps use -- unlike exactAllowWhileIdle,
        // Android documents this as exempt from Doze/App Standby deferral
        // entirely, which is what "fires reliably even once the app's been
        // closed a while" actually needs. It also shows the small alarm-clock
        // icon in the status bar while pending.
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        payload: _alarmPayload(taskId: taskId, taskName: taskName, spaceName: spaceName),
      );
      // Deliberately printed (not debugPrint-gated) so it survives in
      // release console output too -- this is the one line that proves
      // the OS actually accepted the alarm registration, as opposed to
      // it silently no-op'ing or throwing something swallowed elsewhere.
      print('[ALARM] scheduled taskId=$taskId fireAt=$fireAt (device now=${DateTime.now()})');
    } catch (e, st) {
      print('[ALARM] FAILED to schedule taskId=$taskId fireAt=$fireAt: $e');
      print(st);
      rethrow;
    }
  }

  Future<void> cancelOverdueAlarm(String taskId) => _plugin.cancel(_alarmId(taskId));

  Future<void> cancel(int id) => _plugin.cancel(id);
  Future<void> cancelAll() => _plugin.cancelAll();

  /// Checked once at startup (see main.dart) -- was the app cold-started
  /// by the person tapping/launching the overdue alarm notification
  /// (including via its full-screen intent)? If so its payload is used
  /// to route straight to the Alarm screen instead of Home.
  Future<NotificationAppLaunchDetails?> getLaunchDetails() => _plugin.getNotificationAppLaunchDetails();

  /// Same "Complete" action the notification's button performs -- exposed
  /// so the full-screen Alarm screen's own Complete button can call the
  /// identical logic without going through a fake NotificationResponse.
  Future<void> completeOverdueTask(String taskId) async {
    await _completeTaskDirect(taskId);
    await cancelOverdueAlarm(taskId);
  }

  /// Same "Snooze" action the notification's button performs -- defaults to
  /// 5 minutes out (what the notification tray's own quick-action button
  /// still uses, with no room there to offer a duration choice), but the
  /// Alarm screen's own Snooze button lets the person pick 10 min/1 hr/2 hr
  /// and passes that choice through here instead.
  Future<void> snoozeOverdueAlarm({
    required String taskId,
    required String taskName,
    required String spaceName,
    Duration duration = const Duration(minutes: 5),
  }) async {
    await scheduleOverdueAlarmAt(
      taskId: taskId,
      taskName: taskName,
      spaceName: spaceName,
      when: DateTime.now().add(duration),
    );
  }
}

// ── Snooze / Complete action handling ────────────────────────────────────
// Registered as both the foreground (`onDidReceiveNotificationResponse`)
// and background (`onDidReceiveBackgroundNotificationResponse`) callback --
// Android can invoke the latter in a freshly-spawned isolate with no app
// state alive at all if the app was fully swiped away, which is why this
// re-reads everything it needs (auth token via ApiClient's own secure
// storage, the task/space names carried in the notification's payload)
// rather than touching any Riverpod provider. Note: how reliably Android
// actually wakes this isolate for a killed app varies by OEM battery
// optimization (Vivo/Xiaomi/Oppo are notably aggressive about this) --
// it's dependable while the app is foregrounded or backgrounded-but-alive,
// best-effort once fully killed.
@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse response) {
  WidgetsFlutterBinding.ensureInitialized();
  _handleAlarmAction(response);
}

void _onNotificationResponse(NotificationResponse response) {
  _handleAlarmAction(response);
}

Future<void> _handleAlarmAction(NotificationResponse response) async {
  final payload = response.payload;
  if (payload == null) return;

  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return;
  }

  final taskId = data['taskId'] as String?;
  if (taskId == null) return;
  final taskName = data['taskName'] as String? ?? 'Task';
  final spaceName = data['spaceName'] as String? ?? '';

  switch (response.actionId) {
    case 'snooze_action':
      await NotificationService.instance.snoozeOverdueAlarm(taskId: taskId, taskName: taskName, spaceName: spaceName);
      break;
    case 'complete_action':
      await NotificationService.instance.completeOverdueTask(taskId);
      break;
    default:
      // Plain tap on the notification body, or the full-screen intent
      // launching the app directly -- route to the Alarm screen instead
      // of wherever the app would normally land. If this fired in the
      // background isolate (app was fully killed), main.dart's own
      // getLaunchDetails() check picks it up instead once the app
      // actually starts; setting it here too covers the app-already-
      // running case, which getLaunchDetails() (a launch-time-only API)
      // wouldn't see.
      pendingAlarmNotifier.value = data;
      break;
  }
}

/// PUT /tasks/:id status=COMPLETE via the app's own ApiClient -- its
/// request interceptor already attaches the stored auth token from
/// secure storage, so this needs no separate token handling even when
/// running in the background isolate above.
Future<void> _completeTaskDirect(String taskId) async {
  try {
    await ApiClient.instance.dio.put('/tasks/$taskId', data: {'status': 'COMPLETE'});
  } catch (_) {
    // Best-effort: if this fails (offline, expired token), the alarm's
    // already been dismissed client-side and there's no UI here to
    // surface an error to -- the task will just still show as overdue
    // next time the app's own task list is fetched.
  }
}

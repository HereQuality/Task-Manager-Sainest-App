import 'dart:convert';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_alarmkit/flutter_alarmkit.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'api_client.dart';

const _askedBatteryOptKey = 'asked_battery_opt_once';
const _askedFullScreenIntentKey = 'asked_full_screen_intent_once';
const _askedAlarmKitKey = 'asked_alarmkit_auth_once';

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

  // AlarmKit (iOS 26+) is what actually gets a full-screen, Do-Not-
  // Disturb-breaking alarm UI on screen while the app is fully killed --
  // DarwinNotificationDetails below (even at .timeSensitive) only ever
  // posts a normal notification banner, since iOS gives third-party apps
  // no fullScreenIntent equivalent outside AlarmKit. Every call through
  // this is wrapped in try/catch: the plugin throws PlatformException on
  // iOS < 26 or when AlarmKit authorization was never granted, and in
  // both cases the existing zonedSchedule/show call right next to it is
  // left as the only alert -- so this is additive, never a replacement.
  final _alarmKit = FlutterAlarmkit();

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
    final granted = (ios ?? true) && (android ?? true);
    // Exact-time scheduling (used by the overdue alarm and due-soon
    // reminders below) needs this separately on Android 12+ -- without
    // it the OS silently downgrades zonedSchedule to an inexact timer
    // that can drift by tens of minutes. Skipped entirely if the person
    // just said no to notifications outright -- on some OEMs this jumps
    // straight to a system Settings screen rather than a dialog, and
    // chaining that (plus the battery-optimization and full-screen-intent
    // asks main.dart makes right after a granted result) onto a "no"
    // answer is what made denying notifications feel like the app itself
    // had crashed: several more native prompts/Settings screens firing
    // back-to-back with no app UI visible yet underneath any of them.
    if (granted) await androidImpl?.requestExactAlarmsPermission();
    return granted;
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
    // Android-only concept (Doze/App Standby) -- iOS has no equivalent
    // battery-optimization toggle, and permission_handler's
    // ignoreBatteryOptimizations permission only exists on Android.
    if (!Platform.isAndroid) return true;
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

  Future<bool> isBatteryOptimizationExempt() async {
    if (!Platform.isAndroid) return true;
    return Permission.ignoreBatteryOptimizations.status.then((s) => s.isGranted);
  }

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
    // android_intent_plus is explicitly Android-only (no iOS implementation
    // registered), and none of these OEM screens exist on iOS anyway.
    if (!Platform.isAndroid) return false;
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
    // None of the known OEM screens matched -- happens on newer firmware
    // that renamed/moved them (seen in practice on a Vivo/OriginOS build
    // where none of the vivo.permissionmanager/iqoo.secure candidates
    // above existed). Falling all the way through to a snackbar with
    // nowhere to go is a dead end, so this instead opens this app's own
    // standard Android "App info" settings screen -- every OEM skin
    // exposes battery/background-activity controls from there, even when
    // there's no dedicated "Autostart" page this app can jump straight
    // to. Not as direct as the real thing, but always one tap away
    // instead of a wall.
    try {
      await const AndroidIntent(
        action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
        data: 'package:com.hqepl.qtask360',
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
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

  /// One-time prompt for AlarmKit's own authorization (iOS 26+ only) --
  /// separate from, and in addition to, the regular notification
  /// permission above. Without this being granted, every AlarmKit
  /// schedule call below silently throws and the app falls back to its
  /// existing time-sensitive notification. No-ops on Android and on
  /// iOS < 26 (the plugin throws there; swallowed since there's nothing
  /// to ask for).
  Future<void> requestAlarmKitAuthorizationOnce() async {
    if (!Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedAlarmKitKey) ?? false) return;
    try {
      await _alarmKit.requestAuthorization().timeout(const Duration(seconds: 10));
    } catch (_) {}
    await prefs.setBool(_askedAlarmKitKey, true);
  }

  static String _alarmKitIdPrefsKey(String taskId) => 'alarmkit_id_$taskId';

  // Reverse index (AlarmKit's own UUID -> the same {taskId, taskName,
  // spaceName} payload the Android notification path already carries).
  // AlarmMetadata only exposes a bare icon/subtitle pair -- not
  // structured data -- so this is how checkAlertingAlarmKitAlarm/
  // listenForAlarmKitAlerts below recover which task a ringing AlarmKit
  // alarm belongs to well enough to route into the same AlarmScreen
  // Android's fullScreenIntent tap already reaches via pendingAlarmNotifier.
  static String _alarmKitTaskPrefsKey(String alarmId) => 'alarmkit_task_$alarmId';

  /// Best-effort AlarmKit schedule for a task's overdue alert -- see the
  /// _alarmKit field's own doc comment for why this exists alongside, not
  /// instead of, the zonedSchedule/show calls at each call site. Persists
  /// the returned AlarmKit alarm UUID (keyed by taskId, and back again) so
  /// cancelOverdueAlarm can cancel it too, and so a ringing alarm can be
  /// mapped back to its task -- AlarmKit tracks alarms by their own UUID
  /// rather than the int id flutter_local_notifications uses.
  Future<void> _scheduleAlarmKitAlarm({
    required String taskId,
    required String taskName,
    required String spaceName,
    required DateTime when,
  }) async {
    if (!Platform.isIOS) return;
    try {
      final alarmId = await _alarmKit
          .scheduleOneShotAlarm(
            timestamp: when.millisecondsSinceEpoch.toDouble(),
            label: 'Overdue: $taskName',
            // Only the single native Stop button fits in AlarmKit's alert (see
            // requestAlarmKitAuthorizationOnce's own doc comment for the full
            // reasoning) -- it just silences the ring, it does NOT mark the
            // task complete, so it's labelled neutrally rather than "Complete".
            // Tapping anywhere else on the alert opens the app straight into
            // the same AlarmScreen the Android path uses, which has the real
            // Slide-to-complete/Snooze/End actions.
            uiConfig: const AlarmUIConfig(
              stopButton: AlarmButtonConfig(text: 'Dismiss', icon: 'xmark.circle', tintColor: '#EF4444'),
            ),
          )
          .timeout(const Duration(seconds: 5));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_alarmKitIdPrefsKey(taskId), alarmId);
      await prefs.setString(
        _alarmKitTaskPrefsKey(alarmId),
        _alarmPayload(taskId: taskId, taskName: taskName, spaceName: spaceName),
      );
    } catch (_) {
      // iOS < 26, AlarmKit not authorized, or a platform hiccup -- the
      // time-sensitive notification scheduled alongside this is still
      // the person's alert in that case.
    }
  }

  Future<void> _cancelAlarmKitAlarm(String taskId) async {
    if (!Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    final alarmId = prefs.getString(_alarmKitIdPrefsKey(taskId));
    if (alarmId == null) return;
    try {
      // A timeout, not just try/catch, is load-bearing here: the Alarm
      // screen's Complete/End buttons await completeOverdueTask ->
      // cancelOverdueAlarm -> this, then navigate away once it returns
      // (see alarm_screen.dart's _complete/_end). A native AlarmKit call
      // that throws is already handled by catch below, but one that
      // simply never completes -- e.g. cancelling an alarm that already
      // auto-stopped itself the moment the person tapped its native
      // alert, which some AlarmKit builds appear to hang on -- would
      // otherwise leave that await pending forever, stalling the whole
      // chain before it ever reaches context.go('/home') even though the
      // task was already marked complete on the server a step earlier.
      await _alarmKit.cancelAlarm(alarmId: alarmId).timeout(const Duration(seconds: 3));
    } catch (_) {}
    await prefs.remove(_alarmKitTaskPrefsKey(alarmId));
    await prefs.remove(_alarmKitIdPrefsKey(taskId));
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

  // Best-effort, same reasoning as scheduleAt above -- called in a loop
  // from notifications_provider.dart/background_watcher_service.dart, so
  // one native hiccup posting a single task-update notification must
  // never abort the rest of that loop.
  Future<void> showTaskUpdateNotification({
    required String taskId,
    required String title,
    required String body,
  }) async {
    try {
      await _plugin.show(
        'taskupdate_$taskId'.hashCode & 0x7fffffff,
        title,
        body,
        const NotificationDetails(android: _taskUpdatesChannel, iOS: DarwinNotificationDetails()),
      );
    } catch (_) {}
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
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
      );
    } catch (_) {}
  }

  /// Schedules a one-off reminder at [when]. Pass a stable [id] derived from
  /// the task id so re-scheduling the same task overwrites, rather than
  /// duplicates, its reminder.
  ///
  /// Called from inside notifications_provider.dart's feed-building loop,
  /// once per due-soon task -- with no try/catch, a single native failure
  /// here (e.g. flutter_local_notifications' own known Gson/TypeToken
  /// crash reading its persisted scheduled-notification list on some
  /// devices/builds -- "TypeToken must be created with a type argument")
  /// used to propagate all the way up and fail the ENTIRE Notifications
  /// feed, not just this one reminder -- showing as "Couldn't load this"
  /// with a raw stack trace on the Notifications screen, or as an
  /// apparent crash right after the first-launch permission prompt (the
  /// feed is computed again immediately after). A missed due-soon device
  /// reminder is not worth losing the whole feed over, so this is
  /// best-effort like every other native-call site in this file.
  Future<void> scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    if (when.isBefore(DateTime.now())) return;
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _tzFrom(when),
        const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  // Stable per-task id so scheduling/firing/cancelling the same task's
  // alarm always targets the same underlying OS notification instead of
  // piling up duplicates.
  static int _alarmId(String taskId) => 'overdue_$taskId'.hashCode & 0x7fffffff;

  String _alarmPayload({required String taskId, required String taskName, required String spaceName}) =>
      jsonEncode({'taskId': taskId, 'taskName': taskName, 'spaceName': spaceName});

  /// Fires the overdue alarm immediately -- used when a task is discovered
  /// already overdue (e.g. the app was closed when its due time passed).
  /// Called in a loop from notifications_provider.dart/
  /// background_watcher_service.dart alongside several OTHER tasks' own
  /// alarms/reminders -- try/catch here (same reasoning as scheduleAt
  /// above) is what stops one task's alarm failing natively from also
  /// silently swallowing every other task's alert in the same pass.
  Future<void> showOverdueAlarmNow({
    required String taskId,
    required String taskName,
    required String spaceName,
  }) async {
    try {
      await _plugin.show(
        _alarmId(taskId),
        'Overdue: $taskName',
        spaceName.isNotEmpty ? 'Space: $spaceName · tap Complete or Snooze' : 'Tap Complete or Snooze',
        const NotificationDetails(android: _overdueChannel, iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive)),
        payload: _alarmPayload(taskId: taskId, taskName: taskName, spaceName: spaceName),
      );
    } catch (_) {}
    // AlarmKit has no "fire immediately" call -- a few seconds out is the
    // closest equivalent and is indistinguishable from instant to a person.
    await _scheduleAlarmKitAlarm(
      taskId: taskId,
      taskName: taskName,
      spaceName: spaceName,
      when: DateTime.now().add(const Duration(seconds: 2)),
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
    await _scheduleAlarmKitAlarm(taskId: taskId, taskName: taskName, spaceName: spaceName, when: when);
  }

  /// Looks up the task payload persisted for [alarmId] (see
  /// _scheduleAlarmKitAlarm) and, if present, feeds it into
  /// pendingAlarmNotifier -- the exact same trigger router.dart already
  /// watches to redirect to the full AlarmScreen (Slide-to-complete/
  /// Snooze/End) for the Android notification-tap path. This is what
  /// makes tapping an AlarmKit alert reach that same screen instead of
  /// just opening the app to Home.
  Future<void> _routeToAlarmScreenFor(String alarmId) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = prefs.getString(_alarmKitTaskPrefsKey(alarmId));
    if (payload == null) return;
    try {
      pendingAlarmNotifier.value = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {}
  }

  /// Cold-start counterpart to getLaunchDetails() above, for the AlarmKit
  /// path: AlarmKit has no "did this launch come from tapping an alert"
  /// API of its own, so this instead asks the system for every alarm it
  /// still knows about and checks whether any is currently
  /// AlarmState.alerting -- true right after the person taps a ringing
  /// alert to open the app. Call once at startup, after init(); a no-op
  /// on Android and iOS < 26.
  Future<void> checkAlertingAlarmKitAlarm() async {
    if (!Platform.isIOS) return;
    try {
      // Timeout so a hung native call can't stall app startup -- this is
      // awaited directly from main.dart before runApp().
      final alarms = await _alarmKit.getAlarms().timeout(const Duration(seconds: 3));
      for (final alarm in alarms) {
        if (alarm.state == AlarmState.alerting) {
          await _routeToAlarmScreenFor(alarm.id);
          return;
        }
      }
    } catch (_) {}
  }

  /// Live counterpart to the cold-start check above, for while the app is
  /// already running (foreground or backgrounded-but-alive) when an
  /// AlarmKit alarm starts ringing -- AlarmState.alerting only shows up
  /// as a fresh `updated` event here, checkAlertingAlarmKitAlarm() above
  /// won't see it until the next full launch. Call once at startup;
  /// deliberately never cancelled, same lifetime as the app process. A
  /// no-op on Android and iOS < 26.
  void listenForAlarmKitAlerts() {
    if (!Platform.isIOS) return;
    try {
      _alarmKit.alarmUpdates().listen((event) {
        if (event.alarm?.state == AlarmState.alerting) {
          _routeToAlarmScreenFor(event.alarmId);
        }
      });
    } catch (_) {}
  }

  // Best-effort: a caller like the Alarm screen's Complete/End actions
  // awaits this right after already marking the task complete/dismissed
  // server-side -- if the plugin call itself throws (platform-channel
  // hiccup, OEM quirk), that must never block the caller from proceeding
  // to navigate away. Worst case a stale scheduled notification lingers,
  // which is harmless compared to leaving the person stuck on this screen.
  Future<void> cancelOverdueAlarm(String taskId) async {
    try {
      await _plugin.cancel(_alarmId(taskId));
    } catch (_) {}
    await _cancelAlarmKitAlarm(taskId);
  }

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

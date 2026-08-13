import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/notification_service.dart';
import 'core/background_watcher_service.dart';
import 'core/pending_attachment_service.dart';
import 'providers/auth_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  // Must run before auth_provider.dart's startBackgroundWatcher/
  // stopBackgroundWatcher calls (login, logout, or a remembered session
  // resuming on cold start) -- configure() has to happen once before the
  // service can actually be started. See background_watcher_service.dart
  // for why this exists: it's the fallback that keeps firing the overdue
  // alarm even when the OS has fully frozen the app's main process, which
  // is what was actually happening on the test device despite every
  // scheduling/permission fix tried before this.
  await initializeBackgroundWatcher();
  // Independent OS-level watchdog for that same service -- see
  // armWatchdog's own doc comment for why a resume-triggered check alone
  // (below, in _HqeplAppState) isn't enough on its own.
  await armWatchdog();

  // Was this a cold start caused by tapping/launching the overdue
  // alarm's full-screen notification? If so, seed pendingAlarmNotifier
  // before the router's first redirect check so it routes straight to
  // the Alarm screen instead of Home. (The app-already-running case is
  // handled separately, in notification_service.dart's response
  // handler.) Deliberately kept here, before runApp -- it's local-only
  // (no network, no dialogs) and has to win the race against the
  // router's first redirect decision, which the deferred permission
  // cascade below does not.
  final launchDetails = await NotificationService.instance.getLaunchDetails();
  final launchPayload = launchDetails?.notificationResponse?.payload;
  if (launchDetails?.didNotificationLaunchApp == true && launchPayload != null) {
    try {
      pendingAlarmNotifier.value = jsonDecode(launchPayload) as Map<String, dynamic>;
    } catch (_) {
      // Malformed/unrelated payload -- fall through to a normal launch.
    }
  }

  // Same "win the race against the router's first redirect" reasoning as
  // the alarm check just above, for a task-attachment pick that was still
  // in flight when Android last tore this Activity down mid-pick (see
  // pending_attachment_service.dart) -- a fast local SharedPreferences
  // read, no network involved, so it's safe to await here before runApp.
  // Actually recovering (uploading) the file happens later, from
  // didChangeAppLifecycleState/the auth listener below, once a session
  // exists to authenticate the upload with; this only makes sure the
  // FIRST frame the person sees is already the right task, not Home.
  final pendingAttachmentTaskId = await PendingAttachmentService.instance.pendingTargetTaskId();
  if (pendingAttachmentTaskId != null) {
    pendingAttachmentTaskNotifier.value = pendingAttachmentTaskId;
  }

  // The person needs to actually SEE the app (even just its splash
  // screen) before anything below asks them for a permission -- moved
  // ahead of the whole cascade that follows, which used to run entirely
  // before this call. That ordering meant a fresh install's very first
  // moment was: blank screen (no UI existed yet) -> the notification
  // permission dialog -> straight into MORE native prompts, one of which
  // (requestFullScreenIntentPermissionOnce, Android 14+) force-navigates
  // to the OS's own Settings app rather than showing an in-app dialog.
  // Someone who tapped "Don't allow" would be immediately bounced into
  // System Settings having never once seen this app's UI -- indistinguishable
  // from a crash. Now the person always lands on a visibly running app
  // first, and the permission cascade runs as a normal foreground prompt
  // on top of it instead of gating the UI's very existence.
  runApp(const ProviderScope(child: HqeplApp()));

  unawaited(_requestPermissionsAfterLaunch());
}

/// Everything here can show a native dialog or (for full-screen-intent)
/// leave the app for a system Settings screen -- see main()'s own doc
/// comment for why this is deliberately deferred until after runApp, and
/// why each step past the first is gated on the previous one actually
/// being granted rather than firing regardless.
Future<void> _requestPermissionsAfterLaunch() async {
  // "Allow notifications" defaults to on (see settings_provider.dart), so
  // a fresh install never flips that toggle and would otherwise never
  // trigger the actual OS permission prompt on Android 13+/iOS -- every
  // task reminder and the overdue alarm would silently never show.
  // Requesting here is safe to repeat on every launch: once granted or
  // denied, the OS itself won't re-show the dialog.
  final notificationsGranted = await NotificationService.instance.requestPermission();

  // Everything past this point is either meaningless without base
  // notification permission (there's nothing to show full-screen or
  // exempt from battery optimization) or, worse, another native
  // prompt/Settings-screen jump layered on top of a "no" the person just
  // gave -- so a decline here ends the cascade instead of continuing it.
  // They can still turn all of this on later, deliberately, from the
  // Settings screen's own buttons.
  if (notificationsGranted) {
    // Doze/App Standby can defer or drop the overdue alarm once the
    // app's been closed a while -- asking for the exemption up front (in
    // addition to the Settings-screen button, for anyone who dismissed
    // this dialog) is what actually lets zonedSchedule fire reliably
    // while closed. Only asks once ever, not on every launch -- see
    // requestBatteryOptimizationExemptionOnce's own doc comment: on some
    // phones this dialog can never register as "granted" even after the
    // person genuinely allows the equivalent OEM setting, which turned a
    // one-time ask into it nagging on every single app open.
    await NotificationService.instance.requestBatteryOptimizationExemptionOnce();
    // Android 14's separate "full screen notifications" toggle -- without
    // it, the overdue alarm silently degrades to a normal notification
    // that can sit invisible while the phone's locked (see
    // requestFullScreenIntentPermissionOnce's own doc comment).
    await NotificationService.instance.requestFullScreenIntentPermissionOnce();
  }

  // AlarmKit's own authorization (iOS 26+) -- separate from the regular
  // notification permission above; without it the overdue alarm silently
  // falls back to a plain time-sensitive notification (see
  // requestAlarmKitAuthorizationOnce's own doc comment). No-op on
  // Android, so not worth gating on notificationsGranted above.
  await NotificationService.instance.requestAlarmKitAuthorizationOnce();
  // Live counterpart of the AlarmKit cold-start check just below -- picks
  // up an alarm that starts ringing while the app is already running.
  // See its own doc comment for why this needs to be separate.
  NotificationService.instance.listenForAlarmKitAlerts();
  // AlarmKit's equivalent of the launch-details check in main() above --
  // see checkAlertingAlarmKitAlarm's own doc comment for why this needs a
  // separate, active lookup instead of a launch-details flag. Only
  // relevant if that check didn't already find a pending alarm.
  if (pendingAlarmNotifier.value == null) {
    await NotificationService.instance.checkAlertingAlarmKitAlarm();
  }
}

class HqeplApp extends ConsumerStatefulWidget {
  const HqeplApp({super.key});

  @override
  ConsumerState<HqeplApp> createState() => _HqeplAppState();
}

// Self-healing for the overdue-alarm watcher (see
// background_watcher_service.dart). It's started once at login/cold
// start, but Android can silently kill it later -- an aggressive OEM
// process manager, or (Android 15+) the OS's own hard ceiling on how
// long a "dataSync" foreground service may run before it's force-stopped
// -- with no callback this app gets to react to. Left alone, that's
// exactly "the alarm worked for a while, then quietly stopped" with no
// visible cause. Re-checking on every resume, not just at login, means
// the very next time the person opens the app it gets silently
// restarted instead of staying dead until they log out and back in (or
// reboot the phone).
class _HqeplAppState extends ConsumerState<HqeplApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (ref.read(authProvider).status == AuthStatus.authenticated) {
      startBackgroundWatcher();
      // Finishes any task attachment whose picker was still open when the
      // app went to the background -- this is the ONLY place the upload is
      // actually kicked off, whether or not Android tore the Activity down
      // in the meantime, so both paths behave identically. Deliberately
      // app-level rather than inside the attachments panel: after a
      // teardown the app relaunches at Home and that panel no longer
      // exists. Navigating to the task itself isn't done here -- it's
      // driven reactively by pendingAttachmentTaskNotifier, which this
      // sets as soon as it finds a pending pick (before the upload even
      // starts), and router.dart is already watching. See
      // pending_attachment_service.dart.
      unawaited(PendingAttachmentService.instance.recoverPendingUpload());
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    // The cold-start counterpart of the resume-triggered recovery above.
    // When Android tears the Activity down mid-pick, the app comes back as
    // a fresh launch rather than a resume, so didChangeAppLifecycleState
    // never fires for it. Hooked to auth specifically (not initState)
    // because the upload needs a restored session to authenticate with --
    // firing it earlier would consume the pending file on a request that's
    // guaranteed to 401, losing it for good.
    ref.listen(authProvider, (previous, next) {
      if (previous?.status != AuthStatus.authenticated &&
          next.status == AuthStatus.authenticated) {
        unawaited(PendingAttachmentService.instance.recoverPendingUpload());
      }
    });

    return MaterialApp.router(
      title: 'Q Task360',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}

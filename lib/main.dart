import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/notification_service.dart';
import 'core/background_watcher_service.dart';
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
  // "Allow notifications" defaults to on (see settings_provider.dart), so
  // a fresh install never flips that toggle and would otherwise never
  // trigger the actual OS permission prompt on Android 13+/iOS -- every
  // task reminder and the overdue alarm would silently never show.
  // Requesting here is safe to repeat on every launch: once granted or
  // denied, the OS itself won't re-show the dialog.
  await NotificationService.instance.requestPermission();
  // Doze/App Standby can defer or drop the overdue alarm once the app's
  // been closed a while -- asking for the exemption up front (in addition
  // to the Settings-screen button, for anyone who dismissed this dialog)
  // is what actually lets zonedSchedule fire reliably while closed. Only
  // asks once ever, not on every launch -- see
  // requestBatteryOptimizationExemptionOnce's own doc comment: on some
  // phones this dialog can never register as "granted" even after the
  // person genuinely allows the equivalent OEM setting, which turned a
  // one-time ask into it nagging on every single app open.
  await NotificationService.instance.requestBatteryOptimizationExemptionOnce();
  // Android 14's separate "full screen notifications" toggle -- without
  // it, the overdue alarm silently degrades to a normal notification that
  // can sit invisible while the phone's locked (see
  // requestFullScreenIntentPermissionOnce's own doc comment).
  await NotificationService.instance.requestFullScreenIntentPermissionOnce();

  // Was this a cold start caused by tapping/launching the overdue
  // alarm's full-screen notification? If so, seed pendingAlarmNotifier
  // before the router's first redirect check so it routes straight to
  // the Alarm screen instead of Home. (The app-already-running case is
  // handled separately, in notification_service.dart's response
  // handler.)
  final launchDetails = await NotificationService.instance.getLaunchDetails();
  final launchPayload = launchDetails?.notificationResponse?.payload;
  if (launchDetails?.didNotificationLaunchApp == true && launchPayload != null) {
    try {
      pendingAlarmNotifier.value = jsonDecode(launchPayload) as Map<String, dynamic>;
    } catch (_) {
      // Malformed/unrelated payload -- fall through to a normal launch.
    }
  }

  runApp(const ProviderScope(child: HqeplApp()));
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Q Task360',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}

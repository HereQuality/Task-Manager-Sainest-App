import 'dart:async';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'api_client.dart';
import 'notification_service.dart';

/// Remote push (FCM) -- the one path that can alert someone about a task
/// change while the app is fully closed, which nothing else in this app
/// can do on iOS (see CLAUDE.md: iOS has no background watcher, unlike
/// Android's background_watcher_service.dart). The backend sends a normal
/// FCM "notification" payload (title/body) for every relevant task event,
/// so the OS itself displays it and runs this app with zero code required
/// here for the backgrounded/terminated case -- this file only has to
/// handle: asking for permission, registering this device's token with the
/// backend so it knows where to send pushes, showing something while the
/// app is in the FOREGROUND (the OS never auto-displays a push then), and
/// routing a tap on the notification to the right task.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final _messaging = FirebaseMessaging.instance;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;

  // iOS Simulators (and some real devices in edge cases) can never obtain
  // a real APNs token -- rather than fail fast, several firebase_messaging
  // iOS calls that depend on one (requestPermission, getInitialMessage,
  // getToken) are known to simply hang forever instead of throwing. This
  // ran INSIDE main()'s startup sequence, before runApp() -- a hang here
  // showed up as the whole app stuck on a blank white launch screen
  // forever, indistinguishable from a crash. Every native call in this
  // file is wrapped in a timeout for that reason, same defensive pattern
  // notification_service.dart already uses for its own native-call
  // hangs (see _cancelAlarmKitAlarm's own doc comment there).
  static const _nativeCallTimeout = Duration(seconds: 8);

  Future<void> init() async {
    try {
      // iOS needs this separately from NotificationService's own
      // requestPermission (local notifications) -- this is what actually
      // triggers APNs registration. Android 13+ shares the same OS
      // permission as local notifications, so this is a harmless duplicate
      // there (already granted by the time this runs, in main.dart's
      // cascade, or a no-op if declined).
      final settings = await _messaging
          .requestPermission(alert: true, badge: true, sound: true)
          .timeout(_nativeCallTimeout);
      // Deliberately printed -- authorizationStatus.authorized here but
      // getToken() still failing with apns-token-not-set would point at
      // something below the Dart/plugin layer entirely (APNs
      // registration itself failing natively), not a permission problem.
      // ignore: avoid_print
      print('[PushService] permission status: ${settings.authorizationStatus}');
    } catch (e) {
      debugPrint('[PushService] requestPermission failed/timed out: $e');
    }

    // iOS-only, and load-bearing: flutter_local_notifications does NOT
    // register itself as the app's UNUserNotificationCenterDelegate on
    // this version (17.2.4) -- only FirebaseMessaging's own plugin does.
    // That means Firebase's own willPresent handler is what decides
    // whether ANY foreground notification shows a banner, including the
    // ones notification_service.dart posts locally via _plugin.show()
    // (its DarwinNotificationDetails(presentAlert: true, ...) is a no-op
    // for that decision -- it only matters if flutter_local_notifications
    // itself is the delegate, which it isn't here). Firebase's handler
    // reads this exact setting from NSUserDefaults and otherwise defaults
    // to UNNotificationPresentationOptionNone -- silently suppressing
    // every foreground banner (push-triggered or local) until this is
    // called at least once. See flutterfire#18699 / the willPresent
    // implementation in FLTFirebaseMessagingPlugin.m.
    try {
      await _messaging
          .setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true)
          .timeout(_nativeCallTimeout);
    } catch (e) {
      debugPrint('[PushService] setForegroundNotificationPresentationOptions failed/timed out: $e');
    }

    // Android only shows this via _showForeground's manual re-post below
    // (see its own doc comment) -- iOS now auto-displays the push itself,
    // thanks to setForegroundNotificationPresentationOptions above.
    _onMessageSub = FirebaseMessaging.onMessage.listen(_showForeground);

    // Tapped a push that opened the app from background (not terminated --
    // see getInitialMessage below for the cold-start case).
    _onOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

    try {
      // App was fully closed and launched BY tapping the push.
      final initial = await _messaging.getInitialMessage().timeout(_nativeCallTimeout);
      if (initial != null) _handleTap(initial);
    } catch (e) {
      debugPrint('[PushService] getInitialMessage failed/timed out: $e');
    }

    // The token can rotate at any time (app reinstall, token expiry, OS
    // restore to a new device) -- without re-registering here, a device
    // would silently stop receiving pushes until the person happened to
    // log out and back in.
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((_) => registerCurrentToken());
  }

  void _showForeground(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    // iOS-only: init() above now calls setForegroundNotificationPresentation-
    // Options(alert: true, ...), which doesn't just enable
    // NotificationService's own _plugin.show() banners -- it also makes iOS
    // itself auto-present the RAW incoming FCM push while foregrounded
    // (that's literally what that setting controls). So on iOS this method
    // manually re-posting the same event via showTaskUpdateNotification
    // below would double it: one native banner from the OS presenting the
    // push directly, one from this call -- and only the second one runs
    // through NotificationService's in-app dedupe, so the native one always
    // got through uncaught. Android never auto-displays a foreground FCM
    // notification (no equivalent setting), so it still needs this manual
    // path -- this comment's "Foreground pushes are never shown by the OS
    // on either platform" claim just above stopped being true for iOS the
    // moment that presentation-options call was added.
    if (Platform.isIOS) return;
    final taskId = message.data['taskId'] as String?;
    // Reuses the same channel/display path as every other in-app-generated
    // task notification (see notifications_provider.dart) rather than a
    // separate one, so muting "Task Updates" in Settings also mutes these.
    NotificationService.instance.showTaskUpdateNotification(
      taskId: taskId ?? message.messageId ?? 'push',
      title: notification.title ?? 'Task360',
      body: notification.body ?? '',
    );
  }

  void _handleTap(RemoteMessage message) {
    final taskId = message.data['taskId'] as String?;
    if (taskId != null && taskId.isNotEmpty) {
      pendingTaskOpenNotifier.value = taskId;
    }
  }

  /// On iOS, FirebaseMessaging.getToken() needs the native APNs token
  /// first -- that's set asynchronously by the OS shortly after
  /// requestPermission() grants authorization (via a didRegister...
  /// AppDelegate callback Firebase swizzles), not immediately when
  /// requestPermission()'s own Future resolves. Calling getToken() right
  /// away is a real, commonly-hit race -- it throws
  /// 'apns-token-not-set' on a real device with permission correctly
  /// granted and everything else configured right, not just on
  /// Simulator. No-op on Android, which has no separate APNs step.
  Future<void> _waitForApnsToken() async {
    if (!Platform.isIOS) return;
    for (var i = 0; i < 5; i++) {
      try {
        final apnsToken = await _messaging.getAPNSToken().timeout(_nativeCallTimeout);
        if (apnsToken != null) return;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  /// Fetches this device's current FCM token and upserts it against the
  /// logged-in user on the backend. Called after every login/session
  /// restore (see auth_provider.dart) -- not just once at first install --
  /// because the token is tied to this OS install, not this account, so a
  /// second person logging into the same device needs their own
  /// registration, and the same person on a second device needs that
  /// device separately registered too.
  Future<void> registerCurrentToken() async {
    try {
      await _waitForApnsToken();
      final token = await _messaging.getToken().timeout(_nativeCallTimeout);
      if (token == null) {
        // ignore: avoid_print
        print('[PushService] getToken() returned null -- no APNs token available (expected on Simulator)');
        return;
      }
      await ApiClient.instance.dio.post('/devices/register', data: {
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
      });
      // Deliberately printed (not debugPrint-gated), same reasoning as
      // notification_service.dart's own [ALARM] scheduling confirmation --
      // this is the one line that proves the token actually reached the
      // backend, as opposed to silently no-op'ing somewhere in between.
      // ignore: avoid_print
      print('[PushService] registered token with backend: ${token.substring(0, 12)}...');
    } catch (e) {
      // Best-effort, same reasoning as every native-call site in
      // notification_service.dart -- a person should never be blocked
      // from using the app because push registration failed once.
      debugPrint('[PushService] registerCurrentToken failed: $e');
    }
  }

  /// Called from logout() -- tells the backend to stop sending this
  /// device pushes for an account that's no longer signed in here, so a
  /// shared/handed-down device doesn't keep alerting about a previous
  /// person's tasks.
  Future<void> unregisterCurrentToken() async {
    try {
      // Near-instant if the APNs token was already set (the normal case
      // by logout time) -- see _waitForApnsToken's own doc comment.
      await _waitForApnsToken();
      final token = await _messaging.getToken().timeout(_nativeCallTimeout);
      if (token == null) return;
      await ApiClient.instance.dio.post('/devices/unregister', data: {'token': token});
    } catch (e) {
      debugPrint('[PushService] unregisterCurrentToken failed: $e');
    }
  }

  void dispose() {
    _tokenRefreshSub?.cancel();
    _onMessageSub?.cancel();
    _onOpenedSub?.cancel();
  }
}

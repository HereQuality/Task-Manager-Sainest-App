import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // super's call is what starts the Flutter engine AND (synchronously,
    // via didInitializeImplicitFlutterEngine below) runs
    // GeneratedPluginRegistrant.register(...), which is what gives
    // flutter_local_notifications its chance to claim
    // UNUserNotificationCenter.current().delegate for itself. Configuring
    // Firebase BEFORE this (the original ordering, still early enough to
    // avoid the APNs-token race described below) let Firebase's own
    // Messaging setup claim that same delegate slot first instead --
    // foreground local notifications posted via push_service.dart's
    // onMessage handler then silently never displayed (show() reported
    // success, but no banner, no Notification Center entry, nothing) even
    // with a Firebase-team-patched firebase_messaging build applied for
    // the known-adjacent https://github.com/firebase/flutterfire/issues/18699
    // bug -- because that patch only concerns Firebase's own swizzled
    // interception of the delegate call, not a plugin ordering race that
    // hands the delegate to Firebase before flutter_local_notifications
    // ever gets it. Configuring after super's call still runs well before
    // Dart's async main()/Firebase.initializeApp() -- super.application()
    // itself is synchronous; Dart doesn't execute until the engine's UI
    // thread spins up afterward -- so the original APNs-token race this
    // ordering fixed stays fixed.
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    FirebaseApp.configure()

    // Manual integration (FirebaseAppDelegateProxyEnabled=NO in
    // Info.plist) -- Firebase's automatic method swizzling of
    // didRegisterForRemoteNotificationsWithDeviceToken below never
    // reliably fired on this app (getToken() kept failing with
    // apns-token-not-set on a real device with permission granted,
    // Firebase configured, and every Apple-portal/entitlement setting
    // verified correct -- likely an interaction with this AppDelegate's
    // FlutterImplicitEngineDelegate setup, which is new enough that
    // Firebase's swizzling may not fully account for it).
    application.registerForRemoteNotifications()

    return result
  }

  // The real OS callback once APNs hands back a device token -- forwarded
  // to Firebase manually since automatic swizzling isn't handling it (see
  // above). This is the one call that was never actually happening.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Deliberately printed (not debugPrint-gated) -- proves whether the OS
    // itself is refusing registration (e.g. no network to Apple's push
    // servers), as opposed to Firebase-side failing to pick up a token
    // that was actually delivered.
    print("[AppDelegate] didFailToRegisterForRemoteNotificationsWithError: \(error)")
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

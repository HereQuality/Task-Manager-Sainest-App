import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bumped every time a 401 clears the stored token below. ApiClient is a
/// plain singleton with no Riverpod ref of its own, so this is the same
/// ValueNotifier-bridge pattern used everywhere else in the app
/// (pendingAlarmNotifier, taskRealtimeEventNotifier, etc) -- auth_provider.dart's
/// AuthNotifier listens to this and flips its own state to unauthenticated.
///
/// This bridge is the actual fix for what used to be a dead end: clearing
/// the token here did NOT, on its own, change AuthState at all (the two are
/// completely separate pieces of state -- one in secure storage, one in a
/// Riverpod StateNotifier in memory), so router.dart's redirect -- which
/// only ever looks at AuthState.status -- had no idea the session had just
/// died. Every screen kept calling APIs with no token, kept getting 401,
/// and kept showing its own raw error state forever, with no way back to
/// the login screen short of manually logging out or force-closing the
/// app. A stale comment right below used to claim "the router's auth guard
/// will bounce the user back to /login on next rebuild" -- it doesn't; nothing
/// ever triggered that rebuild.
final sessionExpiredNotifier = ValueNotifier<int>(0);

/// Set this to your server's reachable URL:
///  - Android emulator -> http://10.0.2.2:5000/api/v1
///  - iOS simulator    -> http://localhost:5000/api/v1
///  - Real device       -> http://<your-machine-LAN-ip>:5000/api/v1
///  - Production         -> https://your-domain.com/api/v1
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://task.hqepl.com/api/v1',
);

class ApiClient {
  ApiClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: kApiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Content-Type': 'application/json'},
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // Best-effort: flutter_secure_storage's Android KeyStore-backed
          // key can go permanently unreadable (AEADBadTagException/
          // "Signature/MAC verification failed") after certain OS-level
          // events -- confirmed on a real device via logcat, most likely
          // from switching between differently-signed builds (debug vs.
          // release) installed over each other on the same device, which
          // can leave the app's encrypted store referencing a KeyStore key
          // that no longer decrypts it. Without this try/catch, EVERY
          // request (including login itself, which needs no token at all)
          // failed with a generic error that looked exactly like a
          // rejected password -- read() throwing here doesn't get any
          // chance to become the clearer message auth_provider.dart's own
          // login() catch block builds, since it never reaches the network
          // at all. resetOnError below is the real fix (wipes and
          // recreates the corrupted store instead of leaving it broken
          // forever); this is just insurance so a request in flight before
          // that reset takes effect still goes out as an unauthenticated
          // one instead of failing outright.
          //
          // Goes through readToken() (below), not a raw _storage.read()
          // here -- see _cachedToken's own doc comment for why that
          // matters: this used to hit the encrypted store fresh on every
          // single request, from BOTH this isolate and the background
          // watcher's separate one (background_watcher_service.dart)
          // running concurrently roughly once a minute, which meant a lot
          // of chances for the two to collide on the same underlying file
          // at once. Caching collapses that down to (at most) one real
          // disk read per isolate's lifetime.
          try {
            final token = await readToken();
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          } catch (_) {}
          handler.next(options);
        },
        onError: (error, handler) async {
          // 401 -> token expired/invalid. Clear it, and tell
          // auth_provider.dart's AuthNotifier via sessionExpiredNotifier
          // above so AuthState actually flips to unauthenticated -- see
          // that notifier's own doc comment for why deleting the token
          // alone used to leave the app stuck.
          if (error.response?.statusCode == 401) {
            await clearToken();
            sessionExpiredNotifier.value++;
          }
          handler.next(error);
        },
      ),
    );
  }

  static final ApiClient instance = ApiClient._internal();
  late final Dio _dio;
  // encryptedSharedPreferences is the officially-recommended Android
  // option: without it, plain flutter_secure_storage on Android has a
  // well-known failure mode where its KeyStore-backed key becomes
  // unreadable after a normal app restart on a lot of devices/emulators
  // (OS updates, backups, some manufacturers' keystore quirks) -- reads
  // silently come back null, which looked exactly like "remember me"
  // not working: the token was written fine, it just couldn't be read
  // back a moment later.
  // resetOnError: true is the plugin's own documented recovery for exactly
  // the AEADBadTagException/"Signature/MAC verification failed" crash
  // confirmed via logcat on a real device -- when the KeyStore-backed key
  // can no longer decrypt the existing encrypted store (seen after
  // installing differently-signed builds, debug then release, over each
  // other on the same device), a bare read/write throws forever with no
  // way to recover short of clearing app data by hand. This makes the
  // plugin wipe and recreate its own corrupted store the moment it hits
  // that error, so the person just gets signed out and can log back in,
  // rather than every request silently failing indefinitely.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: true),
  );
  static const _tokenKey = 'access_token';
  static const _rememberMeKey = 'remember_me';

  // In-memory copy of the token for the lifetime of THIS isolate (ApiClient
  // is a singleton, but every isolate -- the main UI isolate and each
  // separate background-watcher tick, see background_watcher_service.dart
  // -- gets its own fresh copy of that singleton's state, so this never
  // leaks a stale token across isolates or across a logout/login).
  //
  // Why this exists: before it did, every dio request -- from either
  // isolate -- read the token straight from flutter_secure_storage's
  // encrypted file, every single time. With the watcher isolate polling
  // roughly once a minute and the foreground app making its own requests
  // constantly during normal use, that meant frequent, ongoing chances for
  // two isolates to touch the same underlying encrypted file at once. A
  // transient decrypt hiccup during exactly that kind of collision is what
  // trips resetOnError below into wiping the whole store -- which looked
  // like "the session expired" mid-use, repeatedly, with no clean trigger.
  // Caching cuts the real reads down to at most one per isolate's
  // lifetime, which is what actually shrinks the collision window rather
  // than just reacting to it after the fact.
  String? _cachedToken;

  Dio get dio => _dio;

  Future<void> saveToken(String token) async {
    _cachedToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> readToken() async {
    if (_cachedToken != null) return _cachedToken;
    _cachedToken = await _storage.read(key: _tokenKey);
    return _cachedToken;
  }

  Future<void> clearToken() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
  }

  // "Remember me" on the login screen -- the token itself always has to
  // sit in secure storage for the request interceptor above to find it
  // (it re-reads on every call, there's no separate in-memory copy), so
  // this flag is what _restoreSession (auth_provider.dart) checks on a
  // fresh cold start: unchecked at login means the token gets wiped
  // there instead of silently logging the person back in. Missing/null
  // (e.g. a token saved before this flag existed) defaults to "remember"
  // so nobody already logged in gets bounced out by this change.
  Future<void> saveRememberMe(bool value) => _storage.write(key: _rememberMeKey, value: value.toString());
  Future<bool> readRememberMe() async => (await _storage.read(key: _rememberMeKey)) != 'false';
  Future<void> clearRememberMe() => _storage.delete(key: _rememberMeKey);

  // The logged-in person's own id -- not sensitive on its own (unlike
  // the token above), so plain SharedPreferences instead of secure
  // storage. Needed by task_update_tracker.dart to recognize "this task
  // change was MY OWN action" and skip notifying the person about
  // something they just did themselves -- read from both the foreground
  // Riverpod tree (notifications_provider.dart) and the background
  // watcher's separate isolate (background_watcher_service.dart), which
  // has no ProviderScope to pull authProvider's in-memory state from.
  static const _currentUserIdKey = 'current_user_id';
  Future<void> saveCurrentUserId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentUserIdKey, id);
  }

  Future<String?> readCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_currentUserIdKey);
  }

  Future<void> clearCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentUserIdKey);
  }
}

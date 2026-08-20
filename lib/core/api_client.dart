import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
          try {
            final token = await _storage.read(key: _tokenKey);
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          } catch (_) {}
          handler.next(options);
        },
        onError: (error, handler) async {
          // 401 -> token expired/invalid. Clear it; the router's auth
          // guard will bounce the user back to /login on next rebuild.
          if (error.response?.statusCode == 401) {
            await _storage.delete(key: _tokenKey);
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

  Dio get dio => _dio;

  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);
  Future<String?> readToken() => _storage.read(key: _tokenKey);
  Future<void> clearToken() => _storage.delete(key: _tokenKey);

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

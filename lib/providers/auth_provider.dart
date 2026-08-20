import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../core/background_watcher_service.dart';
import '../core/notification_service.dart';
import '../models/user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  final AuthStatus status;
  final AppUser? user;
  final String? error;

  const AuthState({this.status = AuthStatus.unknown, this.user, this.error});

  AuthState copyWith({AuthStatus? status, AppUser? user, String? error}) =>
      AuthState(status: status ?? this.status, user: user ?? this.user, error: error);
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState()) {
    _restoreSession();
    // See sessionExpiredNotifier's own doc comment in api_client.dart --
    // without this, a 401 anywhere in the app (expired/revoked token)
    // cleared the token from storage but left AuthState untouched, so the
    // person stayed stuck on whatever screen they were on, watching every
    // request fail with the same raw error, with no path back to login
    // short of a manual logout or force-closing the app.
    sessionExpiredNotifier.addListener(_onSessionExpired);
  }

  final _dio = ApiClient.instance;

  // Set the instant state becomes authenticated (both login() and a
  // restored session below) -- see _onSessionExpired's own grace-period
  // check on this.
  DateTime? _authenticatedAt;

  void _onSessionExpired() {
    // Guarded so this can't clobber a login attempt already in progress
    // (login()'s own catch sets its own precise error message) or pile a
    // second transition on top of one that's already happened.
    if (state.status != AuthStatus.authenticated) return;
    // A 401 arriving within a few seconds of becoming authenticated is far
    // more likely to be a local race than a genuinely dead token the
    // server just issued: startBackgroundWatcher() (called right below,
    // both here and in login()) spins up a SEPARATE isolate that reads/
    // writes the exact same encrypted token file this isolate just wrote
    // to, and flutter_secure_storage's resetOnError (api_client.dart) will
    // wipe that ENTIRE file the moment either isolate hits a transient
    // decrypt hiccup while the other is mid-write -- deleting a token that
    // was, from the person's perspective, valid a second ago. Before this
    // guard existed, that race showed up as: dashboard loads fine, then
    // 2-3 seconds later "Your session has expired" kicks them straight
    // back to login, immediately after a login that plainly worked. If the
    // token really is dead, the very next request fails 401 again past
    // this window and the redirect still happens -- just not on the false
    // positive from the startup race.
    if (_authenticatedAt != null && DateTime.now().difference(_authenticatedAt!) < const Duration(seconds: 8)) {
      return;
    }
    pendingAlarmNotifier.value = null;
    stopBackgroundWatcher();
    state = const AuthState(
      status: AuthStatus.unauthenticated,
      error: 'Your session has expired. Please log in again.',
    );
  }

  @override
  void dispose() {
    sessionExpiredNotifier.removeListener(_onSessionExpired);
    super.dispose();
  }

  Future<void> _restoreSession() async {
    String? token;
    bool rememberMe;
    try {
      token = await _dio.readToken();
      rememberMe = await _dio.readRememberMe();
    } catch (_) {
      // Android's EncryptedSharedPreferences can throw here on some
      // devices -- AEADBadTagException / KeyStoreException "Signature/MAC
      // verification failed" -- observed in practice right after the OS
      // silently kills this app in the background (e.g. while a heavier
      // foreground app like the system file/document picker is open) and
      // then cold-restarts it: the Keystore-backed cipher that encrypts
      // this storage came back unreadable on the fresh process. Left
      // unguarded, this exception had nowhere to go -- it broke
      // AuthNotifier's constructor before `state` was ever set past its
      // default AuthStatus.unknown, and router.dart deliberately keeps
      // showing the Splash screen for as long as that lasts (so a
      // still-loading session never flashes the login form). The result
      // was an app that looked permanently stuck/crashed on Splash after
      // exactly this kind of background restart. Falling back to a clean
      // "not authenticated" state at least gets the person to the login
      // screen instead of a screen that never resolves -- they'll just
      // need to sign back in once, same as if the token had genuinely
      // expired.
      state = state.copyWith(status: AuthStatus.unauthenticated);
      pendingAlarmNotifier.value = null;
      return;
    }
    if (token == null) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
      pendingAlarmNotifier.value = null;
      return;
    }
    // "Remember me" was unchecked at login -- the token still had to be
    // written to secure storage for API calls to work during that
    // session (see ApiClient's request interceptor), but a fresh cold
    // start honors the preference by discarding it here instead of
    // silently logging the person back in.
    if (!rememberMe) {
      await _dio.clearToken();
      await _dio.clearRememberMe();
      state = state.copyWith(status: AuthStatus.unauthenticated);
      pendingAlarmNotifier.value = null;
      return;
    }
    try {
      final res = await _dio.dio.get('/auth/me');
      // Unlike /auth/login (below), /auth/me puts the user's fields
      // directly under `data` -- no nested `user` key (see
      // getCurrentUser in employee.controller.js). Parsing this the
      // same way as login's response threw on every restore ("type
      // 'Null' is not a subtype of type 'Map<String, dynamic>'"),
      // which silently bounced a perfectly valid, remembered session
      // back to the login screen.
      final user = AppUser.fromJson(res.data['data']);
      state = AuthState(status: AuthStatus.authenticated, user: user);
      _authenticatedAt = DateTime.now();
      await _dio.saveCurrentUserId(user.id);
      // Restarts the watcher every cold start, not just at login -- the
      // service isn't guaranteed to have survived a full device reboot or
      // this app's own update, and starting an already-running one is a
      // harmless no-op (see startBackgroundWatcher's isRunning check).
      await startBackgroundWatcher();
    } on DioException catch (e) {
      // Only a real "this token is no good" response should force a
      // fresh login. Anything else (no network yet at cold start, the
      // server being briefly unreachable, a request timeout) is
      // transient -- wiping a still-valid token over that would mean
      // "remember me" effectively never works on a flaky connection.
      // The token stays put so the next launch (or a manual retry) can
      // pick the session back up.
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        await _dio.clearToken();
        await _dio.clearRememberMe();
        // A genuinely dead session -- see logout()'s own doc comment on
        // why pendingAlarmNotifier must never survive past this point.
        pendingAlarmNotifier.value = null;
      }
      state = state.copyWith(status: AuthStatus.unauthenticated);
    } catch (_) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  /// Tries the general /auth/login first, then falls back to
  /// /auth/employee/login -- matching the web app's single login form
  /// that resolves against both User and Employee collections.
  Future<bool> login(String usernameOrEmail, String password, {bool rememberMe = true}) async {
    try {
      Response res;
      try {
        res = await _dio.dio.post('/auth/login', data: {
          'username': usernameOrEmail,
          'password': password,
        });
      } on DioException catch (e) {
        if (e.response?.statusCode == 404 || e.response?.statusCode == 400) {
          res = await _dio.dio.post('/auth/employee/login', data: {
            'email': usernameOrEmail,
            'password': password,
          });
        } else {
          rethrow;
        }
      }

      final token = res.data['token'] as String;
      // Always written -- the request interceptor re-reads this on
      // every call, there's no separate in-memory copy it can fall
      // back to for the rest of this session. `rememberMe` only
      // controls whether _restoreSession keeps it past a cold start.
      await _dio.saveToken(token);
      await _dio.saveRememberMe(rememberMe);
      // Login's response DOES nest under `data.user` (see sendToken in
      // auth.controller.js) -- unlike /auth/me above, which doesn't.
      final user = AppUser.fromJson(res.data['data']['user']);
      state = AuthState(status: AuthStatus.authenticated, user: user);
      _authenticatedAt = DateTime.now();
      await _dio.saveCurrentUserId(user.id);
      await startBackgroundWatcher();
      return true;
    } on DioException catch (e) {
      // e.response is only set once the server actually replied -- a
      // connection timeout, no internet, DNS failure, or TLS hiccup never
      // gets that far, so e.response is null and e.response?.data?['message']
      // would silently fall through to the SAME generic fallback text a
      // genuinely wrong password gets. That's actively misleading: it tells
      // someone to "check your credentials" when the real problem is their
      // phone's own network, sending them off to retype a password that
      // was never actually wrong. Distinguishing the two here means the
      // message people see actually points at what to fix.
      final msg = e.response?.data?['message'] ??
          (e.type == DioExceptionType.connectionError ||
                  e.type == DioExceptionType.connectionTimeout ||
                  e.type == DioExceptionType.receiveTimeout ||
                  e.type == DioExceptionType.sendTimeout
              ? 'Could not reach the server. Check your internet connection and try again.'
              : 'Login failed. Check your credentials.');
      state = state.copyWith(status: AuthStatus.unauthenticated, error: msg);
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await _dio.dio.post('/auth/logout');
    } catch (_) {
      // ignore network errors on logout -- clear local session regardless
    }
    await _dio.clearToken();
    await _dio.clearRememberMe();
    await _dio.clearCurrentUserId();
    await stopBackgroundWatcher();
    // pendingAlarmNotifier is a single global flag (see router.dart's
    // redirect, which force-navigates to the Alarm screen the instant
    // it's non-null) -- if an alarm ever fired while the person wasn't on
    // a screen that could consume/clear it (e.g. they were already on
    // the login screen, or backgrounded), it stays set with nothing to
    // clear it. Left alone, the moment ANYONE next logs into this device
    // -- including a different account -- the router replays that stale
    // alarm immediately, showing an old/already-handled reminder as if
    // it just rang. Logging out is the one guaranteed checkpoint to wipe
    // it, so no login can ever inherit another session's leftover alarm.
    pendingAlarmNotifier.value = null;
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier());

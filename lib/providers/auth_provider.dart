import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../core/background_watcher_service.dart';
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
  }

  final _dio = ApiClient.instance;

  Future<void> _restoreSession() async {
    final token = await _dio.readToken();
    if (token == null) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
      return;
    }
    // "Remember me" was unchecked at login -- the token still had to be
    // written to secure storage for API calls to work during that
    // session (see ApiClient's request interceptor), but a fresh cold
    // start honors the preference by discarding it here instead of
    // silently logging the person back in.
    if (!await _dio.readRememberMe()) {
      await _dio.clearToken();
      await _dio.clearRememberMe();
      state = state.copyWith(status: AuthStatus.unauthenticated);
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
      await _dio.saveCurrentUserId(user.id);
      await startBackgroundWatcher();
      return true;
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] ?? 'Login failed. Check your credentials.';
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
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier());

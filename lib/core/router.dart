import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../screens/login_screen.dart';
import '../screens/home_shell.dart';
import '../screens/notifications_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/tickets_screen.dart';
import '../screens/ticket_detail_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/task_detail_screen.dart';
import '../screens/alarm_screen.dart';
import '../core/notification_service.dart';
import '../core/pending_attachment_service.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authNotifier = ref.watch(authProvider.notifier);

  return GoRouter(
    initialLocation: '/splash',
    // Merges auth-state changes with pendingAlarmNotifier (set the
    // instant an overdue alarm fires/is tapped while the app's running,
    // or read from launch details for a cold start -- see main.dart and
    // notification_service.dart) so the redirect below re-runs for
    // either trigger.
    refreshListenable: Listenable.merge(
      [_AuthListenable(ref), pendingAlarmNotifier, pendingAttachmentTaskNotifier],
    ),
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;

      // AuthStatus.unknown = _restoreSession is still checking secure
      // storage / verifying the token against /auth/me. Routing to a
      // neutral splash for that window (instead of letting '/login'
      // render) is what stops a remembered session from flashing the
      // login form for a frame before redirecting itself to /home.
      if (auth.status == AuthStatus.unknown) {
        return loc == '/splash' ? null : '/splash';
      }
      if (auth.status == AuthStatus.unauthenticated) {
        return loc == '/login' ? null : '/login';
      }
      // authenticated -- an overdue alarm takes priority over wherever
      // the app would otherwise land.
      if (pendingAlarmNotifier.value != null && loc != '/home/alarm') {
        return '/home/alarm';
      }
      // A task attachment pick that survived an Android Activity teardown
      // (see pending_attachment_service.dart) -- jumps straight to that
      // task instead of ever rendering Home, the same "skip the default
      // landing spot" reasoning as the alarm redirect just above.
      final pendingTaskId = pendingAttachmentTaskNotifier.value;
      if (pendingTaskId != null && loc != '/home/tasks/$pendingTaskId') {
        return '/home/tasks/$pendingTaskId';
      }
      if (loc == '/login' || loc == '/splash') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeShell(),
        routes: [
          GoRoute(path: 'notifications', builder: (context, state) => const NotificationsScreen()),
          GoRoute(path: 'settings', builder: (context, state) => const SettingsScreen()),
          GoRoute(
            path: 'tickets',
            builder: (context, state) => const TicketsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => TicketDetailScreen(ticketId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: 'tasks/:id',
            // extra carries the ordered list of task ids from whichever
            // screen this was pushed from (see TaskDetailScreen's own doc
            // comment) -- optional, so callers with no meaningful list
            // (a subtask row, Dashboard, Calendar) can just omit it.
            builder: (context, state) {
              final extra = state.extra;
              final taskIds = extra is List ? extra.map((e) => e.toString()).toList() : null;
              return TaskDetailScreen(taskId: state.pathParameters['id']!, taskIds: taskIds);
            },
          ),
          GoRoute(path: 'alarm', builder: (context, state) => const AlarmScreen()),
        ],
      ),
    ],
  );
});

/// Bridges Riverpod state changes into something go_router's
/// `refreshListenable` (a plain Listenable) can react to, so the redirect
/// logic re-runs the instant login/logout changes AuthState.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

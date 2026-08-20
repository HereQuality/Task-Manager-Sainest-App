import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'api_client.dart';

/// Bumped every time a "task:created" or "task:updated" event arrives over
/// the socket -- Pending Approvals and Awaiting Approval both listen to
/// this and re-fetch, the same plain-ValueNotifier bridge pattern already
/// used app-wide (pendingAlarmNotifier, attachmentRecoveredNotifier, etc).
/// A counter rather than the event payload itself: neither screen needs to
/// know WHICH task changed, only "go re-fetch your list", and the server
/// already scopes what reaches this device (see SocketService.connect's own
/// doc comment on the `user:<userId>` room) so every event that arrives here
/// is one this account plausibly cares about.
final taskRealtimeEventNotifier = ValueNotifier<int>(0);

/// Singleton Socket.IO client -- one connection for the whole app, mirroring
/// client/src/lib/socket.js on the web side. Auth and room-joining are
/// identical to that file: same JWT passed as `auth.token` in the handshake,
/// verified server-side by config/socket.js the same way as every REST call,
/// and the server auto-joins every authenticated socket to its own
/// `user:<userId>` room -- nothing to explicitly join/leave here.
///
/// Deliberately scoped to task:created/task:updated only, not the List-room
/// (`list:join`) mechanism the web app also uses for its List/Board views --
/// this app has no equivalent live-editing List screen today, and
/// task.controller.js already emits every approval-relevant change
/// (submit-for-approval, approve, reject) straight to the delegator's and
/// assignee's `user:<userId>` rooms (see approveCompletion/rejectCompletion
/// and the requestingCompletionAsDelegate branch of updateTask), so the
/// per-user room alone is everything Pending Approvals/Awaiting Approval
/// need.
class SocketService {
  SocketService._();
  static final instance = SocketService._();

  socket_io.Socket? _socket;

  /// Connects using the currently-stored access token. Safe to call
  /// repeatedly -- a live connection is left alone rather than torn down
  /// and rebuilt, since main.dart calls this from both the auth-transition
  /// listener and every app-resume, and reconnecting on every single resume
  /// would just be wasted handshakes for a socket.io client that already
  /// reconnects automatically on its own after a real drop (wifi hiccup,
  /// phone sleep).
  Future<void> connect() async {
    if (_socket != null && _socket!.connected) return;

    final token = await ApiClient.instance.readToken();
    if (token == null) return;

    // kApiBaseUrl is the REST base (".../api/v1"); Socket.IO attaches to
    // the HTTP server's root, not under that path, so the "/api/v1" suffix
    // has to come off before handing the URL to the socket client -- same
    // split the web app's own VITE_API_BASE_URL/socket.js pairing avoids
    // needing, since its two env vars are already separately configured.
    final base = kApiBaseUrl.replaceFirst(RegExp(r'/api/v\d+/?$'), '');

    _socket?.dispose();
    _socket = socket_io.io(
      base,
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .build(),
    );

    _socket!
      ..onConnectError((_) {})
      ..onError((_) {})
      ..on('task:created', (_) => taskRealtimeEventNotifier.value++)
      ..on('task:updated', (_) => taskRealtimeEventNotifier.value++)
      ..connect();
  }

  /// Called on logout -- a stale token in an open socket would otherwise
  /// keep receiving another account's room membership until the process
  /// restarts, since the server only checks the JWT once, at the initial
  /// handshake.
  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}

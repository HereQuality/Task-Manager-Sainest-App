import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

// Scoped per-account (suffixed with currentUserId below), NOT just per
// device -- these two keys used to be shared by every account that ever
// signed into this device. Logging out of Person A and into Person B (or
// a fresh install straight into an account that had ALSO been used on
// this same device before, e.g. reinstalling over a restored backup) left
// `_initializedKey` already true and `seen` full of Person A's task ids,
// none of which match any of Person B's own tasks -- so every single one
// of Person B's tasks looked brand new against that stale snapshot, and
// _initializedKey being true (not the very first run anymore) meant
// firstRun's silent-baseline guard below didn't apply, so ALL of that
// person's existing tasks fired as "new" notifications the moment they
// logged in. Suffixing both keys by whoever's actually signed in now
// means each account gets its own clean baseline the first time it's
// ever active on this device, and switching back to an account that
// already has a recorded baseline picks up exactly where it left off.
const _seenVersionsKeyPrefix = 'task_seen_versions'; // {taskId: updatedAt-or-createdAt}
const _initializedKeyPrefix = 'task_update_tracker_initialized';

class TaskChangeResult {
  final String taskId;
  final String title;
  final String spaceName;
  final bool isNew;
  final String? activityMessage;
  // Who this task is assigned to -- lets a caller split "my own task
  // changed" from "a team member's task changed" (see
  // notifications_provider.dart/background_watcher_service.dart's
  // separate myTask*/teamTask* toggles), since myTasksProvider's task
  // list already mixes both together for a manager/senior.
  final String? assigneeId;

  TaskChangeResult({
    required this.taskId,
    required this.title,
    required this.spaceName,
    required this.isNew,
    this.activityMessage,
    this.assigneeId,
  });
}

/// Compares [tasks] (raw maps straight off GET /tasks/mine/all) against
/// what was last recorded on this device, returning every task that's
/// either brand new or has changed since the last check. Deliberately
/// plain Dart + SharedPreferences (no Riverpod) so both
/// notifications_provider.dart's foreground feed and
/// background_watcher_service.dart's polling isolate -- which can't share
/// Riverpod state with each other -- call the exact same detection logic
/// and write to the exact same persisted record, so a task caught by one
/// path doesn't get re-announced by the other a minute later.
///
/// The very first time this ever runs on a device (fresh install/login,
/// no prior record), every existing task would otherwise look "new" and
/// fire a burst of notifications for a person's entire backlog -- that
/// first call only takes a silent baseline snapshot instead.
///
/// [currentUserId] (see ApiClient.readCurrentUserId) suppresses a result
/// entirely when the task's latest activityLog entry was authored by the
/// person looking at their own device -- nobody needs a push telling
/// them about a change they just made themselves (e.g. assigning a task
/// to themselves, or completing it). The version is still recorded either
/// way, so a self-made change never gets re-flagged as "new" once
/// someone else's edit updates it in the future.
Future<List<TaskChangeResult>> detectTaskChanges(
  List<Map<String, dynamic>> tasks, {
  String? currentUserId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  // Falls back to the old unscoped keys only when currentUserId is
  // somehow unavailable (readCurrentUserId() returning null despite an
  // authenticated fetch having just happened, which shouldn't occur in
  // practice) -- still better than crashing, and this device-wide
  // fallback record only actually differs from a real account's if that
  // edge case is ever hit.
  final initializedKey = currentUserId != null ? '${_initializedKeyPrefix}_$currentUserId' : _initializedKeyPrefix;
  final seenVersionsKey = currentUserId != null ? '${_seenVersionsKeyPrefix}_$currentUserId' : _seenVersionsKeyPrefix;
  final firstRun = !(prefs.getBool(initializedKey) ?? false);
  final rawMap = prefs.getString(seenVersionsKey);
  final seen = rawMap != null ? Map<String, dynamic>.from(jsonDecode(rawMap) as Map) : <String, dynamic>{};
  final updated = Map<String, dynamic>.from(seen);

  final results = <TaskChangeResult>[];

  for (final t in tasks) {
    final version = (t['updatedAt'] ?? t['createdAt'] ?? '').toString();
    if (version.isEmpty) continue;

    final title = (t['title'] ?? t['name'] ?? 'Untitled task').toString();
    final id = (t['_id'] ?? t['id'] ?? title).toString();
    final spaceName = (t['spaceName'] ?? '').toString();
    final assigneeRaw = t['assigneeId'];
    final assigneeId = (assigneeRaw is Map ? assigneeRaw['_id'] : assigneeRaw)?.toString();

    final isSelfMade = currentUserId != null && _latestActivityActorId(t) == currentUserId;

    final lastSeen = seen[id] as String?;
    if (lastSeen == null) {
      updated[id] = version;
      if (!firstRun && !isSelfMade) {
        results.add(TaskChangeResult(
          taskId: id,
          title: title,
          spaceName: spaceName,
          isNew: true,
          activityMessage: _latestActivityMessage(t),
          assigneeId: assigneeId,
        ));
      }
      continue;
    }
    if (lastSeen != version) {
      updated[id] = version;
      if (!isSelfMade) {
        results.add(TaskChangeResult(
          taskId: id,
          title: title,
          spaceName: spaceName,
          isNew: false,
          activityMessage: _latestActivityMessage(t),
          assigneeId: assigneeId,
        ));
      }
    }
  }

  if (firstRun) await prefs.setBool(initializedKey, true);
  await prefs.setString(seenVersionsKey, jsonEncode(updated));
  return results;
}

// Task.js's activityLog is permanent and append-only (see the server
// model), so the last element is always the most recent entry -- its
// `message` is the same human-readable line ("changed due date from X to
// Y", "changed status to COMPLETE", etc.) TaskDetailModal.jsx already
// shows in its Activity panel, reused here as the notification body.
String? _latestActivityMessage(Map<String, dynamic> t) {
  final log = t['activityLog'];
  if (log is List && log.isNotEmpty) {
    final last = log.last;
    if (last is Map && last['message'] != null) return last['message'].toString();
  }
  return null;
}

// actorId only exists on entries logged after models/Task.js grew that
// field -- an older entry (or one missing it entirely) simply never
// matches currentUserId below, so this only ever fails "open" (still
// notifies) rather than silently suppressing something it shouldn't.
String? _latestActivityActorId(Map<String, dynamic> t) {
  final log = t['activityLog'];
  if (log is List && log.isNotEmpty) {
    final last = log.last;
    if (last is Map && last['actorId'] != null) return last['actorId'].toString();
  }
  return null;
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/tasks_provider.dart';

/// True only for a request that never reached the server at all (no
/// internet, DNS failure, timed out waiting for a reply) -- as opposed to
/// a real response the server sent back (400 validation error, 401
/// expired session, 500). Only the former is safe to queue/keep retrying,
/// since the latter would just fail identically every time. Shared
/// between add_task_sheet.dart (deciding whether to enqueue a failed add)
/// and flush() below (deciding whether to keep retrying a queued one) so
/// the two can never disagree on what counts as "offline".
bool isConnectivityError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return true;
    default:
      return false;
  }
}

final _idRandom = Random();
String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_idRandom.nextInt(1 << 31)}';

/// One "Add Task" request that couldn't reach the server, saved so it can
/// be replayed exactly as add_task_sheet.dart's per-target loop would have
/// done the first time -- see createTaskInSpace/assignTaskAndMoveSpace in
/// tasks_provider.dart, the same two calls flush() below makes.
///
/// `id` exists purely so flush() can find and remove/update THIS specific
/// entry in a freshly re-read copy of the queue (see _synchronized) --
/// object identity doesn't survive a round trip through JSON, and matching
/// on content alone would misfire for two genuinely identical queued
/// tasks (same name/space/assignee, added twice offline).
class _QueuedTask {
  final String id;
  final String spaceId;
  final String name;
  final DateTime? startDate;
  final DateTime? dueDate;
  final DateTime? reminderAt;
  final List<DateTime> extraReminders;
  final String? priority;
  final String? projectId;
  final String? assigneeId;
  final String? targetSpaceId;
  int attempts;
  // Set the moment createTaskInSpace succeeds, and persisted immediately
  // (see flush() below) BEFORE assignTaskAndMoveSpace is even attempted --
  // without this, a connectivity drop between those two calls (create
  // succeeds, assign then fails) would re-run createTaskInSpace on the
  // next retry too, since the whole pair was treated as one all-or-
  // nothing unit, leaving the task created twice: once correctly
  // assigned, and one orphaned unassigned duplicate left behind by the
  // first (successful but never retried) create. With this, a retry
  // after a partial failure resumes at the assign step only.
  String? createdTaskId;

  _QueuedTask({
    required this.id,
    required this.spaceId,
    required this.name,
    this.startDate,
    this.dueDate,
    this.reminderAt,
    this.extraReminders = const [],
    this.priority,
    this.projectId,
    this.assigneeId,
    this.targetSpaceId,
    this.attempts = 0,
    this.createdTaskId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'spaceId': spaceId,
        'name': name,
        'startDate': startDate?.toIso8601String(),
        'dueDate': dueDate?.toIso8601String(),
        'reminderAt': reminderAt?.toIso8601String(),
        'extraReminders': extraReminders.map((d) => d.toIso8601String()).toList(),
        'priority': priority,
        'projectId': projectId,
        'assigneeId': assigneeId,
        'targetSpaceId': targetSpaceId,
        'attempts': attempts,
        'createdTaskId': createdTaskId,
      };

  // Deliberately falls back to a fresh id for anything queued before this
  // field existed (an app update landing mid-queue) rather than throwing
  // and losing the whole entry -- see _read()'s own per-item try/catch for
  // why losing just this one field must never cascade into losing others.
  static _QueuedTask fromJson(Map<String, dynamic> json) => _QueuedTask(
        id: json['id'] as String? ?? _newId(),
        spaceId: json['spaceId'] as String,
        name: json['name'] as String,
        startDate: json['startDate'] != null ? DateTime.parse(json['startDate'] as String) : null,
        dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate'] as String) : null,
        reminderAt: json['reminderAt'] != null ? DateTime.parse(json['reminderAt'] as String) : null,
        extraReminders:
            (json['extraReminders'] as List? ?? const []).map((d) => DateTime.parse(d as String)).toList(),
        priority: json['priority'] as String?,
        projectId: json['projectId'] as String?,
        assigneeId: json['assigneeId'] as String?,
        targetSpaceId: json['targetSpaceId'] as String?,
        attempts: json['attempts'] as int? ?? 0,
        createdTaskId: json['createdTaskId'] as String?,
      );
}

/// Lets "Add Task" survive a dead connection instead of just reporting
/// "Failed to add task" with no way to recover short of retyping it --
/// add_task_sheet.dart calls enqueue() here instead of counting a target
/// as failed when the error is connectivity-shaped (see isConnectivityError
/// above), and this replays it automatically the moment the device is
/// back online.
///
/// Three triggers call flush(), same redundancy PendingAttachmentService
/// uses in main.dart and for the same reason: any one of them can be
/// missed (a connectivity event firing while the app isn't running to
/// hear it, a cold start landing on an already-connected network before
/// the stream emits anything) --
///   1. init() checks the CURRENT connectivity once at startup, since
///      onConnectivityChanged only reports future changes;
///   2. the live onConnectivityChanged subscription below;
///   3. app resume and login, wired in main.dart next to the identical
///      PendingAttachmentService hooks.
class OfflineTaskQueue {
  OfflineTaskQueue._();
  static final instance = OfflineTaskQueue._();

  static const _key = 'offline_task_queue';
  // A request still failing after this many connectivity-triggered
  // retries almost certainly isn't a connectivity problem any more (e.g.
  // the project or assignee it pointed at was deleted in the meantime),
  // so it's dropped rather than retried forever on every future blip.
  static const _maxAttempts = 8;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _flushing = false;

  // Every read-modify-write of the persisted queue (enqueue's append, and
  // each per-item update inside flush) goes through this same chained
  // Future instead of running freely -- without it, someone adding a new
  // task (enqueue) at the exact moment flush() is mid-loop can read the
  // queue before flush's latest write lands, then write back a version
  // that resurrects an item flush had just removed after successfully
  // syncing it, causing that task to be recreated on the server as a
  // duplicate on the next flush.
  Future<void> _chain = Future.value();
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    // Swallow the error here so a failed action doesn't permanently wedge
    // the chain for every future caller -- the real error still propagates
    // to whoever is awaiting `result` below.
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Bumped once per flush() that actually synced something, so any
  /// screen needing its task list current can listen for this and
  /// invalidate -- same ValueNotifier bridge main.dart already uses for
  /// attachmentRecoveredNotifier, since this service has no Riverpod ref
  /// of its own.
  final syncedNotifier = ValueNotifier<int>(0);

  /// Set to how many queued tasks were just given up on for good, and
  /// NEVER got created on the server at all -- the server itself rejected
  /// the create call, or it hit _maxAttempts. main.dart listens for this
  /// and shows a SnackBar telling the person to re-add it, since silently
  /// dropping a task someone explicitly added would be worse than the
  /// original "Failed to add task" message it replaced.
  final droppedNotifier = ValueNotifier<int>(0);

  /// Separate from droppedNotifier above -- these DID get created on the
  /// server (createdTaskId was already set), but the follow-up
  /// assignTaskAndMoveSpace step then failed permanently. Telling the
  /// person to "re-add" one of these (droppedNotifier's message) would
  /// create a genuine duplicate: the first copy already exists,
  /// unassigned, in its original Space. main.dart shows a different
  /// message for this case pointing them at the task list instead.
  final droppedAfterCreateNotifier = ValueNotifier<int>(0);

  Future<void> init() async {
    final current = await Connectivity().checkConnectivity();
    if (current.any((r) => r != ConnectivityResult.none)) {
      unawaited(flush());
    }
    _sub ??= Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        unawaited(flush());
      }
    });
  }

  Future<void> enqueue({
    required String spaceId,
    required String name,
    DateTime? startDate,
    DateTime? dueDate,
    DateTime? reminderAt,
    List<DateTime> extraReminders = const [],
    String? priority,
    String? projectId,
    String? assigneeId,
    String? targetSpaceId,
    // Set by a caller that got as far as creating the task on the server
    // before THEN hitting a connectivity error on the assign step (see
    // add_task_sheet.dart's own catch block) -- without this, flush()
    // would re-run createTaskInSpace from scratch on retry, leaving the
    // already-created task orphaned/unassigned and a second, duplicate
    // one created alongside it.
    String? createdTaskId,
  }) {
    return _synchronized(() async {
      final queue = await _read();
      queue.add(_QueuedTask(
        id: _newId(),
        spaceId: spaceId,
        name: name,
        startDate: startDate,
        dueDate: dueDate,
        reminderAt: reminderAt,
        extraReminders: extraReminders,
        priority: priority,
        projectId: projectId,
        assigneeId: assigneeId,
        targetSpaceId: targetSpaceId,
        createdTaskId: createdTaskId,
      ));
      await _write(queue);
    });
  }

  Future<void> flush() async {
    // Re-entrancy guard -- a flaky connection bouncing up/down can fire
    // onConnectivityChanged again before the first flush finishes, which
    // would otherwise send two flushes racing through the same queue
    // (the _synchronized lock would serialize their individual writes,
    // but two overlapping flushes would still both try to sync the same
    // still-queued item at once, double-creating it on the server).
    if (_flushing) return;
    _flushing = true;
    try {
      // A snapshot purely to decide iteration order/content for this
      // pass -- every actual mutation below re-reads the live queue by id
      // inside _synchronized, so a concurrent enqueue() never gets lost
      // even though this snapshot can go stale.
      final snapshot = await _read();
      if (snapshot.isEmpty) return;
      var syncedAny = false;
      var droppedCount = 0;
      var droppedAfterCreateCount = 0;
      // Routes a drop decision into the right counter above based on
      // whether the server-side task already exists for this item --
      // shared by all three drop sites below so they can't drift apart.
      void drop(_QueuedTask item) {
        if ((item.createdTaskId ?? '').isNotEmpty) {
          droppedAfterCreateCount += 1;
        } else {
          droppedCount += 1;
        }
      }

      for (final item in snapshot) {
        try {
          // Resume at the assign step if a PREVIOUS attempt already got
          // the task created (see createdTaskId's own doc comment) --
          // never re-runs createTaskInSpace once it's succeeded once for
          // this queued item.
          var taskId = item.createdTaskId;
          if (taskId == null || taskId.isEmpty) {
            taskId = await createTaskInSpace(
              item.spaceId,
              name: item.name,
              startDate: item.startDate,
              dueDate: item.dueDate,
              reminderAt: item.reminderAt,
              extraReminders: item.extraReminders,
              priority: item.priority,
              projectId: item.projectId,
            );
            // A 2xx response with no usable _id (a malformed/unexpected
            // body) is NOT a success -- treated as a thrown failure so it
            // falls into the catch below and gets retried/dropped-with-
            // notice like any other failure, instead of silently being
            // marked synced (and, if an assignee was set, the assign step
            // skipped entirely) with no record it ever happened.
            if (taskId.isEmpty) {
              throw Exception('createTaskInSpace returned no task id for queued item ${item.id}');
            }
            item.createdTaskId = taskId;
            // Persisted BEFORE attempting the assign step below -- if
            // assign now throws (even a non-connectivity error), the next
            // read of this item still has createdTaskId set, so flush()
            // (or the dropped-notice path) never loses track of the fact
            // that a server-side task already exists for it.
            await _update(item);
          }
          if (item.assigneeId != null) {
            await assignTaskAndMoveSpace(taskId, item.assigneeId!, targetSpaceId: item.targetSpaceId);
          }
          syncedAny = true;
          await _remove(item.id);
        } on DioException catch (e) {
          // A 401 is treated the same as a connectivity error, NOT as a
          // permanent rejection -- it means "not authenticated right now",
          // which this task recovers from the moment someone logs back in
          // (main.dart's own ref.listen(authProvider...) already calls
          // flush() again right then). Without this, a task queued before
          // a logout would get permanently dropped the instant
          // connectivity returns while still on the login screen -- the
          // create/assign call reaches the server fine and gets a real
          // 401 response, which isn't a connectivity error at all, so it
          // would otherwise fall into the "stop immediately" branch below
          // and be lost even though nothing about the task itself was
          // ever invalid.
          if (isConnectivityError(e) || e.response?.statusCode == 401) {
            // Still offline (or signed out) -- keep it for the next
            // flush, capped so a task that genuinely never succeeds
            // doesn't retry forever.
            item.attempts += 1;
            if (item.attempts >= _maxAttempts) {
              drop(item);
              await _remove(item.id);
            } else {
              await _update(item);
            }
          } else {
            // A real response came back (validation error, expired
            // session, deleted project/assignee) -- retrying would just
            // fail the exact same way every time, so stop immediately
            // instead of burning through _maxAttempts first.
            drop(item);
            await _remove(item.id);
          }
        } catch (_) {
          item.attempts += 1;
          if (item.attempts >= _maxAttempts) {
            drop(item);
            await _remove(item.id);
          } else {
            await _update(item);
          }
        }
        // Either branch above falls through to here and loops again --
        // one bad/still-offline item must not block the rest of the
        // batch behind it.
      }
      if (syncedAny) syncedNotifier.value++;
      if (droppedCount > 0) droppedNotifier.value += droppedCount;
      if (droppedAfterCreateCount > 0) droppedAfterCreateNotifier.value += droppedAfterCreateCount;
    } finally {
      _flushing = false;
    }
  }

  /// Removes one item by id from the CURRENT persisted queue -- re-reads
  /// fresh under the lock rather than trusting flush()'s snapshot, so a
  /// task enqueue()'d while this flush pass was already running is never
  /// silently dropped by an overwrite.
  Future<void> _remove(String id) {
    return _synchronized(() async {
      final queue = await _read();
      queue.removeWhere((q) => q.id == id);
      await _write(queue);
    });
  }

  Future<void> _update(_QueuedTask updated) {
    return _synchronized(() async {
      final queue = await _read();
      final idx = queue.indexWhere((q) => q.id == updated.id);
      if (idx != -1) {
        queue[idx] = updated;
        await _write(queue);
      }
    });
  }

  Future<List<_QueuedTask>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    List<dynamic> list;
    try {
      list = jsonDecode(raw) as List;
    } catch (_) {
      return [];
    }
    // Each entry parsed independently -- one malformed/incompatible item
    // (a future app update changing this shape, a one-off write glitch)
    // must not take the rest of a device's genuinely pending queue down
    // with it.
    final result = <_QueuedTask>[];
    for (final e in list) {
      try {
        result.add(_QueuedTask.fromJson(e as Map<String, dynamic>));
      } catch (_) {
        // Skip just this one entry.
      }
    }
    return result;
  }

  Future<void> _write(List<_QueuedTask> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(queue.map((e) => e.toJson()).toList()));
  }
}

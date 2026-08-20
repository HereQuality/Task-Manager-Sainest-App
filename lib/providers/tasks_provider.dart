import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import 'auth_provider.dart';

/// Set from Dashboard's stat cards (Total tasks/On time completion/
/// Overdue/In progress/Delayed) to jump straight to the Tasks tab
/// pre-filtered to that category. Consumed once by TasksScreen's own
/// listener and reset back to null immediately after -- same
/// signal-then-clear pattern as notification_service.dart's
/// pendingAlarmNotifier and pending_attachment_service.dart's
/// pendingAttachmentTaskNotifier. An empty set is a real, distinct value
/// from null here: it means "switch to Tasks with every status filter
/// cleared" (the Total tasks card), not "nothing pending".
final pendingTaskStatusFilter = ValueNotifier<Set<String>?>(null);

/// Set alongside pendingTaskStatusFilter above so HomeShell's bottom-nav
/// index actually switches to the Tasks tab when a stat card is tapped --
/// DashboardScreen has no direct reference to HomeShell's own tab-index
/// state, so this is the same kind of cross-screen signal.
final pendingHomeTabIndex = ValueNotifier<int?>(null);

/// Every task assigned to the logged-in user, across every Space --
/// GET /api/v1/tasks/mine/all (same endpoint the web Calendar page uses).
final myTasksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  try {
    final res = await ApiClient.instance.dio.get('/tasks/mine/all');
    final data = res.data['data'] ?? res.data['tasks'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // 403 -- this account isn't authorized to list tasks this way (role/
    // permission gate on the backend), not "no tasks exist". Treated the
    // same as empty rather than surfacing a raw permissions error --
    // notificationsFeedProvider watches this too, so an uncaught 403 here
    // would otherwise take down the whole Notifications screen as well.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
});

// Scoped explicitly to the logged-in user's own id -- sending no
// assigneeIds at all makes the backend default to "me + every
// subordinate" (or literally everyone, for a SuperAdmin -- see
// getDashboardStats in task.controller.js), a much broader set than
// this one account's own numbers, which is what the mobile Home
// screen's ATS/OTC cards are meant to show (same personal scope as
// myTasksProvider's "/tasks/mine/all" above).
final dashboardStatsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final user = ref.watch(authProvider).user;
  final res = await ApiClient.instance.dio.get(
    '/tasks/dashboard-stats',
    queryParameters: user != null ? {'assigneeIds': user.id} : null,
  );
  return Map<String, dynamic>.from(res.data['data'] ?? {});
});

Future<void> updateTaskStatus(String taskId, String status) async {
  await ApiClient.instance.dio.put('/tasks/$taskId', data: {'status': status});
}

/// Full task-details edit -- PUT /api/v1/tasks/:id with whichever of
/// name/assigneeId/priority/startDate/dueDate the Edit sheet collected.
/// Same route/fields the web app's TaskDetailModal uses, so the server's
/// existing permission rules apply identically on mobile: SuperAdmin/
/// Teams-Full-Access can always edit, everyone else only within 5 minutes
/// of the task being assigned (see isPastEditGracePeriod/
/// canBypassTaskLocks in task.controller.js) -- past that window this
/// throws a 403 with a ready-to-show message, which the caller is
/// expected to surface as-is rather than a generic error.
Future<void> updateTaskDetails(
  String taskId, {
  required String name,
  String? assigneeId,
  String? priority,
  DateTime? startDate,
  DateTime? dueDate,
  DateTime? reminderAt,
}) async {
  await ApiClient.instance.dio.put('/tasks/$taskId', data: {
    'name': name,
    'assigneeId': assigneeId,
    'priority': priority,
    'startDate': startDate?.toUtc().toIso8601String(),
    'dueDate': dueDate?.toUtc().toIso8601String(),
    'reminderAt': reminderAt?.toUtc().toIso8601String(),
  });
}

/// Direct reports' tasks overdue 24h+ and still incomplete -- GET
/// /api/v1/tasks/team/overdue-escalations. Returns an empty list for
/// anyone with no direct reports (the server checks, not this app), so
/// it's safe to call unconditionally regardless of whether the logged-in
/// person is actually a manager. Plain function, not a Riverpod
/// provider, since background_watcher_service.dart's isolate has no
/// ProviderScope to watch one through -- see notifications_provider.dart
/// and that file for the two places this gets called from.
Future<List<Map<String, dynamic>>> fetchTeamOverdueEscalations() async {
  try {
    final res =
        await ApiClient.instance.dio.get('/tasks/team/overdue-escalations');
    final data = res.data['data'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // See myTasksProvider's own catch above -- same reasoning.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
}

/// A delegator's own pending "please approve this completion" requests --
/// GET /api/v1/tasks/pending-approvals. Needed because myTasksProvider
/// above is scoped to assigneeId, so a person who delegated a task (but
/// isn't its assignee) would otherwise never see this update on their
/// phone -- same "plain function, not a provider" reasoning as
/// fetchTeamOverdueEscalations.
Future<List<Map<String, dynamic>>> fetchPendingApprovals() async {
  try {
    final res = await ApiClient.instance.dio.get('/tasks/pending-approvals');
    final data = res.data['data'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // See myTasksProvider's own catch above -- same reasoning.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
}

/// Riverpod wrapper around fetchPendingApprovals above, for the Tasks
/// screen's own "DELEGATED" section -- the plain function itself stays,
/// since background_watcher_service.dart's isolate still needs to call it
/// with no ProviderScope available.
final pendingApprovalsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return fetchPendingApprovals();
});

/// POST /api/v1/tasks/:id/approve-completion -- only the task's delegator
/// (createdBy) can call this, and only while completionApproval.status is
/// "PENDING" (server enforces both; see approveCompletion in
/// task.controller.js). Moves the task to COMPLETE.
Future<void> approveTaskCompletion(String taskId) async {
  await ApiClient.instance.dio.post('/tasks/$taskId/approve-completion');
}

/// POST /api/v1/tasks/:id/reject-completion -- same delegator-only/PENDING
/// gate as approveTaskCompletion, but leaves task.status exactly as it
/// was (never COMPLETE) and bounces it back to the assignee with an
/// optional reason attached (see rejectCompletion in task.controller.js).
Future<void> rejectTaskCompletion(String taskId, {String? reason}) async {
  await ApiClient.instance.dio.post('/tasks/$taskId/reject-completion', data: {
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
  });
}

/// The assignee-side mirror of fetchPendingApprovals above -- every task
/// the logged-in person is the ASSIGNEE of that they've already marked
/// complete and is still sitting on completionApproval.status "PENDING"
/// (still waiting) or "REJECTED" (sent back, with a reason). GET
/// /api/v1/tasks/my-submitted-approvals -- same "Awaiting Approval" name
/// the web app's own button uses (MySubmittedApprovalsModal.jsx), kept
/// identical here so the two apps talk about this the same way.
Future<List<Map<String, dynamic>>> fetchMySubmittedApprovals() async {
  try {
    final res = await ApiClient.instance.dio.get('/tasks/my-submitted-approvals');
    final data = res.data['data'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // See myTasksProvider's own catch above -- same reasoning.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
}

/// Riverpod wrapper around fetchMySubmittedApprovals above, for the
/// dedicated "Awaiting Approval" screen.
final mySubmittedApprovalsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return fetchMySubmittedApprovals();
});

/// Every task with a pending 5-minute-lock override request (someone who
/// isn't Full Access asking to edit/delete a task past its normal edit
/// window) -- GET /api/v1/tasks/lock-override-requests. Server-side this
/// returns an empty list for anyone who isn't Full Access rather than
/// 403ing (see listLockOverrideRequests in task.controller.js), so it's
/// safe to call unconditionally, same as fetchTeamOverdueEscalations above.
///
/// Deliberately kept separate from fetchPendingApprovals/
/// pendingApprovalsProvider above rather than merged into it -- that one
/// is also watched by TasksScreen's DELEGATED group, which expects every
/// item to have completion-approval shape (completionApproval, etc); a
/// lock-override item has a different shape (overrideType, reason,
/// requestedByName) entirely. PendingApprovalsScreen merges the two lists
/// itself for display, matching the web app's PendingApprovalsModal.jsx
/// (usePendingApprovals), which does the same two-calls-merged-in-the-
/// component pattern rather than one combined endpoint.
Future<List<Map<String, dynamic>>> fetchLockOverrideRequests() async {
  try {
    final res = await ApiClient.instance.dio.get('/tasks/lock-override-requests');
    final data = res.data['data'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // See myTasksProvider's own catch above -- same reasoning.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
}

final lockOverrideRequestsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return fetchLockOverrideRequests();
});

/// POST /api/v1/tasks/:id/lock-override/approve -- any Full Access person
/// can call this (server enforces via canBypassTaskLocks), not just the
/// task's own creator/delegator. Applies the requester's saved patch (EDIT)
/// or deletes the task (DELETE); see approveLockOverride in
/// task.controller.js.
Future<void> approveLockOverride(String taskId) async {
  await ApiClient.instance.dio.post('/tasks/$taskId/lock-override/approve');
}

/// POST /api/v1/tasks/:id/lock-override/reject -- leaves the task
/// completely untouched, only the request's own status changes.
Future<void> rejectLockOverride(String taskId, {String? reason}) async {
  await ApiClient.instance.dio.post('/tasks/$taskId/lock-override/reject', data: {
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
  });
}

/// A task's subtasks -- GET /api/v1/tasks/:id/subtasks (same endpoint
/// TaskDetailModal.jsx's Subtasks panel uses).
final subtasksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, taskId) async {
  final res = await ApiClient.instance.dio.get('/tasks/$taskId/subtasks');
  final data = res.data['data'] ?? [];
  return List<Map<String, dynamic>>.from(data);
});

/// Creates a subtask under a task -- POST /api/v1/tasks/:id/subtasks.
/// Only `name` is required here even though the server also accepts
/// status/assigneeId/dueDate/priority (see createSubtask in
/// task.controller.js) -- the mobile "quick add" sheet is deliberately
/// minimal, same reasoning as everywhere else this app creates something
/// on the go; a subtask needing more detail can be opened and edited
/// afterward like any other task.
Future<void> createSubtask(String parentTaskId, {required String name}) async {
  await ApiClient.instance.dio
      .post('/tasks/$parentTaskId/subtasks', data: {'name': name});
}

/// Replaces a task's whole checklists array -- PUT /api/v1/tasks/:id
/// {checklists}, the same "send the whole array back" pattern the web
/// app uses (Task.js's own doc comment: "same as tags"). The caller is
/// expected to send the FULL array (existing checklists/items plus
/// whatever just changed), not a partial patch.
Future<void> updateTaskChecklists(
    String taskId, List<Map<String, dynamic>> checklists) async {
  await ApiClient.instance.dio
      .put('/tasks/$taskId', data: {'checklists': checklists});
}

/// Uploads a file to a task -- POST /api/v1/tasks/:id/attachments,
/// multipart field "file" (matches uploadTaskAttachment.single("file")
/// server-side). Any file type/format works here, camera photo or picked
/// document alike -- see AttachmentSchema's own doc comment in Task.js.
Future<void> uploadTaskAttachment(String taskId, String filePath) async {
  final formData = FormData.fromMap({
    // lookupMediaType is required -- see createTicket's own doc comment
    // in tickets_provider.dart for why fromFile alone silently sends
    // application/octet-stream instead of the file's real type.
    'file': await MultipartFile.fromFile(filePath,
        contentType: MultipartFile.lookupMediaType(filePath)),
  });
  await ApiClient.instance.dio.post(
    '/tasks/$taskId/attachments',
    data: formData,
    options: Options(contentType: 'multipart/form-data'),
  );
}

/// DELETE /api/v1/tasks/:id/attachments/:attachmentId -- server enforces
/// who's allowed (the task's delegator/delegate, or SuperAdmin/Teams-
/// Full-Access; see assertCanEditTask in task.controller.js).
Future<void> deleteTaskAttachment(String taskId, String attachmentId) async {
  await ApiClient.instance.dio
      .delete('/tasks/$taskId/attachments/$attachmentId');
}

/// Posts a text message to a task's comment thread -- POST
/// /api/v1/tasks/:id/comments {message}.
Future<void> addTaskTextComment(String taskId, String message) async {
  await ApiClient.instance.dio
      .post('/tasks/$taskId/comments', data: {'message': message});
}

/// Posts a recorded voice message to a task's comment thread -- same
/// route as the text version above, but multipart with field "audio"
/// (matches uploadTaskCommentAudio.single("audio") server-side) plus how
/// long the recording runs, so the UI can show a duration without
/// decoding the audio file itself.
Future<void> addTaskAudioComment(String taskId, String audioPath,
    {required int durationSeconds}) async {
  final formData = FormData.fromMap({
    'durationSeconds': durationSeconds,
    'audio': await MultipartFile.fromFile(audioPath,
        contentType: MultipartFile.lookupMediaType(audioPath)),
  });
  await ApiClient.instance.dio.post(
    '/tasks/$taskId/comments',
    data: formData,
    options: Options(contentType: 'multipart/form-data'),
  );
}

/// DELETE /api/v1/tasks/:id/comments/:commentId -- server enforces that
/// only the message's own author (or SuperAdmin/Teams-Full-Access) can
/// remove it.
Future<void> deleteTaskComment(String taskId, String commentId) async {
  await ApiClient.instance.dio.delete('/tasks/$taskId/comments/$commentId');
}

/// A single task, full detail -- GET /api/v1/tasks/:id (same endpoint
/// TaskDetailModal.jsx uses on the web). Backs the Task Detail screen
/// opened by tapping a task card anywhere (Tasks tab, Home's "Due soon",
/// or a day's tasks on the Calendar tab).
final taskDetailProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, taskId) async {
  final res = await ApiClient.instance.dio.get('/tasks/$taskId');
  return Map<String, dynamic>.from(res.data['data'] ?? {});
});

/// Creates a task directly in a Space's own root List -- POST
/// /api/v1/tasks/space/:spaceId (same endpoint the web app's Space page
/// "+ Add task" uses). Backs the bottom nav's "+" Add task sheet.
Future<void> createTaskInSpace(
  String spaceId, {
  required String name,
  String? assigneeId,
  DateTime? startDate,
  DateTime? dueDate,
  DateTime? reminderAt,
  String? priority,
}) async {
  // .toUtc() before serializing is load-bearing: DateTime(...) built from
  // date/time pickers is in the DEVICE's local time zone, and plain
  // .toIso8601String() on a non-UTC DateTime omits any offset/`Z` suffix
  // (e.g. "2026-08-05T16:15:00.000"). The server (new Date(...) in
  // Node) then parses that ambiguous string as local time IN WHATEVER
  // TIME ZONE THE SERVER RUNS IN, not the phone's -- so "4:15 PM" picked
  // on a phone in IST could get stored as 4:15 PM UTC, landing 5.5 hours
  // off once anything (the web app, this app) converts it back to local
  // time for display. Converting to UTC first makes the serialized
  // string end in "Z", which is unambiguous everywhere.
  await ApiClient.instance.dio.post('/tasks/space/$spaceId', data: {
    'name': name,
    if (assigneeId != null) 'assigneeId': assigneeId,
    if (startDate != null) 'startDate': startDate.toUtc().toIso8601String(),
    if (dueDate != null) 'dueDate': dueDate.toUtc().toIso8601String(),
    if (reminderAt != null) 'reminderAt': reminderAt.toUtc().toIso8601String(),
    if (priority != null) 'priority': priority,
  });
}

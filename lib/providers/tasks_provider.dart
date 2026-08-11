import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import 'auth_provider.dart';

/// Every task assigned to the logged-in user, across every Space --
/// GET /api/v1/tasks/mine/all (same endpoint the web Calendar page uses).
final myTasksProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
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
final dashboardStatsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
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
    final res = await ApiClient.instance.dio.get('/tasks/team/overdue-escalations');
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

/// A single task, full detail -- GET /api/v1/tasks/:id (same endpoint
/// TaskDetailModal.jsx uses on the web). Backs the Task Detail screen
/// opened by tapping a task card anywhere (Tasks tab, Home's "Due soon",
/// or a day's tasks on the Calendar tab).
final taskDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, taskId) async {
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
    if (priority != null) 'priority': priority,
  });
}

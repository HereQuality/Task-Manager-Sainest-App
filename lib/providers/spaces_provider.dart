import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

/// Spaces the current user belongs to -- GET /api/v1/spaces (same
/// endpoint the web app's sidebar/Spaces page uses). Powers the Space
/// picker in the "Add task" sheet.
final spacesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ApiClient.instance.dio.get('/spaces');
  final data = res.data['data'] ?? [];
  return List<Map<String, dynamic>>.from(data);
});

/// Which (active) Space a given employee currently belongs to -- GET
/// /api/v1/spaces/for-employee/:employeeId. Deliberately open to any
/// authenticated user (see space.controller.js#getSpaceForEmployee's own
/// doc comment), unlike spacesProvider above, which is scoped to Spaces
/// THIS account can see. Used by the Add Task sheet so its Space picker
/// shows the CORRECT team the moment an assignee is chosen, even for
/// someone without Full Access whose own spacesProvider list wouldn't
/// otherwise include that team at all -- previously that case (a
/// non-Full-Access person assigning someone on a different team) left
/// the picker silently stuck on the creator's own team, with no visible
/// sign anything was wrong, even though the task DOES still end up
/// correctly relocated server-side (see tasks_provider.dart's
/// assignTaskAndMoveSpace) -- this fixes the display, not the placement,
/// which was already correct.
Future<Map<String, dynamic>?> fetchEmployeeSpace(String employeeId) async {
  final res = await ApiClient.instance.dio.get('/spaces/for-employee/$employeeId');
  final data = res.data['data'];
  return data is Map ? Map<String, dynamic>.from(data) : null;
}

Set<String>? _cachedVisibleSpaceIds;
DateTime? _cachedVisibleSpaceIdsAt;

/// Plain (non-Riverpod) counterpart to spacesProvider above, for
/// background_watcher_service.dart's polling isolate, which can't watch a
/// FutureProvider -- and for notifications_provider.dart's foreground
/// pass, which could `ref.watch(spacesProvider.future)` directly but uses
/// this instead so both paths share one cache/TTL instead of each hitting
/// GET /spaces independently.
///
/// The ids returned are exactly "Spaces this account can see" -- every
/// active Space it's a member of, or literally every active Space for
/// SuperAdmin/a role with Full Access on Teams (see space.controller.js#
/// listMySpaces, the same endpoint this calls). Used to gate "team task"
/// notifications (see TaskChangeResult.spaceId's doc comment) to Spaces
/// the viewer is actually part of, rather than every Space any direct/
/// indirect report happens to have a task in.
///
/// Cached 5 minutes, same window fetchNotificationSchedule uses -- this
/// is consulted on every tick (once a minute for the background watcher),
/// and someone's own Space membership changes rarely enough that a few
/// minutes of staleness is a non-issue, while re-fetching it every single
/// tick would be pure waste.
Future<Set<String>> fetchMyVisibleSpaceIds({bool forceRefresh = false}) async {
  final now = DateTime.now();
  if (!forceRefresh &&
      _cachedVisibleSpaceIds != null &&
      _cachedVisibleSpaceIdsAt != null &&
      now.difference(_cachedVisibleSpaceIdsAt!) < const Duration(minutes: 5)) {
    return _cachedVisibleSpaceIds!;
  }
  try {
    final res = await ApiClient.instance.dio.get('/spaces').timeout(const Duration(seconds: 8));
    final data = List<Map<String, dynamic>>.from(res.data['data'] ?? []);
    final ids = data.map((s) => s['_id']?.toString()).whereType<String>().toSet();
    _cachedVisibleSpaceIds = ids;
    _cachedVisibleSpaceIdsAt = now;
    return ids;
  } catch (_) {
    // Best-effort, same reasoning as fetchNotificationSchedule's own
    // catch: falls back to whatever was last cached (or, on a totally
    // fresh app instance with no cache yet, an empty set) rather than
    // throwing and taking the whole notification-check tick down with
    // it. An empty set under-notifies (no team task ever fires) rather
    // than over-notifies, which is the safer failure direction for
    // something gating what's allowed to reach the person at all.
    return _cachedVisibleSpaceIds ?? <String>{};
  }
}

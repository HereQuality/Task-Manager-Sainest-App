import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_client.dart';

/// Spaces the current user belongs to -- GET /api/v1/spaces (same
/// endpoint the web app's sidebar/Spaces page uses). Powers the Space
/// picker in the "Add task" sheet.
///
/// Deliberately NOT .autoDispose, unlike most FutureProviders in this app
/// (see CLAUDE.md's State management section) -- the "+" tab that opens
/// Add Task is reachable from every screen in home_shell.dart, not just
/// tasks_screen.dart, so an autoDispose version would tear down and
/// re-fetch from scratch every single time someone opens Add Task.
/// Warmed by home_shell.dart's initState the moment the app opens
/// (`ref.read`, not `.watch` -- this just needs to START the fetch, not
/// rebuild the shell on every data change), so it's already sitting
/// ready regardless of which tab Add Task gets opened from, not only
/// after the Tasks tab happens to have been visited first (that tab's
/// own `ref.watch(spacesProvider)` now just keeps it watched while
/// mounted, same as before, rather than being what starts it). Safe to
/// keep alive for the whole session because auth_provider.dart's
/// logout()/_onSessionExpired both explicitly invalidate it, so a
/// different account logging in next never inherits a previous
/// account's cached list.
final spacesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return withTransientRetry(() async {
    final res = await ApiClient.instance.dio.get('/spaces');
    final data = res.data['data'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  });
});

// Which Space a given employee belongs to is the same fact no matter
// which account is asking -- unlike task_update_tracker.dart's
// scopedKey() keys, these two caches are deliberately NOT per-account,
// just per-employeeId.
const _employeeSpaceCachePrefix = 'employee_space_cache_';
const _employeeSpacesAllCachePrefix = 'employee_spaces_all_cache_';

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
///
/// Every successful lookup is also mirrored into SharedPreferences, and a
/// failed one (no connection) falls back to whatever was last cached for
/// this exact employeeId -- without this, picking an assignee while
/// offline always left the Space field unset, even for someone this
/// device had already looked up (and cached) minutes earlier, since this
/// is a plain network call with nothing else backing it.
Future<Map<String, dynamic>?> fetchEmployeeSpace(String employeeId) async {
  final prefs = await SharedPreferences.getInstance();
  final cacheKey = '$_employeeSpaceCachePrefix$employeeId';
  try {
    final res = await ApiClient.instance.dio.get('/spaces/for-employee/$employeeId');
    final data = res.data['data'];
    final space = data is Map ? Map<String, dynamic>.from(data) : null;
    if (space != null) {
      await prefs.setString(cacheKey, jsonEncode(space));
    }
    return space;
  } catch (_) {
    final cached = prefs.getString(cacheKey);
    return cached == null ? null : Map<String, dynamic>.from(jsonDecode(cached) as Map);
  }
}

/// EVERY (active) Space a given employee belongs to -- GET /api/v1/spaces/
/// for-employee/:employeeId/all. Someone can be a member of more than one
/// Team; fetchEmployeeSpace above only ever returns one of them (whichever
/// the server happens to return first), which is fine for the single-
/// assignee Add Task flow but not for the multi-assignee one, where a
/// person selected with two Teams needs to produce two separate tasks --
/// one per Team -- not a guess at just one. See add_task_sheet.dart's
/// showAddTaskSheet for where this drives that expansion, and
/// task.controller.js#updateTask's targetSpaceId param for how a specific
/// one of these is then actually used when creating each copy.
///
/// Cached/falls back offline exactly like fetchEmployeeSpace above, same
/// reasoning -- this also feeds showAddTaskSheet's own per-target Space
/// expansion, not just the on-screen "who's going to which Team" preview.
Future<List<Map<String, dynamic>>> fetchAllEmployeeSpaces(String employeeId) async {
  final prefs = await SharedPreferences.getInstance();
  final cacheKey = '$_employeeSpacesAllCachePrefix$employeeId';
  try {
    final res = await ApiClient.instance.dio.get('/spaces/for-employee/$employeeId/all');
    final data = res.data['data'];
    final list = data is List ? List<Map<String, dynamic>>.from(data) : <Map<String, dynamic>>[];
    await prefs.setString(cacheKey, jsonEncode(list));
    return list;
  } catch (_) {
    final cached = prefs.getString(cacheKey);
    if (cached == null) return [];
    return List<Map<String, dynamic>>.from(
        (jsonDecode(cached) as List).map((e) => Map<String, dynamic>.from(e as Map)));
  }
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

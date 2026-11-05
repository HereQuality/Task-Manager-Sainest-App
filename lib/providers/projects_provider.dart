import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

/// Every active Project in the company -- GET /api/v1/projects (see
/// listProjects in project.controller.js, which returns every Project
/// with no isActive/team filtering server-side, same as the web app's
/// own useProjects() hook). Filtered to isActive here, client-side, same
/// as SpaceDetail.jsx does before handing its own Project dropdown a
/// list -- an inactive Project shouldn't be pickable for a NEW task
/// (though an existing task keeps whatever it was already set to,
/// unaffected by this list). Not scoped to a Space/Team, same reasoning
/// assignableEmployeesProvider already documents for "Assign to": the
/// Add Task sheet's Project dropdown is meant to offer every active
/// Project, not just ones belonging to whichever Space is picked.
///
/// Deliberately NOT .autoDispose -- see spacesProvider's identical doc
/// comment in spaces_provider.dart for why. Warmed by home_shell.dart's
/// initState (right when the app opens, same as Spaces/Employees) so
/// it's already sitting ready by the time Add Task opens, instead of
/// starting a fresh fetch from scratch every time -- .autoDispose tore
/// this down the instant Add Task closed, right when the sheet builds.
/// Invalidated on logout/session expiry in auth_provider.dart, same as
/// the other two.
const _projectsCacheKey = 'projects_cache';

final projectsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return cachedListFetch(_projectsCacheKey, null, () {
    return withTransientRetry(() async {
      final res = await ApiClient.instance.dio.get('/projects');
      final data = res.data['data'] ?? [];
      final projects = List<Map<String, dynamic>>.from(data);
      final active = projects.where((p) => p['isActive'] != false).toList();
      active.sort((a, b) => (a['projectName'] ?? '').toString().compareTo((b['projectName'] ?? '').toString()));
      return active;
    });
  });
});

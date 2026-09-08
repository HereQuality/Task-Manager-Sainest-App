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
final projectsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ApiClient.instance.dio.get('/projects');
  final data = res.data['data'] ?? [];
  final projects = List<Map<String, dynamic>>.from(data);
  final active = projects.where((p) => p['isActive'] != false).toList();
  active.sort((a, b) => (a['projectName'] ?? '').toString().compareTo((b['projectName'] ?? '').toString()));
  return active;
});

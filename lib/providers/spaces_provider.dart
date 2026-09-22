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

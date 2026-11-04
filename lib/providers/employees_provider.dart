import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

/// Every active employee in the company -- GET
/// /api/v1/employees/assignable/list (see listAssignableEmployees in
/// employee.controller.js). Deliberately not scoped to a Space's
/// members or gated by any menu permission: the "Assign to" picker on
/// the Add Task sheet is meant to offer literally everyone, same as the
/// Excel import template's Assign To column.
///
/// Deliberately NOT .autoDispose -- see spacesProvider's identical doc
/// comment in spaces_provider.dart for why (warmed by tasks_screen.dart,
/// consumed by Add Task from any tab, invalidated on logout/session
/// expiry in auth_provider.dart).
final assignableEmployeesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ApiClient.instance.dio.get('/employees/assignable/list');
  final data = res.data['data'] ?? [];
  return List<Map<String, dynamic>>.from(data);
});

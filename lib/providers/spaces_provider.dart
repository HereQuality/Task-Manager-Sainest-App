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

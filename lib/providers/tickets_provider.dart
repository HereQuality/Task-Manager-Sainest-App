import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

final ticketsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ApiClient.instance.dio.get('/tickets');
  final data = res.data['data'] ?? res.data['tickets'] ?? [];
  return List<Map<String, dynamic>>.from(data);
});

Future<void> createTicket({required String title, required String description}) async {
  await ApiClient.instance.dio.post('/tickets', data: {
    'title': title,
    'description': description,
  });
}

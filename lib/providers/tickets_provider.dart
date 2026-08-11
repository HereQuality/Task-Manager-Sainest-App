import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

const kTicketPlatforms = ['Web', 'App'];
const kTicketPriorities = ['Urgent', 'High', 'Normal', 'Low'];
const kTicketStatuses = ['Pending', 'In Progress', 'Confirmation', 'Closed'];

/// Every ticket visible to the logged-in person -- GET /api/v1/tickets
/// (same endpoint Support.jsx uses). The server itself decides the scope
/// (own tickets only, every read/write role's tickets, or just the ones
/// escalated to Admin for a SuperAdmin -- see getAllTickets in
/// ticket.controller.js), so a ticket showing up here that this person
/// didn't raise themselves is the client-side signal that they hold the
/// Support desk's Full Access role -- see _isOwner in tickets_screen.dart.
final ticketsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  try {
    final res = await ApiClient.instance.dio.get('/tickets');
    final data = res.data['data'] ?? res.data['tickets'] ?? [];
    return List<Map<String, dynamic>>.from(data);
  } on DioException catch (e) {
    // 403 -- this account isn't authorized to list tickets (role/permission
    // gate on the backend, not "no tickets exist"). Treated the same as
    // empty rather than surfacing a raw permissions error, since there's
    // nothing actionable for the person to do about it from here.
    if (e.response?.statusCode == 403) return [];
    rethrow;
  }
});

/// A single ticket, full detail (including its comment thread) -- GET
/// /api/v1/tickets/:id (same endpoint TicketDetailModal uses on the web).
final ticketDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  final res = await ApiClient.instance.dio.get('/tickets/$id');
  return Map<String, dynamic>.from(res.data['data'] ?? {});
});

/// POST /api/v1/tickets -- matches NewTicketModal on the web: subject,
/// platform, priority, and description are all required by the server
/// (see createTicket in ticket.controller.js); screenshot is optional and,
/// when present, forces the whole request into multipart form-data since
/// that's what multer's uploadTicketScreenshot.single("screenshot") expects.
Future<void> createTicket({
  required String subject,
  required String platform,
  required String priority,
  required String description,
  String? screenshotPath,
}) async {
  if (screenshotPath != null) {
    final formData = FormData.fromMap({
      'subject': subject,
      'platform': platform,
      'priority': priority,
      'description': description,
      'screenshot': await MultipartFile.fromFile(screenshotPath),
    });
    // ApiClient's Dio instance carries a blanket 'Content-Type:
    // application/json' header (see api_client.dart) for every other
    // endpoint in the app, which all send plain JSON bodies. Dio treats
    // an explicit Content-Type header as authoritative and won't
    // override it for FormData, so without forcing multipart/form-data
    // here, this request would go out with a JSON content-type but a
    // multipart body -- multer never sees a boundary, silently drops
    // every field (including the required subject/platform/priority),
    // and the server 400s.
    await ApiClient.instance.dio.post(
      '/tickets',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
  } else {
    await ApiClient.instance.dio.post('/tickets', data: {
      'subject': subject,
      'platform': platform,
      'priority': priority,
      'description': description,
    });
  }
}

/// PUT /api/v1/tickets/:id/status -- Support-desk/SuperAdmin only; the
/// server 403s anyone else (see updateTicketStatus in ticket.controller.js).
Future<void> updateTicketStatus(String id, String status) async {
  await ApiClient.instance.dio.put('/tickets/$id/status', data: {'status': status});
}

/// POST /api/v1/tickets/:id/comments -- open to the raiser and to anyone
/// with the Support desk's Full Access role.
Future<void> addTicketComment(String id, String message) async {
  await ApiClient.instance.dio.post('/tickets/$id/comments', data: {'message': message});
}

/// POST /api/v1/tickets/:id/ask-confirmation -- Support desk marks the
/// ticket resolved and waits for the raiser to accept or reopen it.
Future<void> askTicketConfirmation(String id) async {
  await ApiClient.instance.dio.post('/tickets/$id/ask-confirmation');
}

/// POST /api/v1/tickets/:id/forward-to-admin -- escalates a ticket to
/// SuperAdmin; only the Support desk (not the raiser) can call this.
Future<void> forwardTicketToAdmin(String id) async {
  await ApiClient.instance.dio.post('/tickets/$id/forward-to-admin');
}

/// POST /api/v1/tickets/:id/confirm -- only the raiser, and only while the
/// ticket is in "Confirmation" status. accepted=true closes it, false
/// reopens it as "In Progress".
Future<void> confirmTicketResolution(String id, bool accepted) async {
  await ApiClient.instance.dio.post('/tickets/$id/confirm', data: {'accepted': accepted});
}

/// DELETE /api/v1/tickets/:id -- server enforces who's allowed (owner on a
/// still-Pending ticket, or Support desk/SuperAdmin otherwise).
Future<void> deleteTicket(String id) async {
  await ApiClient.instance.dio.delete('/tickets/$id');
}

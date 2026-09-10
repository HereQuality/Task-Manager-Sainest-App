enum NotificationKind { taskDueSoon, taskOverdue, ticketUpdate }

class AppNotification {
  final String id;
  final NotificationKind kind;
  final String title;
  final String body;
  final DateTime timestamp;
  final bool read;
  final String? spaceName;
  // The actual Task or Ticket _id this notification is about -- `id`
  // above is a synthetic, prefixed key ('overdue_<taskId>', 'ticket_
  // <ticketId>', ...) only meant to be unique within this feed/read-state
  // tracking, never a real document id on its own. Lets the Notifications
  // screen navigate straight to the task/ticket a tap was about instead of
  // just opening the app to wherever it normally lands.
  final String refId;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.timestamp,
    required this.refId,
    this.read = false,
    this.spaceName,
  });

  AppNotification markRead() => AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        timestamp: timestamp,
        refId: refId,
        read: true,
        spaceName: spaceName,
      );
}

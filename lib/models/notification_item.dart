enum NotificationKind { taskDueSoon, taskOverdue, ticketUpdate }

class AppNotification {
  final String id;
  final NotificationKind kind;
  final String title;
  final String body;
  final DateTime timestamp;
  final bool read;
  final String? spaceName;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.timestamp,
    this.read = false,
    this.spaceName,
  });

  AppNotification markRead() => AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        timestamp: timestamp,
        read: true,
        spaceName: spaceName,
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../models/notification_item.dart';
import '../providers/notifications_provider.dart';
import '../widgets/empty_state.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  IconData _iconFor(NotificationKind kind) {
    switch (kind) {
      case NotificationKind.taskOverdue:
        return Icons.error_outline_rounded;
      case NotificationKind.taskDueSoon:
        return Icons.schedule_rounded;
      case NotificationKind.ticketUpdate:
        return Icons.confirmation_number_outlined;
    }
  }

  Color _colorFor(NotificationKind kind) {
    switch (kind) {
      case NotificationKind.taskOverdue:
        return AppColors.danger;
      case NotificationKind.taskDueSoon:
        return AppColors.warning;
      case NotificationKind.ticketUpdate:
        return AppColors.indigo;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(notificationsFeedProvider);

    // Opening this screen is the only real "seen" signal the app has --
    // swiping the OS notification away in the tray isn't observable here
    // (see markNotificationsSeen). Scheduled after the frame so it never
    // triggers a provider update mid-build; refreshes the Home bell's
    // badge right after so it reflects it immediately.
    feedAsync.whenData((items) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await markNotificationsSeen(items);
        ref.invalidate(unreadNotificationCountProvider);
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Notification settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.push('/home/settings'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(notificationsFeedProvider),
        child: feedAsync.when(
          data: (items) {
            if (items.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 60),
                EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: "You're all caught up",
                  message: 'Nothing due soon and no recent ticket updates.',
                ),
              ]);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(Gap.lg),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
              itemBuilder: (context, i) {
                final n = items[i];
                final color = _colorFor(n.kind);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                          child: Icon(_iconFor(n.kind), color: color, size: 18),
                        ),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(n.title, style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(
                                n.spaceName != null ? '${n.body} · ${n.spaceName}' : n.body,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(message: '$e', onRetry: () => ref.invalidate(notificationsFeedProvider)),
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../models/notification_item.dart';
import '../providers/notifications_provider.dart';
import '../widgets/empty_state.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  IconData _iconFor(NotificationKind kind) {
    switch (kind) {
      case NotificationKind.taskOverdue:
        return Icons.error_outline_rounded;
      case NotificationKind.taskDueSoon:
        return Icons.schedule_rounded;
      case NotificationKind.ticketUpdate:
        return Icons.confirmation_number_outlined;
      case NotificationKind.taskAssigned:
        return Icons.assignment_outlined;
      case NotificationKind.teamOverdue:
        return Icons.groups_outlined;
      case NotificationKind.approvalNeeded:
        return Icons.task_alt_outlined;
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
      case NotificationKind.taskAssigned:
        return AppColors.success;
      case NotificationKind.teamOverdue:
        return AppColors.danger;
      case NotificationKind.approvalNeeded:
        return AppColors.warning;
    }
  }

  String _messageFor(Object e) {
    if (e is SocketException) return "No internet connection. Check your network and try again.";
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return "This is taking too long -- your connection may be slow. Try again.";
        case DioExceptionType.connectionError:
          return "No internet connection. Check your network and try again.";
        case DioExceptionType.badResponse:
          return "The server had a problem loading this. Try again in a moment.";
        default:
          break;
      }
    }
    return 'Something went wrong loading notifications.';
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(notificationsFeedProvider);

    // Opening this screen is the only real "seen" signal the app has --
    // swiping the OS notification away in the tray isn't observable here
    // (see markNotificationsSeen). Scheduled after the frame so it never
    // triggers a provider update mid-build; refreshes the Home bell's
    // badge right after so it reflects it immediately.
    //
    // Guarded with `mounted` before both the network call and the
    // ref.invalidate after it -- unlike a plain ConsumerWidget (which this
    // used to be, with no `mounted` to check at all), a person backing out
    // of Notifications quickly can let markNotificationsSeen's await
    // resolve after this screen is already disposed, and touching `ref`
    // past that point throws.
    feedAsync.whenData((items) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await markNotificationsSeen(items);
        if (!mounted) return;
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
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    // A ticket update opens the ticket, everything else
                    // (overdue/due-soon) opens the task itself -- same
                    // destination a tap on the matching push notification
                    // already lands on (see notification_service.dart's
                    // showTaskUpdateNotification/pendingTaskOpenNotifier),
                    // this just wires up the in-app feed the same way.
                    onTap: () => context.push(
                      n.kind == NotificationKind.ticketUpdate ? '/home/tickets/${n.refId}' : '/home/tasks/${n.refId}',
                    ),
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
                          const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkMuted),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          // Was `message: '$e'` -- dumped the raw DioException (status code,
          // MDN link, "verify and fix your request code" boilerplate and
          // all) straight onto the screen. Matches the friendly-message
          // pattern every other screen's ErrorState already uses. Still a
          // single generic line per exception TYPE rather than the raw
          // exception, but now distinguishes "no connection" / "took too
          // long" / "server error" instead of showing the exact same
          // message for all three -- those have different, actionable
          // next steps for the person reading it.
          error: (e, _) => ErrorState(
            message: _messageFor(e),
            onRetry: () => ref.invalidate(notificationsFeedProvider),
          ),
        ),
      ),
    );
  }
}

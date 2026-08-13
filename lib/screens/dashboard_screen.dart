import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/tasks_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final statsAsync = ref.watch(dashboardStatsProvider);
    final tasksAsync = ref.watch(myTasksProvider);
    final unread = ref.watch(unreadNotificationCountProvider).maybeWhen(data: (n) => n, orElse: () => 0);

    return Scaffold(
      appBar: AppBar(
        title: Text('${_greeting()}${user != null ? ", ${user.name.split(' ').first}" : ''}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.md),
            child: _NotificationBell(count: unread),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardStatsProvider);
          ref.invalidate(myTasksProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
          children: [
            if (user?.roleName != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: Gap.lg),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.indigoSoft,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    user!.roleName!,
                    style: const TextStyle(color: AppColors.indigo, fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                ),
              ),
            statsAsync.when(
              data: (stats) {
                final totalTask = (stats['totalTask'] as num?)?.toDouble() ?? 0;
                final onTimeCompletion = (stats['onTimeCompletion'] as num?)?.toDouble() ?? 0;
                final overdue = (stats['overdue'] as num?) ?? 0;
                final inProgress = (stats['inProgress'] as num?) ?? 0;
                final delayed = (stats['delayed'] as num?) ?? 0;
                final atsScore = (stats['atsScore'] as num?)?.toDouble() ?? 0;
                final otcPct = totalTask > 0 ? (onTimeCompletion / totalTask) * 100 : 0;

                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: Gap.md,
                  crossAxisSpacing: Gap.md,
                  childAspectRatio: 1.5,
                  children: [
                    _StatCard(label: 'Total tasks', value: '${totalTask.toInt()}', color: AppColors.indigo, icon: Icons.stacked_bar_chart_rounded),
                    _StatCard(label: 'On time completion', value: '${onTimeCompletion.toInt()}', color: AppColors.success, icon: Icons.check_circle_outline_rounded),
                    _StatCard(label: 'Overdue', value: '$overdue', color: AppColors.danger, icon: Icons.error_outline_rounded),
                    _StatCard(label: 'In progress', value: '$inProgress', color: AppColors.warning, icon: Icons.timelapse_rounded),
                    _StatCard(label: 'Delayed', value: '$delayed', color: AppColors.warning, icon: Icons.hourglass_bottom_rounded),
                    _StatCard(label: 'ATS Score', value: '${atsScore.toStringAsFixed(1)}%', color: AppColors.indigo, icon: Icons.speed_rounded),
                    _StatCard(label: 'OTC', value: '${otcPct.toStringAsFixed(1)}%', color: AppColors.success, icon: Icons.check_circle_outline_rounded),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                child: Text('Stats unavailable right now.', style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
            const SizedBox(height: Gap.xl),
            Text('Due soon', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            tasksAsync.when(
              data: (tasks) {
                final upcoming = tasks.where((t) {
                  final due = t['dueDate'];
                  if (due == null) return false;
                  final d = DateTime.tryParse(due.toString());
                  if (d == null) return false;
                  final status = (t['status'] ?? '').toString().toLowerCase();
                  return !status.contains('complete') && d.difference(DateTime.now()).inDays <= 3;
                }).toList()
                  ..sort((a, b) => DateTime.parse(a['dueDate']).compareTo(DateTime.parse(b['dueDate'])));

                if (upcoming.isEmpty) {
                  return const EmptyState(
                    icon: Icons.beach_access_outlined,
                    title: 'Nothing due soon',
                    message: "You're clear for the next few days.",
                  );
                }
                return Column(
                  children: upcoming.take(5).map((t) {
                    final spaceName = t['spaceName']?.toString();
                    final dueText = 'Due ${t['dueDate'].toString().split('T').first}';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: EntityCard(
                        title: t['title'] ?? t['name'] ?? 'Untitled task',
                        status: t['status'] ?? 'pending',
                        leadingIcon: Icons.task_alt_rounded,
                        subtitle: spaceName != null && spaceName.isNotEmpty ? '$dueText · $spaceName' : dueText,
                        onTap: () => context.push('/home/tasks/${t['_id']}'),
                      ),
                    );
                  }).toList(),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Could not load tasks.', style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  const _StatCard({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, color: color, size: 17),
            ),
            // This card's height is fixed by the parent GridView's
            // childAspectRatio, not sized to content -- maxLines/ellipsis
            // alone still overflows if the icon+value+label together are
            // just taller than that fixed height on a given screen size or
            // system font-scale setting (seen on an iPhone 13 running iOS
            // 18, not just accessibility settings). Expanded+FittedBox
            // gives each text its bounded share of the remaining height
            // and shrinks it to fit instead, which can't overflow on any
            // device regardless of exact metrics.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 2,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationBell extends StatelessWidget {
  final int count;
  const _NotificationBell({required this.count});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => context.push('/home/notifications'),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.notifications_none_rounded, color: AppColors.ink),
            if (count > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                  child: Text(
                    count > 9 ? '9+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

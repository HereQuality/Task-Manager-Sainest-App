import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/tasks_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/task_meta_chips.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  // Jumps to the Tasks tab pre-filtered to match whichever stat card was
  // tapped -- see pendingTaskStatusFilter/pendingHomeTabIndex's own doc
  // comments in tasks_provider.dart for how TasksScreen/HomeShell pick
  // these up. [statuses] uses the same keys as _statusFacetOptions in
  // tasks_screen.dart (TO DO/IN PROGRESS/OVERDUE/COMPLETE/COMPLETE_LATE);
  // an empty set clears every status filter, for the Total tasks card.
  void _openTasksFiltered(Set<String> statuses) {
    pendingTaskStatusFilter.value = statuses;
    pendingHomeTabIndex.value =
        1; // Tasks is nav-slot/page index 1 -- see home_shell.dart
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final statsAsync = ref.watch(dashboardStatsProvider);
    final tasksAsync = ref.watch(myTasksProvider);
    final delayByPersonAsync = ref.watch(averageDelayDaysByPersonProvider);
    final unread = ref
        .watch(unreadNotificationCountProvider)
        .maybeWhen(data: (n) => n, orElse: () => 0);
    // Badge count for the new Approvals card below -- everything currently
    // needing a look either direction: requests waiting on THIS person to
    // approve (completion + lock-override requests combined, same merge
    // PendingApprovalsScreen itself does) plus this person's own submitted
    // completions still waiting on someone else.
    final int pendingCount = ref.watch(pendingApprovalsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0) +
        ref.watch(lockOverrideRequestsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0);
    final int awaitingCount = ref.watch(mySubmittedApprovalsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0);
    final int approvalsCount = pendingCount + awaitingCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${_greeting()}${user != null ? ", ${user.name.split(' ').first}" : ''}'),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: Gap.md, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.indigoSoft,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    user!.roleName!,
                    style: const TextStyle(
                        color: AppColors.indigo,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5),
                  ),
                ),
              ),
            statsAsync.when(
              data: (stats) {
                final totalTask = (stats['totalTask'] as num?)?.toDouble() ?? 0;
                final onTimeCompletion =
                    (stats['onTimeCompletion'] as num?)?.toDouble() ?? 0;
                final overdue = (stats['overdue'] as num?) ?? 0;
                final inProgress = (stats['inProgress'] as num?) ?? 0;
                final delayed = (stats['delayed'] as num?) ?? 0;
                final atsScore = (stats['atsScore'] as num?)?.toDouble() ?? 0;
                // On-time completions vs delayed completions only --
                // deliberately excludes both In Progress (not yet judged,
                // same reasoning as ATS) AND Overdue: an overdue task hasn't
                // been completed at all yet, so counting it against this
                // percentage penalizes it twice over once it eventually IS
                // completed (late, into the "delayed" bucket) -- once while
                // still overdue, and again once it lands in delayed. This
                // is meant to answer "of the tasks people actually
                // finished, how many finished on time", not "how many of
                // everything ever assigned is currently on time".
                final onTimeJudgedTotal = onTimeCompletion + delayed;
                final otcPct = onTimeJudgedTotal > 0
                    ? (onTimeCompletion / onTimeJudgedTotal) * 100
                    : 0;
                // Just this person's own average overdue delay -- same
                // self-scoping as the card below, sourced from the same
                // per-person provider (see averageDelayDaysByPersonProvider).
                final myDelay = delayByPersonAsync.maybeWhen<Map<String, dynamic>?>(
                  data: (people) {
                    final matches = people.where((p) => p['employeeId']?.toString() == user?.id);
                    return matches.isEmpty ? null : matches.first;
                  },
                  orElse: () => null,
                );
                final myAvgOverdueDelay = ((myDelay?['avgDelayDays'] as num?) ?? 0).toDouble();
                // Ring fill is only meaningful on a 0-100 scale -- days late
                // isn't one, so this caps the fill at a 14-day "fully red"
                // ring purely for the visual, while the exact day count
                // still shows as the center text regardless.
                final overdueDelayRingPct = (myAvgOverdueDelay / 14 * 100).clamp(0, 100);

                return Column(
                  children: [
                    // ATS/OTC/Average Overdue Delay are the headline
                    // performance numbers, not just another count like the
                    // cards below -- a distinct "hero" ring treatment up top
                    // is what makes them read as the numbers to check first,
                    // before the raw task-count breakdown underneath.
                    // IntrinsicHeight -- required for crossAxisAlignment.stretch
                    // to work safely here. This Row sits inside a Column
                    // inside a ListView, which gives it an UNBOUNDED height
                    // constraint; stretch alone would try to stretch its
                    // children to that unbounded height, which silently
                    // breaks layout for the rest of the page (a known
                    // Flutter footgun -- release builds strip the assertion
                    // that would normally catch it in debug, so the failure
                    // just shows up as everything below this Row vanishing).
                    // IntrinsicHeight first computes a real, finite height
                    // from the children themselves, then stretch works
                    // against that instead.
                    IntrinsicHeight(
                      child: Row(
                        // Stretch -- without this, each card sizes to its own
                        // label's intrinsic height, and "ATS Score" (one
                        // line) ends up visibly shorter than the two-line
                        // labels beside it. Stretching makes all three match
                        // the tallest card's height.
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _ScoreRingCard(
                              label: 'ATS Score',
                              pct: atsScore.toDouble(),
                              color: AppColors.indigo,
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: _ScoreRingCard(
                              label: 'On-Time Completed',
                              pct: otcPct.toDouble(),
                              color: AppColors.success,
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: _ScoreRingCard(
                              label: 'Average Overdue Delay',
                              pct: overdueDelayRingPct.toDouble(),
                              color: AppColors.danger,
                              centerText: myAvgOverdueDelay > 0 ? '${myAvgOverdueDelay.toStringAsFixed(1)}d' : '—',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.md),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 3,
                      mainAxisSpacing: Gap.sm,
                      crossAxisSpacing: Gap.sm,
                      childAspectRatio: 1.15,
                      children: [
                        _StatCard(
                          label: 'Total tasks',
                          value: '${totalTask.toInt()}',
                          color: AppColors.indigo,
                          icon: Icons.stacked_bar_chart_rounded,
                          onTap: () => _openTasksFiltered(const {}),
                        ),
                        _StatCard(
                          label: 'On time completed',
                          value: '${onTimeCompletion.toInt()}',
                          color: AppColors.success,
                          icon: Icons.check_circle_outline_rounded,
                          onTap: () => _openTasksFiltered(const {'COMPLETE'}),
                        ),
                        _StatCard(
                          label: 'Overdue',
                          value: '$overdue',
                          color: AppColors.danger,
                          icon: Icons.error_outline_rounded,
                          onTap: () => _openTasksFiltered(const {'OVERDUE'}),
                        ),
                        _StatCard(
                          label: 'In progress',
                          value: '$inProgress',
                          color: AppColors.warning,
                          icon: Icons.timelapse_rounded,
                          onTap: () => _openTasksFiltered(const {'IN PROGRESS'}),
                        ),
                        _StatCard(
                          label: 'Delayed',
                          value: '$delayed',
                          color: AppColors.warning,
                          icon: Icons.hourglass_bottom_rounded,
                          onTap: () => _openTasksFiltered(const {'COMPLETE_LATE'}),
                        ),
                        _StatCard(
                          label: 'Approvals',
                          value: '$approvalsCount',
                          color: AppColors.indigo,
                          icon: Icons.pending_actions_rounded,
                          onTap: () => context.push('/home/approvals'),
                        ),
                      ],
                    ),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                child: Text('Stats unavailable right now.',
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
            const SizedBox(height: Gap.md),
            delayByPersonAsync.when(
              // Just this person's own row -- not the whole team's, see
              // approvals-style per-person breakdown for that (this screen
              // used to list everyone; kept small and self-scoped now so it
              // doesn't push "Today's tasks" further down the page).
              data: (people) {
                final mine = people.where((p) => p['employeeId']?.toString() == user?.id).toList();
                if (mine.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: _MyDelayCard(person: mine.first),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (e, _) => const SizedBox.shrink(),
            ),
            Text("Today's tasks",
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            tasksAsync.when(
              data: (tasks) {
                final now = DateTime.now();
                // myTasksProvider ("/tasks/mine/all") mixes a manager/
                // senior's own tasks together with every subordinate's
                // (see listMyTasksAll in task.controller.js) -- this
                // section is scoped to just the logged-in person's own
                // work, same "Mine" default the Tasks screen itself now
                // uses, so the assignee check below is what actually
                // narrows it rather than relying on the endpoint alone.
                final today = tasks.where((t) {
                  final assigneeRaw = t['assigneeId'];
                  final assigneeId =
                      (assigneeRaw is Map ? assigneeRaw['_id'] : assigneeRaw)
                          ?.toString();
                  if (assigneeId == null || assigneeId != user?.id)
                    return false;
                  final due = t['dueDate'];
                  if (due == null) return false;
                  final d = DateTime.tryParse(due.toString());
                  if (d == null) return false;
                  final status = (t['status'] ?? '').toString().toLowerCase();
                  if (status.contains('complete')) return false;
                  return d.year == now.year &&
                      d.month == now.month &&
                      d.day == now.day;
                }).toList()
                  ..sort((a, b) => DateTime.parse(a['dueDate'])
                      .compareTo(DateTime.parse(b['dueDate'])));

                if (today.isEmpty) {
                  return const EmptyState(
                    icon: Icons.beach_access_outlined,
                    title: 'Nothing due today',
                    message: "You're clear for today.",
                  );
                }
                return Column(
                  children: today.map((t) {
                    final spaceName = t['spaceName']?.toString();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: EntityCard(
                        title: t['title'] ?? t['name'] ?? 'Untitled task',
                        status: t['status'] ?? 'pending',
                        leadingIcon: Icons.task_alt_rounded,
                        subtitle: spaceName != null && spaceName.isNotEmpty
                            ? spaceName
                            : null,
                        // Same chip set every other task row in the app
                        // uses (see task_meta_chips.dart) -- due date,
                        // priority, assigned by/to.
                        metaRow: taskMetaRow(t, currentUserId: user?.id),
                        onTap: () => context.push('/home/tasks/${t['_id']}'),
                      ),
                    );
                  }).toList(),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Could not load tasks.',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact single-line card showing just the logged-in person's own average
/// COMPLETED delay, in days -- across their own tasks that were actually
/// finished late, not still-open overdue ones (see the ring above for
/// that). Server-computed, see getAverageDelayDaysByPerson's
/// avgCompletedDelayDays in task.controller.js -- same task-weighted
/// averaging the web Dashboard's own "Average Completed Delay Days" card
/// uses. Deliberately small -- one row, not a list -- so it doesn't push
/// "Today's tasks" further down the Home screen.
class _MyDelayCard extends StatelessWidget {
  final Map<String, dynamic> person;
  const _MyDelayCard({required this.person});

  @override
  Widget build(BuildContext context) {
    final delayedCount = ((person['delayedCount'] as num?) ?? 0).toInt();
    if (delayedCount == 0) return const SizedBox.shrink();
    final avgCompletedDelayDays = ((person['avgCompletedDelayDays'] as num?) ?? 0).toDouble();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.hourglass_bottom_rounded, color: AppColors.warning, size: 16),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                'Avg. completed delay: $delayedCount task${delayedCount == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Text(
              '${avgCompletedDelayDays.toStringAsFixed(1)}d',
              style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w800, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// Headline performance card for ATS/OTC -- a circular progress ring with
/// the percentage inside, instead of the plain icon+value+label tile the
/// other stats below use. Deliberately a different shape (not just a
/// different color) so these two read as "the numbers that matter most"
/// at a glance, ahead of the raw task-count breakdown underneath.
class _ScoreRingCard extends StatelessWidget {
  final String label;
  final double pct;
  final Color color;
  // Overrides the "N%" text drawn in the ring's center -- used by the
  // Average Overdue Delay ring (days, not a percentage) alongside ATS/OTC.
  // [pct] still drives how much of the ring fills in, so callers that pass
  // it must pre-scale a non-percentage value onto a 0-100 range themselves.
  final String? centerText;
  const _ScoreRingCard({required this.label, required this.pct, required this.color, this.centerText});

  @override
  Widget build(BuildContext context) {
    final clamped = pct.clamp(0, 100) / 100;
    // Shrunk from 76 -- three of these now sit side by side (ATS / OTC /
    // Average Overdue Delay) instead of the original two, so each needs to
    // give up some width to fit a phone screen without wrapping.
    const size = 64.0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: size,
                    height: size,
                    child: CircularProgressIndicator(
                      value: 1,
                      strokeWidth: 6,
                      color: color.withValues(alpha: 0.12),
                    ),
                  ),
                  SizedBox(
                    width: size,
                    height: size,
                    child: CircularProgressIndicator(
                      value: clamped.toDouble(),
                      strokeWidth: 6,
                      color: color,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      centerText ?? '${pct.toStringAsFixed(0)}%',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
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
  final VoidCallback? onTap;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, color: color, size: 14),
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
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: const BoxDecoration(
                      color: AppColors.danger, shape: BoxShape.circle),
                  child: Text(
                    count > 9 ? '9+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

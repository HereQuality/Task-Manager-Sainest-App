import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';

/// Reached from the Home screen's "Approvals" card -- a simple chooser
/// between this app's two existing, separately-routed approval screens
/// (both already reachable from the Profile menu, see profile_screen.dart)
/// rather than a third screen re-implementing either one:
///   - Pending Approval: requests waiting on THIS person to approve (a
///     delegate's completion request, or an edit/delete lock-override
///     request) -- PendingApprovalsScreen, /home/pending-approvals.
///   - Awaiting Approval: this person's OWN submitted completion requests
///     still waiting on someone else -- AwaitingApprovalScreen,
///     /home/awaiting-approval.
class ApprovalsHubScreen extends ConsumerWidget {
  const ApprovalsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same two-list merge PendingApprovalsScreen itself does for its own
    // count -- shown here as a preview badge so picking between the two
    // options doesn't require opening each one first to see which has
    // something waiting.
    final int pendingCount = ref.watch(pendingApprovalsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0) +
        ref.watch(lockOverrideRequestsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0);
    final int awaitingCount = ref.watch(mySubmittedApprovalsProvider).maybeWhen<int>(data: (l) => l.length, orElse: () => 0);

    return Scaffold(
      appBar: AppBar(title: const Text('Approvals')),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(
            'Choose which side of the approval flow you want to see.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: Gap.lg),
          _ApprovalChoiceCard(
            icon: Icons.fact_check_outlined,
            iconColor: AppColors.indigo,
            iconBg: AppColors.indigoSoft,
            title: 'Pending Approval',
            subtitle: 'Requests waiting on you to approve or reject',
            count: pendingCount,
            onTap: () => context.push('/home/pending-approvals'),
          ),
          const SizedBox(height: Gap.md),
          _ApprovalChoiceCard(
            icon: Icons.hourglass_empty_rounded,
            iconColor: AppColors.warning,
            iconBg: AppColors.warningSoft,
            title: 'Awaiting Approval',
            subtitle: 'Your own requests still waiting on someone else',
            count: awaitingCount,
            onTap: () => context.push('/home/awaiting-approval'),
          ),
        ],
      ),
    );
  }
}

class _ApprovalChoiceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onTap;
  const _ApprovalChoiceCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        onTap: onTap,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: iconColor, size: 22),
        ),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (count > 0)
              Container(
                margin: const EdgeInsets.only(right: Gap.sm),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(AppRadius.chip)),
                child: Text(
                  '$count',
                  style: TextStyle(color: iconColor, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }
}

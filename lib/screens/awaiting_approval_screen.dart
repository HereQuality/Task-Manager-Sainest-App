import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../core/socket_service.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/status_pill.dart';

/// The assignee's side of the completion-approval flow -- every task this
/// person has already marked complete that's still waiting (PENDING) or
/// was sent back (REJECTED) by whoever delegated it to them. Same name
/// ("Awaiting Approval") and same underlying GET
/// /tasks/my-submitted-approvals as the web app's
/// MySubmittedApprovalsModal.jsx. Read-only -- the decision belongs to the
/// delegator (see PendingApprovalsScreen), so this is purely "here's where
/// what I finished currently stands".
class AwaitingApprovalScreen extends ConsumerStatefulWidget {
  const AwaitingApprovalScreen({super.key});

  @override
  ConsumerState<AwaitingApprovalScreen> createState() => _AwaitingApprovalScreenState();
}

class _AwaitingApprovalScreenState extends ConsumerState<AwaitingApprovalScreen> {
  @override
  void initState() {
    super.initState();
    // Same staleness fix as PendingApprovalsScreen -- see its initState's
    // doc comment.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(mySubmittedApprovalsProvider);
    });
    // Realtime: the delegator approving/rejecting shows up here the moment
    // it happens -- see PendingApprovalsScreen's own doc comment on the
    // same mechanism.
    taskRealtimeEventNotifier.addListener(_onRealtimeEvent);
  }

  void _onRealtimeEvent() {
    if (mounted) ref.invalidate(mySubmittedApprovalsProvider);
  }

  @override
  void dispose() {
    taskRealtimeEventNotifier.removeListener(_onRealtimeEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mySubmittedApprovalsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Awaiting Approval')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => ErrorState(
          message: 'Something went wrong loading this list.',
          onRetry: () => ref.invalidate(mySubmittedApprovalsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.hourglass_empty_rounded,
              title: 'Nothing waiting on anyone else',
              message: 'Tasks you delegate and mark complete for approval will show up here until the delegator decides.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(mySubmittedApprovalsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(Gap.lg),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
              itemBuilder: (context, i) => _AwaitingApprovalCard(
                task: items[i],
                onOpen: () {
                  final id = (items[i]['_id'] ?? '').toString();
                  if (id.isNotEmpty) context.push('/home/tasks/$id');
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AwaitingApprovalCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final VoidCallback onOpen;
  const _AwaitingApprovalCard({required this.task, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final name = (task['name'] ?? 'Untitled task').toString();
    final spaceName = (task['spaceName'] ?? '').toString();
    final createdBy = task['createdBy'] is Map ? task['createdBy'] as Map : null;
    final delegatorName = (createdBy?['employeeName'] ?? createdBy?['name'] ?? 'Someone').toString();
    final status = (task['status'] ?? 'PENDING').toString();
    final isRejected = status == 'REJECTED';
    final requestedAt = task['requestedAt'] != null ? DateTime.tryParse(task['requestedAt'].toString()) : null;
    final rejectionReason = (task['rejectionReason'] ?? '').toString();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(name, style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: Gap.sm),
                  StatusPill(status: isRejected ? 'REJECTED' : 'PENDING'),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  'Delegated by $delegatorName',
                  if (spaceName.isNotEmpty) spaceName,
                  if (requestedAt != null) DateFormat('dd/MM/yyyy, hh:mm a').format(requestedAt),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (isRejected && rejectionReason.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Container(
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(color: AppColors.dangerSoft, borderRadius: BorderRadius.circular(AppRadius.card)),
                  child: Text(
                    'Sent back: $rejectionReason',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.danger),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

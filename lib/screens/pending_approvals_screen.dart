import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../core/socket_service.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/status_pill.dart';

/// The delegator's side of the completion-approval flow -- every task this
/// person delegated away that its assignee has already marked complete and
/// is now sitting on this person's own approve/reject decision -- MERGED
/// with every pending 5-minute-lock override request (someone who isn't
/// Full Access asking to edit/delete a task past its normal edit window).
/// Same two lists, same merge-in-the-screen approach, and the same name
/// ("Pending Approvals") as the web app's PendingApprovalsModal.jsx
/// (usePendingApprovals) -- lockOverrideRequestsProvider was missing here
/// entirely before, which is why an edit/delete request never showed up on
/// mobile even though it was visible on the website.
///
/// Approve/reject also already works from TaskDetailScreen for the
/// completion-approval kind (tapping a row gets there too) -- the inline
/// buttons here are for the common case of deciding straight from the list
/// without opening the full task. Lock-override requests are decided from
/// here only; there's no equivalent inline control in TaskDetailScreen for
/// those today.
class PendingApprovalsScreen extends ConsumerStatefulWidget {
  const PendingApprovalsScreen({super.key});

  @override
  ConsumerState<PendingApprovalsScreen> createState() => _PendingApprovalsScreenState();
}

class _PendingApprovalsScreenState extends ConsumerState<PendingApprovalsScreen> {
  String? _busyTaskId;

  @override
  void initState() {
    super.initState();
    // pendingApprovalsProvider is watched by TasksScreen too (its DELEGATED
    // group), and HomeShell keeps that screen alive in an IndexedStack --
    // so its autoDispose fetch, done once the first time it's watched,
    // otherwise never refires and this screen would just show whatever was
    // cached from whenever TasksScreen last happened to load, not what's
    // actually pending right now. Forcing a fresh fetch every time this
    // screen opens is what makes a task delegated moments ago on the
    // website actually show up here without needing to fully close and
    // reopen the app.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.invalidate(pendingApprovalsProvider);
        ref.invalidate(lockOverrideRequestsProvider);
      }
    });
    // Realtime: a task delegated to someone else gets marked complete by
    // them (or a lock-override request gets filed/approved/rejected by
    // anyone), and this list refetches immediately -- no more waiting for
    // pull-to-refresh or a tab switch. See socket_service.dart's own doc
    // comment for why the per-user room server-side already scopes this to
    // changes this account is actually a party to.
    taskRealtimeEventNotifier.addListener(_onRealtimeEvent);
  }

  void _onRealtimeEvent() {
    if (!mounted) return;
    ref.invalidate(pendingApprovalsProvider);
    ref.invalidate(lockOverrideRequestsProvider);
  }

  @override
  void dispose() {
    taskRealtimeEventNotifier.removeListener(_onRealtimeEvent);
    super.dispose();
  }

  Future<void> _approve(Map<String, dynamic> task) async {
    final id = (task['_id'] ?? '').toString();
    if (id.isEmpty) return;
    final isLockOverride = task['kind'] == 'lockOverride';
    setState(() => _busyTaskId = id);
    try {
      if (isLockOverride) {
        await approveLockOverride(id);
        ref.invalidate(lockOverrideRequestsProvider);
      } else {
        await approveTaskCompletion(id);
        ref.invalidate(pendingApprovalsProvider);
      }
      ref.invalidate(myTasksProvider);
      ref.invalidate(dashboardStatsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isLockOverride ? 'Request approved' : 'Completion approved — task marked complete')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not approve this.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyTaskId = null);
    }
  }

  // Same reason-collection sheet as TaskDetailScreen's own _reject -- kept
  // here rather than shared since it's the only two call sites and each is
  // small on its own.
  Future<void> _reject(Map<String, dynamic> task) async {
    final id = (task['_id'] ?? '').toString();
    if (id.isEmpty) return;
    final isLockOverride = task['kind'] == 'lockOverride';
    final reasonCtrl = TextEditingController();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Gap.xl, right: Gap.xl, top: Gap.xl,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Send this back?', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(
              isLockOverride
                  ? "The task stays exactly as it is -- the request is just declined."
                  : "The task won't be marked complete -- it goes back to the assignee as-is.",
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: reasonCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: "What's missing? (optional)"),
            ),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: Text(isLockOverride ? 'Reject request' : 'Send back to assignee'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyTaskId = id);
    try {
      if (isLockOverride) {
        await rejectLockOverride(id, reason: reasonCtrl.text);
        ref.invalidate(lockOverrideRequestsProvider);
      } else {
        await rejectTaskCompletion(id, reason: reasonCtrl.text);
        ref.invalidate(pendingApprovalsProvider);
      }
      ref.invalidate(myTasksProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isLockOverride ? 'Request rejected' : 'Sent back to the assignee')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send this back.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyTaskId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final completionAsync = ref.watch(pendingApprovalsProvider);
    // Best-effort, matching listLockOverrideRequests' own server-side
    // contract (empty list rather than 403 for anyone who isn't Full
    // Access) -- a failure here shouldn't take down the primary
    // completion-approval list, so it degrades to "no lock-override items
    // shown" rather than an error state, same reasoning as myTasksProvider
    // swallowing a 403.
    final lockAsync = ref.watch(lockOverrideRequestsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pending Approvals')),
      body: completionAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => ErrorState(
          message: 'Something went wrong loading pending approvals.',
          onRetry: () => ref.invalidate(pendingApprovalsProvider),
        ),
        data: (completionItems) {
          final items = [
            for (final t in lockAsync.value ?? const <Map<String, dynamic>>[]) {...t, 'kind': 'lockOverride'},
            for (final t in completionItems) {...t, 'kind': 'completion'},
          ];
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Nothing waiting on you',
              message: "Tasks you've delegated that get marked complete, and any edit/delete requests, will show up here for your approval.",
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(pendingApprovalsProvider);
              ref.invalidate(lockOverrideRequestsProvider);
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(Gap.lg),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
              itemBuilder: (context, i) => _PendingApprovalCard(
                task: items[i],
                busy: _busyTaskId == (items[i]['_id'] ?? '').toString(),
                onApprove: () => _approve(items[i]),
                onReject: () => _reject(items[i]),
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

class _PendingApprovalCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onOpen;

  const _PendingApprovalCard({
    required this.task,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final isLockOverride = task['kind'] == 'lockOverride';
    final isDeleteRequest = isLockOverride && task['overrideType'] == 'DELETE';
    final name = (task['name'] ?? 'Untitled task').toString();
    final spaceName = (task['spaceName'] ?? '').toString();
    final assignee = task['assigneeId'] is Map ? task['assigneeId'] as Map : null;
    final assigneeName = (assignee?['employeeName'] ?? 'Someone').toString();
    final requestedByName = (task['requestedByName'] ?? 'someone').toString();
    final reason = (task['reason'] ?? '').toString();
    final requestedAt = task['requestedAt'] != null ? DateTime.tryParse(task['requestedAt'].toString()) : null;

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
                  if (isLockOverride)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        isDeleteRequest ? 'Delete request' : 'Edit request',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                      ),
                    )
                  else
                    const StatusPill(status: 'DELEGATED'),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  isLockOverride ? 'Requested by $requestedByName' : 'Marked complete by $assigneeName',
                  if (spaceName.isNotEmpty) spaceName,
                  if (requestedAt != null) DateFormat('dd/MM/yyyy, hh:mm a').format(requestedAt),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (isLockOverride && reason.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Container(
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(AppRadius.field)),
                  child: Text(
                    '"$reason"',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF92400E)),
                  ),
                ),
              ],
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : onReject,
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
                      child: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : onApprove,
                      child: busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Approve'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

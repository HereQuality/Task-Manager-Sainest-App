import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/tasks_provider.dart';
import '../widgets/status_pill.dart';
import '../widgets/empty_state.dart';

const _statuses = ['TO DO', 'IN PROGRESS', 'COMPLETE'];

/// Opened by tapping a task anywhere in the app -- the Tasks tab, Home's
/// "Due soon" list, or a day's tasks on the Calendar tab all push here
/// with the same taskId, same as clicking a task's name opens
/// TaskDetailModal.jsx on the web. Deliberately a single focused screen
/// rather than porting every tab of the web modal (subtasks, checklists,
/// attachments, dependencies, time tracking) -- the point of the mobile
/// app is fast triage: see what a task needs and move its status,
/// not full editing.
class TaskDetailScreen extends ConsumerStatefulWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  bool _updating = false;

  Future<void> _setStatus(String status) async {
    setState(() => _updating = true);
    try {
      await updateTaskStatus(widget.taskId, status);
      ref.invalidate(taskDetailProvider(widget.taskId));
      ref.invalidate(myTasksProvider);
      ref.invalidate(dashboardStatsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(status == 'COMPLETE' ? 'Task marked complete' : 'Status updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update this task.')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _approve() async {
    setState(() => _updating = true);
    try {
      await approveTaskCompletion(widget.taskId);
      ref.invalidate(taskDetailProvider(widget.taskId));
      ref.invalidate(myTasksProvider);
      ref.invalidate(pendingApprovalsProvider);
      ref.invalidate(dashboardStatsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Completion approved — task marked complete')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not approve this task.')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  // Rejecting doesn't touch task.status -- the task stays exactly where it
  // was before the assignee tried to complete it (see rejectTaskCompletion's
  // own doc comment), so from here it just goes back to sitting in whatever
  // status group it was already in, minus the DELEGATED flag. The optional
  // reason is what the assignee sees on their side to know what to fix.
  Future<void> _reject() async {
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
              "The task won't be marked complete -- it goes back to the assignee as-is.",
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
              child: const Text('Send back to assignee'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() => _updating = true);
    try {
      await rejectTaskCompletion(widget.taskId, reason: reasonCtrl.text);
      ref.invalidate(taskDetailProvider(widget.taskId));
      ref.invalidate(myTasksProvider);
      ref.invalidate(pendingApprovalsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent back to the assignee')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send this back.')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskAsync = ref.watch(taskDetailProvider(widget.taskId));
    final currentUserId = ref.watch(authProvider).user?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Task')),
      body: taskAsync.when(
        data: (t) {
          final status = (t['status'] ?? 'TO DO').toString();
          final assignee = t['assigneeId'] is Map ? t['assigneeId'] as Map : null;
          final assigneeName = assignee?['employeeName']?.toString();
          final priority = t['priority']?.toString();
          final description = (t['description'] ?? '').toString();
          final dateFmt = DateFormat('MMM d, yyyy');
          final startDate = _parseDate(t['startDate']);
          final dueDate = _parseDate(t['dueDate']);
          final spaceName = t['spaceName']?.toString();
          final folderName = t['folderName']?.toString();

          // createdBy comes back as a bare id string, not populated (see
          // getTask in task.controller.js) -- comparing it directly against
          // the logged-in person's own id is how this screen tells whether
          // THEY are the one who delegated this task away, i.e. the only
          // person the server will actually let approve/reject it.
          final completionApproval = t['completionApproval'] is Map ? t['completionApproval'] as Map : null;
          final pendingApproval = completionApproval?['status'] == 'PENDING';
          final createdById = t['createdBy']?.toString();
          final isDelegator = pendingApproval && currentUserId != null && createdById == currentUserId;

          return ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(t['name']?.toString() ?? 'Untitled task', style: Theme.of(context).textTheme.headlineSmall),
                  ),
                  const SizedBox(width: Gap.sm),
                  StatusPill(status: pendingApproval ? 'DELEGATED' : status),
                ],
              ),
              if (spaceName != null && spaceName.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  folderName != null && folderName.isNotEmpty ? '$spaceName / $folderName' : spaceName,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: Gap.xl),

              if (pendingApproval) ...[
                // The task's real status.dart is deliberately frozen while
                // this is PENDING (see Task.js's own doc comment on
                // completionApproval) -- so instead of the normal Status
                // chips/Mark complete button below (which would be
                // misleading right now), this is either something only the
                // delegator can act on, or, for anyone else looking at it
                // (the assignee, a manager just browsing), a plain heads-up
                // that a decision is pending and nothing more to do here.
                if (isDelegator) ...[
                  Container(
                    padding: const EdgeInsets.all(Gap.lg),
                    decoration: BoxDecoration(
                      color: AppColors.warningSoft,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'The assignee marked this complete',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppColors.warning),
                        ),
                        const SizedBox(height: Gap.xs),
                        Text(
                          "It won't count as done until you approve it -- or send it back if it isn't actually finished.",
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: Gap.md),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: _updating ? null : _approve,
                                child: const Text('Approve'),
                              ),
                            ),
                            const SizedBox(width: Gap.sm),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _updating ? null : _reject,
                                style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
                                child: const Text('Send back'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else
                  Container(
                    padding: const EdgeInsets.all(Gap.lg),
                    decoration: BoxDecoration(
                      color: AppColors.warningSoft,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Text(
                      "Marked complete -- waiting on the delegator's approval.",
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.warning),
                    ),
                  ),
              ] else ...[
                Text('Status', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.sm,
                  children: _statuses.map((s) {
                    final selected = s == status;
                    return ChoiceChip(
                      label: Text(s),
                      selected: selected,
                      onSelected: _updating || selected ? null : (_) => _setStatus(s),
                      selectedColor: AppColors.indigo,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : AppColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: AppColors.neutralSoft,
                    );
                  }).toList(),
                ),

                if (status != 'COMPLETE') ...[
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    onPressed: _updating ? null : () => _setStatus('COMPLETE'),
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: const Text('Mark complete'),
                  ),
                ],
              ],

              const SizedBox(height: Gap.xl),
              _DetailRow(icon: Icons.person_outline_rounded, label: 'Assigned to', value: assigneeName ?? 'Unassigned'),
              _DetailRow(
                icon: Icons.flag_outlined,
                label: 'Priority',
                value: priority ?? 'None',
              ),
              _DetailRow(
                icon: Icons.play_circle_outline_rounded,
                label: 'Start date',
                value: startDate != null ? dateFmt.format(startDate) : 'Not set',
              ),
              _DetailRow(
                icon: Icons.event_outlined,
                label: 'Due date',
                value: dueDate != null ? dateFmt.format(dueDate) : 'Not set',
              ),

              if (description.trim().isNotEmpty) ...[
                const SizedBox(height: Gap.lg),
                Text('Description', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                Text(description, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: 'Could not load this task.',
          onRetry: () => ref.invalidate(taskDetailProvider(widget.taskId)),
        ),
      ),
    );
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.inkMuted),
          const SizedBox(width: Gap.md),
          // label is a short fixed string ("Assigned to", "Priority", ...);
          // value is the actually dynamic side (an assignee's name, a
          // formatted date, ...). The outer Expanded bounds how much width
          // label+value can claim together; the inner spaceBetween keeps
          // label flush left and value flush right same as before, and
          // Flexible+ellipsis on value (not label) means IT shrinks first
          // when a long name doesn't fit, instead of overflowing.
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

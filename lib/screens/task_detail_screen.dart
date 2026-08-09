import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
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

  @override
  Widget build(BuildContext context) {
    final taskAsync = ref.watch(taskDetailProvider(widget.taskId));

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
                  StatusPill(status: status),
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
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
        ],
      ),
    );
  }
}

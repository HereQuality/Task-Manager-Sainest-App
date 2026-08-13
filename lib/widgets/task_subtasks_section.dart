import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';
import 'status_pill.dart';

/// Task detail's Subtasks panel -- each subtask is a full Task document
/// nested one level (Task.js's parentTaskId), so tapping one just opens
/// the same TaskDetailScreen recursively with the subtask's own id.
class TaskSubtasksSection extends ConsumerWidget {
  final String taskId;
  const TaskSubtasksSection({super.key, required this.taskId});

  Future<void> _addSubtask(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showModalBottomSheet<String>(
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
            Text('New subtask', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Subtask name'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: Gap.xl),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Add subtask')),
          ],
        ),
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await createSubtask(taskId, name: name.trim());
      ref.invalidate(subtasksProvider(taskId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create the subtask.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtasksAsync = ref.watch(subtasksProvider(taskId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Subtasks', style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () => _addSubtask(context, ref),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        subtasksAsync.when(
          data: (subtasks) => subtasks.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text('No subtasks yet.', style: Theme.of(context).textTheme.bodyMedium),
                )
              : Column(
                  children: subtasks.map((s) {
                    final status = (s['status'] ?? 'TO DO').toString();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.field),
                        onTap: () => context.push('/home/tasks/${s['_id']}'),
                        child: Container(
                          padding: const EdgeInsets.all(Gap.md),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(AppRadius.field),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(s['name']?.toString() ?? 'Untitled subtask', maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              const SizedBox(width: Gap.sm),
                              StatusPill(status: status),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.md),
            child: LinearProgressIndicator(),
          ),
          error: (e, _) => Text('Could not load subtasks.', style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

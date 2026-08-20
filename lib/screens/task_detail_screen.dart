import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../core/notification_service.dart';
import '../core/pending_attachment_service.dart';
import '../providers/auth_provider.dart';
import '../providers/tasks_provider.dart';
import '../widgets/status_pill.dart';
import '../widgets/empty_state.dart';
import '../widgets/task_checklist_section.dart';
import '../widgets/task_subtasks_section.dart';
import '../widgets/task_attachments_section.dart';
import '../widgets/task_comments_section.dart';
import '../widgets/edit_task_sheet.dart';

const _statuses = ['TO DO', 'IN PROGRESS', 'COMPLETE'];

/// Opened by tapping a task anywhere in the app -- the Tasks tab, Home's
/// "Due soon" list, or a day's tasks on the Calendar tab all push here
/// with the same taskId, same as clicking a task's name opens
/// TaskDetailModal.jsx on the web. Deliberately a single focused screen
/// rather than porting every tab of the web modal (subtasks, checklists,
/// attachments, dependencies, time tracking) -- the point of the mobile
/// app is fast triage: see what a task needs and move its status,
/// not full editing.
///
/// [taskIds], when the caller has one (see tasks_screen.dart's onTap),
/// is the exact ordered list of task ids currently visible on whichever
/// screen this was opened from -- lets someone swipe left/right straight
/// to the next/previous task in that same list without backing out to it
/// and tapping another row. Callers that don't have a meaningful ordered
/// list (a single task reached from a subtask row, Dashboard, or the
/// Calendar day view) just omit it, and this screen falls back to
/// [taskId] alone with no swiping.
class TaskDetailScreen extends StatefulWidget {
  final String taskId;
  final List<String>? taskIds;
  const TaskDetailScreen({super.key, required this.taskId, this.taskIds});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late final List<String> _ids;
  late int _index;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _ids = (widget.taskIds != null && widget.taskIds!.isNotEmpty) ? widget.taskIds! : [widget.taskId];
    final foundIndex = _ids.indexOf(widget.taskId);
    _index = foundIndex >= 0 ? foundIndex : 0;
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_ids.length > 1 ? 'Task ${_index + 1} of ${_ids.length}' : 'Task'),
      ),
      // itemCount/builder rather than a fixed children list -- PageView.builder
      // only actually builds pages near the current one (same lazy-loading
      // behavior as ListView.builder), so this stays cheap even for the
      // Tasks screen's full filtered list (can be 100+ tasks).
      body: PageView.builder(
        controller: _pageController,
        itemCount: _ids.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _TaskDetailBody(taskId: _ids[i]),
      ),
    );
  }
}

/// The actual per-task content -- everything the old single-task
/// TaskDetailScreen used to render directly, now hosted one-per-page
/// inside the PageView above so each page keeps its own independent
/// Riverpod state (status updates, comments, etc.) keyed to its own
/// taskId.
class _TaskDetailBody extends ConsumerStatefulWidget {
  final String taskId;
  const _TaskDetailBody({required this.taskId});

  @override
  ConsumerState<_TaskDetailBody> createState() => _TaskDetailBodyState();
}

class _TaskDetailBodyState extends ConsumerState<_TaskDetailBody> {
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    // Consumes router.dart's redirect trigger for a recovered task
    // attachment (see pending_attachment_service.dart) -- same deferred
    // clear AlarmScreen already uses for pendingAlarmNotifier, and for the
    // same reason: clearing it synchronously here would notify the
    // router's refreshListenable WHILE this screen is still being built as
    // part of that very redirect, which crashes with "setState() or
    // markNeedsBuild() called during build". Only clears it when it's
    // actually THIS task, so opening some other task while a recovery is
    // still in flight elsewhere doesn't cancel that redirect.
    if (pendingAttachmentTaskNotifier.value == widget.taskId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pendingAttachmentTaskNotifier.value == widget.taskId) {
          pendingAttachmentTaskNotifier.value = null;
        }
      });
    }
  }

  Future<void> _setStatus(String status) async {
    setState(() => _updating = true);
    try {
      await updateTaskStatus(widget.taskId, status);
      if (status == 'COMPLETE') {
        // A snoozed/scheduled overdue alarm is a standalone OS-level
        // trigger (AndroidAlarmManager/zonedSchedule) independent of the
        // task's own status -- finishing the task before a snooze window
        // ends previously left that alarm armed, so it still rang at the
        // original snooze time for a task that was already done. Best-
        // effort: a task completed from here was never overdue to begin
        // with in the common case, so there's usually nothing scheduled
        // to cancel.
        await NotificationService.instance.cancelOverdueAlarm(widget.taskId);
      }
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

    return taskAsync.when(
        data: (t) {
          final status = (t['status'] ?? 'TO DO').toString();
          final assignee = t['assigneeId'] is Map ? t['assigneeId'] as Map : null;
          final assigneeId = (assignee?['_id'] ?? (t['assigneeId'] is Map ? null : t['assigneeId']))?.toString();
          // "Me" instead of the logged-in person's own name, same shorthand
          // used elsewhere in the app (e.g. the Assign-to picker) -- can
          // apply to either the assignee or the creator below, since
          // either one can legitimately be the viewer.
          final assigneeName = assigneeId != null && assigneeId == currentUserId ? 'Me' : assignee?['employeeName']?.toString();
          final priority = t['priority']?.toString();
          final description = (t['description'] ?? '').toString();
          final dateTimeFmt = DateFormat('dd/MM/yyyy, hh:mm a');
          final startDate = _parseDate(t['startDate']);
          final dueDate = _parseDate(t['dueDate']);
          final reminderAt = _parseDate(t['reminderAt']);
          final completedAt = _parseDate(t['completedAt']);
          final spaceName = t['spaceName']?.toString();
          final folderName = t['folderName']?.toString();

          // createdBy is now populated (see getTask in task.controller.js)
          // as a Map when the server has it, but this screen still has to
          // handle the bare-id-string shape too -- older cached responses,
          // or a createdBy that failed to populate (e.g. its model doc was
          // deleted). Comparing the extracted id against the logged-in
          // person's own id is how this screen tells whether THEY are the
          // one who delegated this task away, i.e. the only person the
          // server will actually let approve/reject it.
          final createdByRaw = t['createdBy'];
          final createdById = (createdByRaw is Map ? createdByRaw['_id'] : createdByRaw)?.toString();
          final completionApproval = t['completionApproval'] is Map ? t['completionApproval'] as Map : null;
          final pendingApproval = completionApproval?['status'] == 'PENDING';
          final isDelegator = pendingApproval && currentUserId != null && createdById == currentUserId;
          final assignedByName = createdById != null && currentUserId != null && createdById == currentUserId
              ? 'Me'
              : (createdByRaw is Map ? (createdByRaw['employeeName'] ?? createdByRaw['name'])?.toString() : null);

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
                  // No client-side "can I edit" check here on purpose --
                  // the sheet always opens, and the server's own 5-minute/
                  // Full-Access rule (see updateTaskDetails in
                  // tasks_provider.dart) decides on save, same as the web
                  // app's own edit button does no pre-check either.
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Edit task',
                    onPressed: () => showEditTaskSheet(context, ref, t),
                    visualDensity: VisualDensity.compact,
                  ),
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
              if (assignedByName != null && assignedByName.isNotEmpty)
                _DetailRow(icon: Icons.north_east_rounded, label: 'Assigned by', value: assignedByName),
              _DetailRow(
                icon: Icons.flag_outlined,
                label: 'Priority',
                value: priority ?? 'None',
              ),
              _DetailRow(
                icon: Icons.play_circle_outline_rounded,
                label: 'Start date',
                // Was date-only -- Start date now genuinely carries a real
                // time-of-day (current time when it lands on today, see
                // add_task_sheet.dart/edit_task_sheet.dart's
                // _todayAtCurrentTime), so hiding it here made that fix
                // invisible.
                value: startDate != null ? dateTimeFmt.format(startDate) : 'Not set',
              ),
              _DetailRow(
                icon: Icons.event_outlined,
                label: 'Due date',
                // Was date-only -- Due date always carries a real
                // time-of-day too, whether explicitly picked or defaulted
                // to end-of-day (23:59, see add_task_sheet.dart/
                // edit_task_sheet.dart's dueDateTime), and that exact
                // moment is what overdue/completion timing is actually
                // judged against.
                value: dueDate != null ? dateTimeFmt.format(dueDate) : 'Not set',
              ),
              _DetailRow(
                icon: Icons.alarm_rounded,
                label: 'Reminder (alarm)',
                value: reminderAt != null ? dateTimeFmt.format(reminderAt) : 'Not set',
              ),
              if (completedAt != null)
                _DetailRow(
                  icon: Icons.task_alt_rounded,
                  label: 'Completed on',
                  value: dateTimeFmt.format(completedAt.toLocal()),
                ),

              if (description.trim().isNotEmpty) ...[
                const SizedBox(height: Gap.lg),
                Text('Description', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                Text(description, style: Theme.of(context).textTheme.bodyMedium),
              ],

              const SizedBox(height: Gap.xl),
              TaskChecklistSection(taskId: widget.taskId, checklists: (t['checklists'] as List?) ?? const []),

              const SizedBox(height: Gap.xl),
              TaskSubtasksSection(taskId: widget.taskId),

              const SizedBox(height: Gap.xl),
              TaskAttachmentsSection(taskId: widget.taskId, attachments: (t['attachments'] as List?) ?? const []),

              const SizedBox(height: Gap.xl),
              TaskCommentsSection(taskId: widget.taskId, comments: (t['comments'] as List?) ?? const []),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: 'Could not load this task.',
          onRetry: () => ref.invalidate(taskDetailProvider(widget.taskId)),
        ),
      );
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    // .toLocal() -- the server sends UTC ('Z'-suffixed) timestamps; without
    // converting back, DateFormat below prints the UTC calendar date/time
    // directly. In a timezone ahead of UTC (e.g. IST, UTC+5:30) that showed
    // a start/due date picked as "today" as the day before, and a reminder
    // time hours off from what was actually picked (and what the alarm
    // itself correctly fires at, since NotificationService schedules off
    // the same underlying instant, not this display path).
    return DateTime.tryParse(value.toString())?.toLocal();
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

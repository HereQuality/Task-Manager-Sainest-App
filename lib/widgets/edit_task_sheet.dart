import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/tasks_provider.dart';

const _priorities = ['Urgent', 'High', 'Normal', 'Low'];

/// Task Detail's "Edit" pencil -- lets the assignee/creator change a
/// task's own details (name, assignee, priority, start/due date) from the
/// phone, the same fields the web app's TaskDetailModal edits. There's no
/// separate mobile-side permission check here on purpose: the server is
/// the single source of truth for who can still edit a task and until
/// when (SuperAdmin/Teams-Full-Access always, everyone else only within 5
/// minutes of the task being assigned -- see isPastEditGracePeriod/
/// canBypassTaskLocks in task.controller.js), so this sheet just submits
/// and surfaces whatever the server decides, identically to the website.
Future<void> showEditTaskSheet(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> task,
) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _EditTaskSheetContent(task: task),
  );

  if (saved == true) {
    ref.invalidate(taskDetailProvider(task['_id'].toString()));
    ref.invalidate(myTasksProvider);
    ref.invalidate(dashboardStatsProvider);
  }
}

class _EditTaskSheetContent extends ConsumerStatefulWidget {
  final Map<String, dynamic> task;
  const _EditTaskSheetContent({required this.task});

  @override
  ConsumerState<_EditTaskSheetContent> createState() => _EditTaskSheetContentState();
}

class _EditTaskSheetContentState extends ConsumerState<_EditTaskSheetContent> {
  late final TextEditingController _nameCtrl;
  String? _assigneeId;
  String? _priority;
  DateTime? _startDate;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;
  DateTime? _reminderDate;
  TimeOfDay? _reminderTime;
  bool _saving = false;
  String? _error;

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _nameCtrl = TextEditingController(text: t['name']?.toString() ?? '');
    final assignee = t['assigneeId'];
    _assigneeId = (assignee is Map ? assignee['_id'] : assignee)?.toString();
    _priority = t['priority']?.toString();
    _startDate = _parseDate(t['startDate']);
    _dueDate = _parseDate(t['dueDate']);
    if (_dueDate != null && (_dueDate!.hour != 0 || _dueDate!.minute != 0)) {
      _dueTime = TimeOfDay(hour: _dueDate!.hour, minute: _dueDate!.minute);
    }
    final reminder = _parseDate(t['reminderAt']);
    if (reminder != null) {
      _reminderDate = DateTime(reminder.year, reminder.month, reminder.day);
      _reminderTime = TimeOfDay(hour: reminder.hour, minute: reminder.minute);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  // Same start-date/due-date cross-bounding and auto-fill as the Add Task
  // sheet (see add_task_sheet.dart's own doc comment) -- kept in sync so
  // this doesn't reintroduce the "due today but start date still offers
  // yesterday" glitch that prompted fixing it there.
  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = (isStart ? _startDate : _dueDate) ?? today;
    final firstDate = isStart ? today : (_startDate ?? today);
    // An already-existing task being edited can have a due date that's
    // already in the past (e.g. it's overdue) -- floor lastDate at
    // firstDate so that never produces an invalid (lastDate < firstDate)
    // range for showDatePicker, which asserts on that. The 5-minute edit
    // lock (server-side) is what actually stops the save on a task like
    // that, not the picker's own bounds.
    final rawLastDate = isStart ? (_dueDate ?? DateTime(now.year + 5)) : DateTime(now.year + 5);
    final lastDate = rawLastDate.isBefore(firstDate) ? firstDate : rawLastDate;
    final clampedInitial = initial.isBefore(firstDate)
        ? firstDate
        : (initial.isAfter(lastDate) ? lastDate : initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: clampedInitial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _dueDate = picked;
        if (_startDate == null || _startDate!.isAfter(picked)) {
          _startDate = today.isAfter(picked) ? picked : today;
        }
      }
    });
  }

  Future<void> _pickDueTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _dueTime ?? TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() => _dueTime = picked);
  }

  Future<void> _pickReminderDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rawInitial = _reminderDate ?? today;
    final initial = rawInitial.isBefore(today) ? today : rawInitial;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() => _reminderDate = picked);
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminderTime ?? TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() => _reminderTime = picked);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Task name cannot be empty.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final dueDateTime = _dueDate == null
        ? null
        : DateTime(
            _dueDate!.year,
            _dueDate!.month,
            _dueDate!.day,
            _dueTime?.hour ?? 23,
            _dueTime?.minute ?? 59,
          );

    final reminderDateTime = _reminderDate == null || _reminderTime == null
        ? null
        : DateTime(
            _reminderDate!.year,
            _reminderDate!.month,
            _reminderDate!.day,
            _reminderTime!.hour,
            _reminderTime!.minute,
          );

    try {
      await updateTaskDetails(
        widget.task['_id'].toString(),
        name: name,
        assigneeId: _assigneeId,
        priority: _priority,
        startDate: _startDate,
        dueDate: dueDateTime,
        reminderAt: reminderDateTime,
      );
      if (mounted) Navigator.pop(context, true);
    } on DioException catch (e) {
      // Surfaces the server's own message as-is (e.g. "This task was
      // assigned more than 5 minutes ago and can no longer be edited...")
      // rather than a generic error -- that message already explains
      // exactly why, same as the website shows.
      final msg = e.response?.data?['message']?.toString() ?? 'Could not save this task.';
      setState(() => _error = msg);
    } catch (e) {
      setState(() => _error = 'Could not save this task.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(assignableEmployeesProvider);
    final currentUserId = ref.watch(authProvider).user?.id;
    final dateFmt = DateFormat('dd/MM/yyyy');

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.xl,
        right: Gap.xl,
        top: Gap.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Edit task', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),

            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(AppRadius.field),
                ),
                child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ),
              const SizedBox(height: Gap.md),
            ],

            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Task')),
            const SizedBox(height: Gap.md),

            Row(
              children: [
                Expanded(
                  child: _EditDateField(
                    label: 'Due date',
                    value: _dueDate == null ? null : dateFmt.format(_dueDate!),
                    onTap: () => _pickDate(isStart: false),
                    onClear: _dueDate == null ? null : () => setState(() { _dueDate = null; _dueTime = null; }),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: _EditDateField(
                    label: 'Due time',
                    value: _dueTime?.format(context),
                    onTap: _pickDueTime,
                    onClear: _dueTime == null ? null : () => setState(() => _dueTime = null),
                    icon: Icons.access_time_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),

            Row(
              children: [
                Expanded(
                  child: _EditDateField(
                    label: 'Start date',
                    value: _startDate == null ? null : dateFmt.format(_startDate!),
                    onTap: () => _pickDate(isStart: true),
                    onClear: _startDate == null ? null : () => setState(() => _startDate = null),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _priority,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    items: _priorities
                        .map((p) => DropdownMenuItem<String>(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (v) => setState(() => _priority = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),

            Row(
              children: [
                Expanded(
                  child: _EditDateField(
                    label: _priority == 'Urgent' ? 'Reminder date *' : 'Reminder date',
                    value: _reminderDate == null ? null : dateFmt.format(_reminderDate!),
                    onTap: _pickReminderDate,
                    onClear: _reminderDate == null ? null : () => setState(() { _reminderDate = null; _reminderTime = null; }),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: _EditDateField(
                    label: _priority == 'Urgent' ? 'Reminder time *' : 'Reminder time',
                    value: _reminderTime?.format(context),
                    onTap: _pickReminderTime,
                    onClear: _reminderTime == null ? null : () => setState(() => _reminderTime = null),
                    icon: Icons.access_time_rounded,
                  ),
                ),
              ],
            ),
            if (_priority == 'Urgent') ...[
              const SizedBox(height: Gap.xs),
              Text(
                '* required for an Urgent task -- the overdue alarm rings at this reminder date/time.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ],
            const SizedBox(height: Gap.md),

            employeesAsync.when(
              data: (employees) {
                final me = employees.where((e) => e['_id'] == currentUserId);
                final others = employees.where((e) => e['_id'] != currentUserId);
                final sorted = [...me, ...others];
                final hasCurrentAssignee = sorted.any((e) => e['_id'] == _assigneeId);
                return DropdownButtonFormField<String>(
                  initialValue: hasCurrentAssignee ? _assigneeId : null,
                  decoration: const InputDecoration(labelText: 'Assign to'),
                  items: sorted
                      .map((e) => DropdownMenuItem<String>(
                            value: e['_id'] as String,
                            child: Text(e['_id'] == currentUserId ? 'Me' : (e['employeeName']?.toString() ?? 'Unnamed')),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _assigneeId = v),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.sm),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text('Could not load employees.', style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(height: Gap.xl),

            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditDateField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final IconData icon;
  const _EditDateField({
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
    this.icon = Icons.calendar_today_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: onClear != null
              ? IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: onClear)
              : Icon(icon, size: 18),
        ),
        child: Text(
          value ?? 'Not set',
          style: TextStyle(color: value == null ? AppColors.inkMuted : AppColors.ink),
        ),
      ),
    );
  }
}

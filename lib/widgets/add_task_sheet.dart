import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/spaces_provider.dart';
import '../providers/tasks_provider.dart';

const _priorities = ['Urgent', 'High', 'Normal', 'Low'];

class _AddTaskResult {
  final String name;
  final String spaceId;
  final DateTime? startDate;
  final DateTime? dueDate;
  final String? priority;
  final String? assigneeId;
  _AddTaskResult({
    required this.name,
    required this.spaceId,
    this.startDate,
    this.dueDate,
    this.priority,
    this.assigneeId,
  });
}

/// The "+" slot in the bottom nav (see home_shell.dart) opens this instead
/// of switching tabs -- same bottom-sheet pattern as "New support ticket"
/// on the Tickets screen, just for creating a task: Space is scoped to
/// the Spaces this account is a member of (or every Space for a
/// SuperAdmin -- see listMySpaces in space.controller.js, spacesProvider
/// just calls GET /spaces as-is), while Assign To deliberately lists
/// every active employee in the company (see assignableEmployeesProvider)
/// since a task can be handed to anyone, not just people in that Space.
Future<void> showAddTaskSheet(BuildContext context, WidgetRef ref) async {
  final result = await showModalBottomSheet<_AddTaskResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => const _AddTaskSheetContent(),
  );

  if (result == null) return;

  await createTaskInSpace(
    result.spaceId,
    name: result.name,
    assigneeId: result.assigneeId,
    startDate: result.startDate,
    dueDate: result.dueDate,
    priority: result.priority,
  );
  ref.invalidate(myTasksProvider);
  ref.invalidate(dashboardStatsProvider);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Task added')));
  }
}

class _AddTaskSheetContent extends ConsumerStatefulWidget {
  const _AddTaskSheetContent();

  @override
  ConsumerState<_AddTaskSheetContent> createState() => _AddTaskSheetContentState();
}

class _AddTaskSheetContentState extends ConsumerState<_AddTaskSheetContent> {
  final _nameCtrl = TextEditingController();
  String? _spaceId;
  String? _assigneeId;
  String? _priority;
  DateTime? _startDate;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = (isStart ? _startDate : _dueDate) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _dueDate = picked;
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

  // The overdue alarm (see NotificationService) needs an exact due
  // date+time to ring at, not just a calendar day -- so an Urgent task
  // has to carry all three before it can be saved. Everything else
  // (priority left unset, or High/Normal/Low) keeps dates optional.
  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _spaceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a space and enter a task name.')),
      );
      return;
    }
    if (_priority == 'Urgent' && (_startDate == null || _dueDate == null || _dueTime == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Urgent tasks need a start date, due date, and due time.')),
      );
      return;
    }

    final dueDateTime = _dueDate == null
        ? null
        : DateTime(
            _dueDate!.year,
            _dueDate!.month,
            _dueDate!.day,
            _dueTime?.hour ?? 23,
            _dueTime?.minute ?? 59,
          );

    Navigator.pop(
      context,
      _AddTaskResult(
        name: name,
        spaceId: _spaceId!,
        startDate: _startDate,
        dueDate: dueDateTime,
        priority: _priority,
        assigneeId: _assigneeId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spacesAsync = ref.watch(spacesProvider);
    final employeesAsync = ref.watch(assignableEmployeesProvider);
    final currentUserId = ref.watch(authProvider).user?.id;
    final dateFmt = DateFormat('MMM d, yyyy');

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
            Text('New task', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),

            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Task')),
            const SizedBox(height: Gap.md),

            spacesAsync.when(
              data: (spaces) => DropdownButtonFormField<String>(
                initialValue: _spaceId,
                decoration: const InputDecoration(labelText: 'Space'),
                items: spaces
                    .map((s) => DropdownMenuItem<String>(
                          value: s['_id'] as String,
                          child: Text(s['name']?.toString() ?? 'Untitled space'),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _spaceId = v),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.sm),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text('Could not load spaces.', style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(height: Gap.md),

            Row(
              children: [
                Expanded(
                  child: _DatePickerField(
                    label: _priority == 'Urgent' ? 'Due date *' : 'Due date',
                    value: _dueDate == null ? null : dateFmt.format(_dueDate!),
                    onTap: () => _pickDate(isStart: false),
                    onClear: _dueDate == null ? null : () => setState(() => _dueDate = null),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: _DatePickerField(
                    label: _priority == 'Urgent' ? 'Due time *' : 'Due time',
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
                  child: _DatePickerField(
                    label: _priority == 'Urgent' ? 'Start date *' : 'Start date',
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
            if (_priority == 'Urgent') ...[
              const SizedBox(height: Gap.xs),
              Text(
                '* required for an Urgent task, so the overdue alarm knows exactly when to ring.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ],
            const SizedBox(height: Gap.md),

            employeesAsync.when(
              data: (employees) {
                // The signed-in person sorts to the top of their own list,
                // labeled "Me" instead of their own name -- assigning a
                // task to yourself is the single most common pick here, so
                // it shouldn't be buried wherever their name happens to
                // fall alphabetically among everyone else in the company.
                // Split-then-concatenate (rather than a comparator) keeps
                // everyone else in whatever order assignableEmployeesProvider
                // already sorted them in, since List.sort isn't stable.
                final me = employees.where((e) => e['_id'] == currentUserId);
                final others = employees.where((e) => e['_id'] != currentUserId);
                final sorted = [...me, ...others];
                return DropdownButtonFormField<String>(
                  initialValue: _assigneeId,
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

            FilledButton(onPressed: _submit, child: const Text('Add task')),
          ],
        ),
      ),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final IconData icon;
  const _DatePickerField({
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/projects_provider.dart';
import '../providers/spaces_provider.dart';
import '../providers/tasks_provider.dart';
import 'searchable_employee_field.dart';
import 'time_picker_sheet.dart';

const _priorities = ['Urgent', 'High', 'Normal', 'Low'];

class _AddTaskResult {
  final String name;
  final String spaceId;
  final DateTime? startDate;
  final DateTime? dueDate;
  final DateTime? reminderAt;
  final List<DateTime> extraReminders;
  final String? priority;
  final String? assigneeId;
  final String? projectId;
  _AddTaskResult({
    required this.name,
    required this.spaceId,
    this.startDate,
    this.dueDate,
    this.reminderAt,
    this.extraReminders = const [],
    this.priority,
    this.assigneeId,
    this.projectId,
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
    reminderAt: result.reminderAt,
    extraReminders: result.extraReminders,
    priority: result.priority,
    projectId: result.projectId,
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
  String? _projectId;
  String? _priority;
  DateTime? _startDate;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;
  DateTime? _reminderDate;
  TimeOfDay? _reminderTime;
  // Extra, plain reminders added via the "+" next to Reminder date/time --
  // each just a normal notification at its own moment, no alarm/snooze
  // (see Task.js's extraReminders doc comment for why these are kept
  // separate from the Urgent-only overdue alarm above). Kept sorted so
  // the list on screen always reads chronologically regardless of the
  // order they were added in.
  final List<DateTime> _extraReminders = [];

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  // Start date can never be in the past, and can't land after the due
  // date; the due date can't land before the start date. Previously Start
  // date's lower bound was a flat "1 year back" with no floor at today,
  // so picking a due date of today still let Start date offer yesterday
  // or any earlier day -- that's what let an impossible range (start
  // before today, or after the due date) through in the first place.
  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = (isStart ? _startDate : _dueDate) ?? today;
    final firstDate = isStart ? today : (_startDate ?? today);
    final lastDate = isStart ? (_dueDate ?? DateTime(now.year + 5)) : DateTime(now.year + 5);
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
        _startDate = _todayAtCurrentTime(picked);
      } else {
        _dueDate = picked;
        // Auto-fill (or re-clamp) Start date the moment its valid range
        // collapses to a single sensible default -- today, or the due
        // date itself if that's somehow earlier -- rather than leaving a
        // now-invalid value in place or making the person open a second
        // picker just to confirm the only real choice (e.g. due date =
        // today leaves exactly one valid Start date: today). Left alone
        // if they'd already picked a Start date that's still valid
        // against this due date.
        if (_startDate == null || _startDate!.isAfter(picked)) {
          _startDate = _todayAtCurrentTime(today.isAfter(picked) ? picked : today);
        }
      }
    });
  }

  // showDatePicker only ever returns a date at midnight -- there's no
  // separate Start-time picker in this sheet at all, so a Start date left
  // that way always saved as 00:00. For a Start date that lands on today,
  // that read as "started at midnight" for a task someone is creating and
  // starting right now, and it's what made the Start date the auto-fill
  // set below fill in as today at 00:00 instead of today at whatever time
  // it actually is. A date that ISN'T today keeps midnight -- there's no
  // "actual" time to infer for a start date days in the future or past.
  DateTime _todayAtCurrentTime(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return now;
    }
    return date;
  }

  // TimeOfDay.format(context) defaults to whatever the DEVICE's own
  // 24-hour setting is (System Settings > Date & time > 24-hour format),
  // which on plenty of phones is ON -- this always formats as 12-hour +
  // AM/PM regardless of that device setting, matching pickTime12h's own
  // wheel picker below.
  String _formatTimeOfDay12h(TimeOfDay t) => formatTimeOfDay12h(t);

  Future<void> _pickDueTime() async {
    final picked = await pickTime12h(context, initialTime: _dueTime ?? TimeOfDay.now(), title: 'Due time');
    if (picked == null) return;
    setState(() => _dueTime = picked);
  }

  // The reminder date can be any day (independent of Start/Due) -- it's
  // simply the moment the overdue alarm should ring, not a claim about
  // when the work itself is due.
  Future<void> _pickReminderDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _reminderDate ?? today,
      firstDate: today,
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() => _reminderDate = picked);
  }

  Future<void> _pickReminderTime() async {
    final picked = await pickTime12h(context, initialTime: _reminderTime ?? TimeOfDay.now(), title: 'Reminder time');
    if (picked == null) return;
    setState(() => _reminderTime = picked);
  }

  // "+" next to Reminder date/time -- picks one more date+time (date then
  // time, same two-step flow as the main reminder above) and appends it to
  // _extraReminders. Any future moment is fair game, independent of the
  // main reminder/due/start dates -- these are just extra personal nudges.
  Future<void> _addExtraReminder() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: today,
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await pickTime12h(context, initialTime: TimeOfDay.now(), title: 'Reminder time');
    if (time == null) return;
    setState(() {
      _extraReminders.add(DateTime(date.year, date.month, date.day, time.hour, time.minute));
      _extraReminders.sort();
    });
  }

  // The overdue alarm (see NotificationService) needs an exact reminder
  // date+time to ring at, not just a calendar day -- so an Urgent task
  // has to carry both before it can be saved. Everything else (priority
  // left unset, or High/Normal/Low) keeps this optional.
  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _spaceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a space and enter a task name.')),
      );
      return;
    }
    if (_priority == 'Urgent' && (_reminderDate == null || _reminderTime == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Urgent tasks need a reminder date and time for the alarm.')),
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

    final reminderDateTime = _reminderDate == null || _reminderTime == null
        ? null
        : DateTime(
            _reminderDate!.year,
            _reminderDate!.month,
            _reminderDate!.day,
            _reminderTime!.hour,
            _reminderTime!.minute,
          );

    Navigator.pop(
      context,
      _AddTaskResult(
        name: name,
        spaceId: _spaceId!,
        startDate: _startDate,
        dueDate: dueDateTime,
        reminderAt: reminderDateTime,
        extraReminders: _extraReminders,
        priority: _priority,
        assigneeId: _assigneeId,
        projectId: _projectId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spacesAsync = ref.watch(spacesProvider);
    final projectsAsync = ref.watch(projectsProvider);
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
            Text('New task', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),

            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Task')),
            const SizedBox(height: Gap.md),

            // Assign To sits up here now (Space, further below, gets
            // auto-picked the moment a person is chosen -- see
            // onChanged) -- picking who a task is for is the more
            // natural first step, and which Space it then lands in
            // follows from that instead of being picked blind first.
            employeesAsync.when(
              data: (employees) => SearchableEmployeeField(
                label: 'Assign to',
                employees: employees,
                value: _assigneeId,
                currentUserId: currentUserId,
                onChanged: (v) => setState(() {
                  _assigneeId = v;
                  // Auto-picks whichever Space this person is a member
                  // of, same "assign them, the task lands in their own
                  // team" idea as the web app's My Task page (see
                  // task.controller.js#updateTask's moveToAssigneeSpace
                  // handling) -- just applied at creation time here
                  // instead of via a later reassignment. Left as
                  // whatever it already was if the person isn't a
                  // member of any Space this account can see (e.g. no
                  // shared Space at all), or if Assign to was cleared.
                  final spaces = spacesAsync.value;
                  if (v != null && spaces != null) {
                    final match = spaces.where((s) {
                      final memberIds = s['memberIds'];
                      return memberIds is List && memberIds.map((m) => m.toString()).contains(v);
                    });
                    if (match.isNotEmpty) _spaceId = match.first['_id'] as String;
                  }
                }),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.sm),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text('Could not load employees.', style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(height: Gap.md),

            // Optional -- a task doesn't have to belong to a Project. Every
            // active Project in the company is offered here (see
            // projects_provider.dart), same "not scoped to the chosen
            // Space" reasoning the Assign To picker below already uses.
            projectsAsync.when(
              data: (projects) => DropdownButtonFormField<String>(
                initialValue: _projectId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Project (optional)'),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('None')),
                  ...projects.map((p) => DropdownMenuItem<String>(
                        value: p['_id'] as String,
                        child: Text(
                          p['projectName']?.toString() ?? 'Untitled project',
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
                onChanged: (v) => setState(() => _projectId = v),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.sm),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text('Could not load projects.', style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(height: Gap.md),

            Row(
              children: [
                Expanded(
                  child: _DatePickerField(
                    label: 'Due date',
                    value: _dueDate == null ? null : dateFmt.format(_dueDate!),
                    onTap: () => _pickDate(isStart: false),
                    onClear: _dueDate == null ? null : () => setState(() => _dueDate = null),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: _DatePickerField(
                    label: 'Due time',
                    value: _dueTime != null ? _formatTimeOfDay12h(_dueTime!) : null,
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
                  child: _DatePickerField(
                    label: _priority == 'Urgent' ? 'Reminder date *' : 'Reminder date',
                    value: _reminderDate == null ? null : dateFmt.format(_reminderDate!),
                    onTap: _pickReminderDate,
                    onClear: _reminderDate == null ? null : () => setState(() => _reminderDate = null),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: _DatePickerField(
                    label: _priority == 'Urgent' ? 'Reminder time *' : 'Reminder time',
                    value: _reminderTime != null ? _formatTimeOfDay12h(_reminderTime!) : null,
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

            // Extra reminders -- as many plain "ping me at this moment"
            // reminders as the person wants, on top of the one above. Each
            // just posts a normal notification when it fires; only the
            // single Reminder date/time above ever drives the loud
            // full-screen overdue alarm.
            Row(
              children: [
                Text('Extra reminders', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addExtraReminder,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_extraReminders.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(
                  'None yet -- tap Add to remind yourself again at another date and time.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    for (final r in _extraReminders)
                      InputChip(
                        avatar: const Icon(Icons.notifications_active_outlined, size: 16),
                        label: Text(DateFormat('dd/MM/yyyy, hh:mm a').format(r)),
                        onDeleted: () => setState(() => _extraReminders.remove(r)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: Gap.sm),

            // Auto-filled the moment Assign to (above) picks someone --
            // still shown, and still changeable by hand, since a Space is
            // required either way and this is also the only way to set
            // one before an assignee's been picked at all.
            spacesAsync.when(
              data: (spaces) => DropdownButtonFormField<String>(
                // DropdownButtonFormField only ever reads `initialValue`
                // once, the moment its FormFieldState is first created
                // (same as any other FormField's initialValue -- it does
                // NOT track a changed value across rebuilds on its own).
                // Keying it by _spaceId forces a fresh FormFieldState
                // whenever that changes, which is what actually makes the
                // auto-pick above (or a plain manual re-selection) show up
                // here instead of silently staying on the stale display
                // while the real underlying value has already moved on.
                key: ValueKey(_spaceId),
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

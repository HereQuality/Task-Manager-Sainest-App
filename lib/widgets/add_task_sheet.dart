import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/projects_provider.dart';
import '../providers/spaces_provider.dart' show fetchEmployeeSpace, fetchAllEmployeeSpaces, spacesProvider;
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
  // One task gets created PER id in here (see showAddTaskSheet) -- not one
  // task shared by several assignees, since Task.assigneeId is a single
  // value. Empty means an unassigned task, same as before this was a list.
  final List<String> assigneeIds;
  final String? projectId;
  _AddTaskResult({
    required this.name,
    required this.spaceId,
    this.startDate,
    this.dueDate,
    this.reminderAt,
    this.extraReminders = const [],
    this.priority,
    this.assigneeIds = const [],
    this.projectId,
  });
}

/// One (assignee, Team) pair showAddTaskSheet below actually creates a
/// task for -- see its own doc comment on why a single ticked assignee can
/// expand into several of these.
class _AddTaskTarget {
  final String? assigneeId;
  final String? spaceId;
  const _AddTaskTarget({required this.assigneeId, required this.spaceId});
}

/// The "+" slot in the bottom nav (see home_shell.dart) opens this instead
/// of switching tabs -- same bottom-sheet pattern as "New support ticket"
/// on the Tickets screen, just for creating a task: Space is scoped to
/// the Spaces this account is a member of (or every Space for a
/// SuperAdmin -- see listMySpaces in space.controller.js, spacesProvider
/// just calls GET /spaces as-is), while Assign To deliberately lists
/// every active employee in the company (see assignableEmployeesProvider)
/// since a task can be handed to anyone, not just people in that Space --
/// including someone on a completely different team than whoever's
/// creating this task. That mismatch is exactly why creation and
/// assignment happen as two separate calls below (createTaskInSpace,
/// then assignTaskAndMoveSpace in tasks_provider.dart) instead of one:
/// the task always ends up in the ASSIGNEE's real Space, resolved
/// server-side, regardless of which (possibly unrelated) Space this
/// account happened to have selected or could even see.
Future<void> showAddTaskSheet(BuildContext context, WidgetRef ref) async {
  final result = await showModalBottomSheet<_AddTaskResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => const _AddTaskSheetContent(),
  );

  if (result == null) return;

  // Expands each ticked assignee into one target per TEAM they actually
  // belong to -- someone split across two Teams needs a separate task in
  // each, not a guess at just one (see fetchAllEmployeeSpaces' own doc
  // comment). Someone in zero Teams still gets exactly one task, assigned
  // to them but left in the placeholder Space below (same fallback as
  // before this per-Team expansion existed). No assignees ticked at all
  // means exactly one unassigned task, same as ever.
  final targets = <_AddTaskTarget>[];
  if (result.assigneeIds.isEmpty) {
    targets.add(const _AddTaskTarget(assigneeId: null, spaceId: null));
  } else {
    for (final assigneeId in result.assigneeIds) {
      List<Map<String, dynamic>> teams;
      try {
        teams = await fetchAllEmployeeSpaces(assigneeId);
      } catch (_) {
        teams = const [];
      }
      if (teams.isEmpty) {
        targets.add(_AddTaskTarget(assigneeId: assigneeId, spaceId: null));
      } else {
        for (final team in teams) {
          targets.add(_AddTaskTarget(assigneeId: assigneeId, spaceId: team['_id']?.toString()));
        }
      }
    }
  }

  // One task per target above -- each created and relocated completely
  // independently via the same create-then-assign flow a single assignee
  // already used, so ticking several people (or one person in several
  // Teams) never produces one task shared between them. A failed copy
  // doesn't stop the rest; `failed` is surfaced in the closing snack bar
  // so a partial batch is never silently reported as fully successful.
  var created = 0;
  var failed = 0;
  for (final target in targets) {
    try {
      final taskId = await createTaskInSpace(
        result.spaceId,
        name: result.name,
        startDate: result.startDate,
        dueDate: result.dueDate,
        reminderAt: result.reminderAt,
        extraReminders: result.extraReminders,
        priority: result.priority,
        projectId: result.projectId,
      );
      // Two-step on purpose when an assignee was picked -- see
      // assignTaskAndMoveSpace's own doc comment: this is what actually
      // gets the task into that person's real team even when they're on a
      // different team than whoever's creating it (the Space picker above
      // only ever lists Spaces THIS account can see, so it may not even
      // have offered the assignee's real team as an option). targetSpaceId
      // pins it to the EXACT Team this target is for, when there's more
      // than one to choose from.
      if (target.assigneeId != null && taskId.isNotEmpty) {
        await assignTaskAndMoveSpace(taskId, target.assigneeId!, targetSpaceId: target.spaceId);
      }
      created += 1;
    } catch (_) {
      failed += 1;
    }
  }
  ref.invalidate(myTasksProvider);
  ref.invalidate(dashboardStatsProvider);
  // See edit_task_sheet.dart's identical call for why this is needed:
  // notificationsFeedProvider is the only place a reminderAt/extraReminders
  // actually gets scheduled on-device, and it's autoDispose -- only run
  // while the Notifications screen is open. Without forcing it here, a
  // brand-new task's reminder would silently do nothing until that screen
  // happened to be visited (iOS has no background poller to catch it
  // otherwise, unlike Android's background_watcher_service.dart).
  unawaited(ref.read(notificationsFeedProvider.future));
  if (context.mounted) {
    final message = targets.length <= 1
        ? (created > 0 ? 'Task added' : 'Failed to add task')
        : failed > 0
            ? '$created task${created == 1 ? '' : 's'} added, $failed failed'
            : '$created tasks added';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
  // Ticking several people here makes showAddTaskSheet create one
  // completely separate task per person instead of a single shared one
  // (see its own doc comment) -- nothing on screen or on the server links
  // those copies together once they're created.
  List<String> _assigneeIds = [];
  // The chosen assignee's own Space, fetched via fetchEmployeeSpace the
  // moment they're picked -- kept separately from spacesAsync's own list
  // (which only ever holds Spaces THIS account can see) so it can be
  // merged into the Space dropdown's items below even when it's a team
  // this account otherwise has no visibility into at all. Null while
  // loading, if the assignee isn't in any Space yet, or if several people
  // are selected (which Space to preview then isn't well-defined -- see
  // _onAssigneesChanged).
  Map<String, dynamic>? _assigneeSpace;
  // Every selected assignee's full Team list, keyed by their id -- powers
  // the "who's going to which Team" preview shown under the Assign to
  // field, and is exactly what showAddTaskSheet itself re-fetches (fresh,
  // not from this UI-only cache) to decide how many task copies to make.
  // An empty (not missing) entry means that lookup finished and genuinely
  // found no Team; a missing entry means it's still loading.
  final Map<String, List<Map<String, dynamic>>> _assigneeTeamsById = {};
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

  // Bumped on every assignee pick, so a slow fetchEmployeeSpace response
  // for an EARLIER pick can't clobber a newer one that already resolved
  // (or is still in flight) -- e.g. quickly picking Person A then Person
  // B before A's lookup returns.
  int _assigneeSpaceRequestToken = 0;
  // Same bumped-counter guard as _assigneeSpaceRequestToken above, for the
  // per-person Team-list preview fetches below.
  int _assigneeTeamsRequestToken = 0;

  // Picking Assign To person(s) looks up their own Space (GET /spaces/
  // for-employee/:id -- see fetchEmployeeSpace's own doc comment) so the
  // Space field below can show/select the CORRECT team even when this
  // account has no visibility into it at all (a non-Full-Access person
  // assigning someone on a different team, whose team never appears in
  // spacesAsync's own list). The actual task placement doesn't depend on
  // this succeeding -- see showAddTaskSheet's assignTaskAndMoveSpace call,
  // which resolves it server-side regardless -- this only fixes what the
  // picker DISPLAYS while filling out the form.
  //
  // Only previewed for exactly one selected person -- with several people
  // ticked, each ends up in their OWN Space once the separate tasks are
  // created (see showAddTaskSheet), so there's no single "the" Space to
  // preview here; the field just falls back to showing/letting this
  // account pick its own default Space as the placeholder used while
  // creating each copy.
  Future<void> _onAssigneesChanged(List<String> ids) async {
    final spaceToken = ++_assigneeSpaceRequestToken;
    final teamsToken = ++_assigneeTeamsRequestToken;
    setState(() {
      _assigneeIds = ids;
      _assigneeSpace = null;
      // Drop any cached Team list for someone who just got unticked, so a
      // re-tick later fetches fresh rather than reading stale data --
      // membership can change between picks within the same open sheet.
      _assigneeTeamsById.removeWhere((id, _) => !ids.contains(id));
    });

    if (ids.length == 1) {
      Map<String, dynamic>? space;
      try {
        space = await fetchEmployeeSpace(ids.first);
      } catch (_) {
        // Best-effort display only -- a failed lookup just leaves the
        // Space field showing whatever it already had (or blank), same as
        // before this feature existed. The task itself still ends up in
        // the right place either way (see assignTaskAndMoveSpace).
        space = null;
      }
      if (mounted && spaceToken == _assigneeSpaceRequestToken) {
        setState(() {
          _assigneeSpace = space;
          if (space != null) _spaceId = space['_id']?.toString();
        });
      }
    } else if (_spaceId == null) {
      // Zero or several assignees ticked -- there's no single "the"
      // person's Space to auto-fill here (see this function's own doc
      // comment above), but _submit() still requires SOME Space picked
      // before it'll let the form through. Falls back to this account's
      // own first available Space, purely as the placeholder
      // createTaskInSpace creates into -- showAddTaskSheet's per-target
      // assignTaskAndMoveSpace call is what actually relocates each copy
      // to the right Team afterward, so this placeholder never affects
      // where a task ends up once an assignee is picked. Left untouched
      // if something (a previous single pick, or a manual choice) already
      // set one.
      final spaces = ref.read(spacesProvider).valueOrNull;
      if (mounted && spaces != null && spaces.isNotEmpty) {
        setState(() => _spaceId ??= spaces.first['_id']?.toString());
      }
    }

    // "Which Team(s) will this actually go to" preview, for every newly
    // ticked id this device hasn't already looked up -- see
    // _assigneeTeamsById's own doc comment. Fetched in parallel since
    // each is an independent lookup.
    final toFetch = ids.where((id) => !_assigneeTeamsById.containsKey(id)).toList();
    if (toFetch.isEmpty) return;
    final fetched = await Future.wait(toFetch.map((id) async {
      try {
        return MapEntry(id, await fetchAllEmployeeSpaces(id));
      } catch (_) {
        return MapEntry(id, const <Map<String, dynamic>>[]);
      }
    }));
    if (!mounted || teamsToken != _assigneeTeamsRequestToken) return;
    setState(() {
      for (final entry in fetched) {
        _assigneeTeamsById[entry.key] = entry.value;
      }
    });
  }

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
        assigneeIds: _assigneeIds,
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
              data: (employees) => MultiSearchableEmployeeField(
                label: 'Assign to',
                employees: employees,
                value: _assigneeIds,
                currentUserId: currentUserId,
                onChanged: (ids) => _onAssigneesChanged(ids),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.sm),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text('Could not load employees.', style: Theme.of(context).textTheme.bodyMedium),
            ),
            // "Who's actually getting which Team" preview -- shows up the
            // instant each person is ticked (see _onAssigneesChanged), so
            // it's obvious BEFORE hitting "Add task" that someone split
            // across two Teams is about to get two separate task copies,
            // one per Team, rather than that only becoming visible after
            // the fact in the task lists themselves.
            if (_assigneeIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final id in _assigneeIds)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Builder(builder: (context) {
                          final employees = employeesAsync.value ?? const [];
                          final match = employees.where((e) => e['_id'] == id);
                          final name = id == currentUserId
                              ? 'Me'
                              : (match.isNotEmpty ? match.first['employeeName']?.toString() : null) ?? '...';
                          final teams = _assigneeTeamsById[id];
                          final teamsText = teams == null
                              ? 'looking up team…'
                              : teams.isEmpty
                                  ? 'not in any team yet -- will stay here'
                                  : teams.length == 1
                                      ? '${teams.first['name']}'
                                      : '${teams.length} teams: ${teams.map((t) => t['name']).join(', ')}';
                          return Text(
                            '$name → $teamsText',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
                          );
                        }),
                      ),
                  ],
                ),
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
            //
            // Hidden entirely once 2+ people are ticked: at that point
            // _spaceId is just an internal placeholder (see
            // _onAssigneesChanged's else branch) that createTaskInSpace
            // uses to create EACH copy before it gets relocated to that
            // specific person's actual Team -- showing it here read as
            // "this task is going to Accounts" even when the "Me -> Dumy /
            // Bhim Rai -> Dumy" preview right above already says
            // otherwise, which is exactly the confusing, wrong-looking
            // mismatch this avoids. The per-person preview above is the
            // real answer once there's more than one assignee; this
            // dropdown only still means something when there's at most
            // one.
            if (_assigneeIds.length <= 1)
            spacesAsync.when(
              data: (spaces) {
                // Merges in the chosen assignee's own Space
                // (_assigneeSpace, from _onAssigneeChanged/
                // fetchEmployeeSpace) whenever it isn't already one of
                // the Spaces THIS account can see -- without this, a
                // non-Full-Access person assigning someone on a
                // different team would have `_spaceId` set to a value
                // that isn't in `items` at all, so the dropdown would
                // just show blank instead of that person's real team
                // name (the exact gap that made this feel broken
                // compared to a SuperAdmin's account, where that team
                // already happens to be in their own full spacesAsync
                // list).
                final items = [...spaces];
                final assigneeSpace = _assigneeSpace;
                if (assigneeSpace != null &&
                    !items.any((s) => s['_id']?.toString() == assigneeSpace['_id']?.toString())) {
                  items.add(assigneeSpace);
                }
                return DropdownButtonFormField<String>(
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
                  items: items
                      .map((s) => DropdownMenuItem<String>(
                            value: s['_id'] as String,
                            child: Text(s['name']?.toString() ?? 'Untitled space'),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _spaceId = v),
                );
              },
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

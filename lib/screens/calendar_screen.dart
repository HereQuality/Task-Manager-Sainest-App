import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/tasks_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/searchable_employee_field.dart';
import '../widgets/task_meta_chips.dart';

// assigneeId comes back from /tasks/mine/all populated (a Map with _id)
// when set -- same shape juggling as tasks_screen.dart's own _refId.
String? _assigneeId(dynamic v) {
  if (v is Map) return (v['_id'] ?? v['id'])?.toString();
  return v?.toString();
}

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  // null = the default "My Task" view (see build() below, which then
  // falls back to the logged-in user's own id). Set by picking someone
  // in the filter sheet opened from the AppBar's filter icon.
  String? _selectedPersonId;

  Future<void> _openPersonFilter(List<Map<String, dynamic>> employees, String? currentUserId) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => EmployeeSearchSheet(
        title: 'View calendar for',
        employees: employees,
        currentUserId: currentUserId,
        selectedId: _selectedPersonId,
      ),
    );
    // Dismissed (back / tap outside) -- leave the current selection
    // alone. The sheet's own "Clear selection" resolves with '' instead,
    // which IS a real choice (back to the default "My Task" view).
    if (picked == null) return;
    setState(() => _selectedPersonId = picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(myTasksProvider);
    final employeesAsync = ref.watch(assignableEmployeesProvider);
    final currentUserId = ref.watch(authProvider).user?.id;
    final employees = employeesAsync.value ?? const <Map<String, dynamic>>[];
    final selectedPersonName = _selectedPersonId == null
        ? null
        : employees
            .where((e) => e['_id'] == _selectedPersonId)
            .map((e) => e['employeeName']?.toString())
            .firstWhere((n) => n != null, orElse: () => 'team member');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.filter_list_rounded,
              color: _selectedPersonId != null ? AppColors.indigo : null,
            ),
            tooltip: 'View another team member\'s calendar',
            onPressed: employeesAsync.hasValue ? () => _openPersonFilter(employees, currentUserId) : null,
          ),
        ],
      ),
      body: tasksAsync.when(
        data: (allTasks) {
          // Default (nobody picked in the filter) is "my own tasks", even
          // for an account that can see everyone's (myTasksProvider
          // itself already returns every task company-wide for a
          // SuperAdmin/top-of-hierarchy account) -- the calendar only
          // ever widens to someone else once you explicitly pick them.
          final targetPersonId = _selectedPersonId ?? currentUserId;
          final tasks = targetPersonId == null
              ? allTasks
              : allTasks.where((t) => _assigneeId(t['assigneeId']) == targetPersonId).toList();

          final byDay = <DateTime, List<Map<String, dynamic>>>{};
          for (final t in tasks) {
            final due = t['dueDate'];
            if (due == null) continue;
            final d = DateTime.tryParse(due.toString());
            if (d == null) continue;
            final key = DateTime(d.year, d.month, d.day);
            byDay.putIfAbsent(key, () => []).add(t);
          }
          final selectedKey = DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
          final selectedTasks = byDay[selectedKey] ?? [];

          return Column(
            children: [
              if (_selectedPersonId != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.indigoSoft,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.person_rounded, size: 16, color: AppColors.indigo),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Viewing $selectedPersonName\'s tasks',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.indigo),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _selectedPersonId = null),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close_rounded, size: 16, color: AppColors.indigo),
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: AppColors.line),
                ),
                // Always the full month grid -- shrunk down across every
                // dimension (row height, weekday-label row, header) instead
                // of a week/month toggle, so the task list below always has
                // more room without an extra tap to get it.
                child: TableCalendar(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2035, 12, 31),
                  focusedDay: _focusedDay,
                  headerStyle: const HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    headerPadding: EdgeInsets.symmetric(vertical: 4),
                    titleTextStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink),
                    leftChevronPadding: EdgeInsets.zero,
                    rightChevronPadding: EdgeInsets.zero,
                    leftChevronIcon: Icon(Icons.chevron_left_rounded, size: 20, color: AppColors.inkMuted),
                    rightChevronIcon: Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.inkMuted),
                  ),
                  daysOfWeekHeight: 18,
                  daysOfWeekStyle: const DaysOfWeekStyle(
                    weekdayStyle: TextStyle(fontSize: 11, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                    weekendStyle: TextStyle(fontSize: 11, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                  ),
                  // Small enough that the fixed 6-row month grid no longer
                  // eats half the screen, but still tall enough for the
                  // marker dot below the day number not to feel cramped.
                  rowHeight: 34,
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    cellMargin: const EdgeInsets.all(2),
                    defaultTextStyle: const TextStyle(fontSize: 12.5),
                    weekendTextStyle: const TextStyle(fontSize: 12.5),
                    todayDecoration: BoxDecoration(
                      color: AppColors.indigoSoft,
                      shape: BoxShape.circle,
                    ),
                    todayTextStyle: const TextStyle(color: AppColors.indigo, fontWeight: FontWeight.w700, fontSize: 12.5),
                    selectedDecoration: const BoxDecoration(color: AppColors.indigo, shape: BoxShape.circle),
                    selectedTextStyle: const TextStyle(color: Colors.white, fontSize: 12.5),
                    markerDecoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                    markersMaxCount: 1,
                    markerSize: 4,
                    // table_calendar's own doc comment: "A value of 0.5 will
                    // center the markers AT the bottom edge of day cell's
                    // decoration" -- i.e. half the dot sits on top of the
                    // circle. The library's own default (0.7) pulls it up
                    // even further into the circle, which is exactly the
                    // "dot on the edge of the circle" look this was meant to
                    // fix. A negative anchor pushes the dot's top edge below
                    // the circle's bottom edge instead of into it.
                    markersAnchor: -0.6,
                  ),
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  eventLoader: (day) => byDay[DateTime(day.year, day.month, day.day)] ?? [],
                  onDaySelected: (selected, focused) {
                    setState(() {
                      _selectedDay = selected;
                      _focusedDay = focused;
                    });
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    isSameDay(_selectedDay, DateTime.now()) ? 'Today' : _formatDate(_selectedDay),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: Gap.sm),
              Expanded(
                child: selectedTasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_available_rounded,
                        title: 'Nothing due this day',
                        message: 'Pick another day, or enjoy the clear schedule.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
                        itemCount: selectedTasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                        itemBuilder: (context, i) {
                          final t = selectedTasks[i];
                          final spaceName = t['spaceName']?.toString();
                          return EntityCard(
                            title: t['title'] ?? t['name'] ?? 'Untitled task',
                            status: t['status'] == 'COMPLETE' ? 'COMPLETED' : (t['status'] ?? 'pending'),
                            leadingIcon: Icons.task_alt_rounded,
                            subtitle: spaceName != null && spaceName.isNotEmpty ? spaceName : null,
                            // Same chip set every other task row in the
                            // app uses (see task_meta_chips.dart) -- due
                            // date, priority, assigned by/to.
                            metaRow: taskMetaRow(t, currentUserId: currentUserId),
                            onTap: () => context.push('/home/tasks/${t['_id']}'),
                          );
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: 'Something went wrong loading your tasks.',
          onRetry: () => ref.invalidate(myTasksProvider),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

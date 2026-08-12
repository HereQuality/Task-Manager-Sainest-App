import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(myTasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: tasksAsync.when(
        data: (tasks) {
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
              Container(
                margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: AppColors.line),
                ),
                child: TableCalendar(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2035, 12, 31),
                  focusedDay: _focusedDay,
                  headerStyle: const HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.ink),
                  ),
                  // A little taller than table_calendar's own 52px default --
                  // the marker gap added below (markersAnchor) needs somewhere
                  // to sit that isn't crowding the next row down.
                  rowHeight: 58,
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    todayDecoration: BoxDecoration(
                      color: AppColors.indigoSoft,
                      shape: BoxShape.circle,
                    ),
                    todayTextStyle: const TextStyle(color: AppColors.indigo, fontWeight: FontWeight.w700),
                    selectedDecoration: const BoxDecoration(color: AppColors.indigo, shape: BoxShape.circle),
                    markerDecoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                    markersMaxCount: 1,
                    markerSize: 5,
                    // table_calendar's own doc comment: "A value of 0.5 will
                    // center the markers AT the bottom edge of day cell's
                    // decoration" -- i.e. half the dot sits on top of the
                    // circle. The library's own default (0.7) pulls it up
                    // even further into the circle, which is exactly the
                    // "dot on the edge of the circle" look this was meant to
                    // fix. A negative anchor pushes the dot's top edge below
                    // the circle's bottom edge instead of into it -- -1.0
                    // here means a full marker-height gap between the two.
                    markersAnchor: -1.0,
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
                            status: t['status'] ?? 'pending',
                            leadingIcon: Icons.task_alt_rounded,
                            subtitle: spaceName != null && spaceName.isNotEmpty ? spaceName : null,
                            onTap: () => context.push('/home/tasks/${t['_id']}'),
                          );
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(message: '$e', onRetry: () => ref.invalidate(myTasksProvider)),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

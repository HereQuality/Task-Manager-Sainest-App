import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';

enum _DueFilter { all, today, upcoming, overdue }

// Status facet options shown in the Filters sheet -- mirrors the web
// app's STATUS_GROUPS + OVERDUE_GROUP + DELAYED_GROUP (TaskListView.jsx):
// OVERDUE and COMPLETE (LATE) aren't real task.status values, they're
// client-side regroupings (see _isOverdue/_isDelayed/_effectiveStatus
// below) so a task whose due date has passed, or that finished after its
// due date, gets its own checkbox instead of being lumped in with
// TO DO/IN PROGRESS or a plain on-time COMPLETE.
const _statusFacetOptions = [
  ('TO DO', 'TO DO'),
  ('IN PROGRESS', 'IN PROGRESS'),
  ('DELEGATED', 'DELEGATED (Awaiting Approval)'),
  ('OVERDUE', 'OVERDUE'),
  ('COMPLETE', 'COMPLETE'),
  ('COMPLETE_LATE', 'COMPLETE (LATE)'),
];
const _priorityOptions = ['Urgent', 'High', 'Normal', 'Low'];

// Fixed status-group order the task list renders in -- still-open work
// first, completed work last. Matches the keys _effectiveStatus produces.
// DELEGATED sits before OVERDUE: it's a task someone marked complete that's
// now sitting on the current person's own decision (approve/reject) --
// more actionable right now than a plain overdue task still waiting on
// someone else to move it.
const _statusOrder = ['TO DO', 'IN PROGRESS', 'DELEGATED', 'OVERDUE', 'COMPLETE', 'COMPLETE_LATE'];

// Mirrors TaskListView.jsx#isTaskOverdue: a not-yet-complete task whose
// due date has passed.
bool _isOverdue(Map<String, dynamic> t) {
  if (t['status'] == 'COMPLETE') return false;
  final due = t['dueDate'];
  if (due == null) return false;
  final d = DateTime.tryParse(due.toString());
  if (d == null) return false;
  return d.isBefore(DateTime.now());
}

// Mirrors TaskListView.jsx#isTaskDelayed: a COMPLETE task that finished
// strictly after its own due date.
bool _isDelayed(Map<String, dynamic> t) {
  if (t['status'] != 'COMPLETE') return false;
  final due = t['dueDate'];
  final completed = t['completedAt'];
  if (due == null || completed == null) return false;
  final d = DateTime.tryParse(due.toString());
  final c = DateTime.tryParse(completed.toString());
  if (d == null || c == null) return false;
  return c.isAfter(d);
}

// Set (see the screen's build method, where tasks from
// pendingApprovalsProvider are merged into the main list) on a task the
// current person delegated away and that its assignee has already marked
// complete -- server-side, task.status is deliberately left as-is until
// this person approves or rejects it (Task.js#completionApproval), so
// without this flag a delegated-and-marked-done task would otherwise just
// silently sit in whatever its pre-completion group was (TO DO/IN
// PROGRESS), with nothing in the UI showing it actually needs a decision.
bool _isPendingApproval(Map<String, dynamic> t) => t['_pendingMyApproval'] == true;

// Mirrors TaskListView.jsx#effectiveTaskStatus -- what the Status facet
// actually filters against, rather than the raw task.status. Checked
// before OVERDUE: a task can be both (its due date passed before the
// assignee got around to marking it complete), and "needs my approval"
// is the more useful/actionable framing at that point.
String _effectiveStatus(Map<String, dynamic> t) {
  if (_isPendingApproval(t)) return 'DELEGATED';
  if (_isOverdue(t)) return 'OVERDUE';
  if (_isDelayed(t)) return 'COMPLETE_LATE';
  return (t['status'] ?? '').toString();
}

// What the task card actually shows -- an overdue task reads "OVERDUE"
// instead of whatever its raw status (TO DO/IN PROGRESS) happens to be,
// same reasoning as _effectiveStatus above but as a friendly label rather
// than a filter key.
String _displayStatus(Map<String, dynamic> t) {
  if (_isPendingApproval(t)) return 'DELEGATED';
  if (_isOverdue(t)) return 'OVERDUE';
  if (_isDelayed(t)) return 'COMPLETE (LATE)';
  return (t['status'] ?? 'pending').toString();
}

int _compareByDueDate(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ad = a['dueDate'] != null ? DateTime.tryParse(a['dueDate'].toString()) : null;
  final bd = b['dueDate'] != null ? DateTime.tryParse(b['dueDate'].toString()) : null;
  if (ad == null && bd == null) return 0;
  if (ad == null) return 1;
  if (bd == null) return -1;
  return ad.compareTo(bd);
}

// assigneeId/projectId come back from /tasks/mine/all populated (a Map
// with _id/name fields) when set, but can be null/absent -- these two
// just centralize digging the id and display name out of that shape so
// the rest of the file doesn't repeat the same null-and-type juggling.
String? _refId(dynamic v) {
  if (v is Map) return (v['_id'] ?? v['id'])?.toString();
  return v?.toString();
}

String? _refName(dynamic v, String nameKey) => v is Map ? v[nameKey]?.toString() : null;

// One row in the grouped task list -- either a collapsible section header
// (TO DO/IN PROGRESS/OVERDUE/COMPLETE/COMPLETE (LATE), each with its own
// arrow toggle) or a task belonging to whichever header preceded it.
class _TaskListEntry {
  final String? headerKey;
  final String? headerLabel;
  final int? headerCount;
  final Map<String, dynamic>? task;

  const _TaskListEntry.header(this.headerKey, this.headerLabel, this.headerCount) : task = null;
  const _TaskListEntry.task(this.task)
      : headerKey = null,
        headerLabel = null,
        headerCount = null;

  bool get isHeader => task == null;
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  _DueFilter _dueFilter = _DueFilter.all;
  final _searchController = TextEditingController();
  String _query = '';
  Set<String> _selectedStatuses = {};
  Set<String> _selectedPriorities = {};
  Set<String> _selectedTags = {};
  Set<String> _selectedAssigneeIds = {};
  Set<String> _selectedProjectIds = {};
  Set<String> _selectedSpaceIds = {};
  bool _dtrOnly = false;
  DateTime? _dueFrom;
  DateTime? _dueTo;
  bool _noDueDateOnly = false;
  // Which status groups (by _statusOrder key) are collapsed -- empty by
  // default, i.e. every group starts expanded. Tapping a group's header
  // (the chevron row) toggles it, same collapsible-section pattern as
  // TO DO/IN PROGRESS/OVERDUE/COMPLETE/COMPLETE (LATE) each being their
  // own foldable block instead of one long flat list.
  final Set<String> _collapsedGroups = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int get _activeFacetCount =>
      _selectedStatuses.length +
      _selectedPriorities.length +
      _selectedTags.length +
      _selectedAssigneeIds.length +
      _selectedProjectIds.length +
      _selectedSpaceIds.length +
      (_dtrOnly ? 1 : 0) +
      (_dueFrom != null ? 1 : 0) +
      (_dueTo != null ? 1 : 0) +
      (_noDueDateOnly ? 1 : 0);

  void _clearAllFacets() {
    setState(() {
      _selectedStatuses = {};
      _selectedPriorities = {};
      _selectedTags = {};
      _selectedAssigneeIds = {};
      _selectedProjectIds = {};
      _selectedSpaceIds = {};
      _dtrOnly = false;
      _dueFrom = null;
      _dueTo = null;
      _noDueDateOnly = false;
      _dueFilter = _DueFilter.all;
      _query = '';
      _searchController.clear();
    });
  }

  Future<void> _openFilterSheet({
    required List<String> availableTags,
    required Map<String, String> availableAssignees,
    required Map<String, String> availableProjects,
    required Map<String, String> availableSpaces,
  }) async {
    final result = await showModalBottomSheet<_FacetSelection>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _FilterSheet(
        availableTags: availableTags,
        availableAssignees: availableAssignees,
        availableProjects: availableProjects,
        availableSpaces: availableSpaces,
        initialStatuses: _selectedStatuses,
        initialPriorities: _selectedPriorities,
        initialTags: _selectedTags,
        initialAssigneeIds: _selectedAssigneeIds,
        initialProjectIds: _selectedProjectIds,
        initialSpaceIds: _selectedSpaceIds,
        initialDtrOnly: _dtrOnly,
        initialDueFrom: _dueFrom,
        initialDueTo: _dueTo,
        initialNoDueDateOnly: _noDueDateOnly,
      ),
    );
    if (result != null) {
      setState(() {
        _selectedStatuses = result.statuses;
        _selectedPriorities = result.priorities;
        _selectedTags = result.tags;
        _selectedAssigneeIds = result.assigneeIds;
        _selectedProjectIds = result.projectIds;
        _selectedSpaceIds = result.spaceIds;
        _dtrOnly = result.dtrOnly;
        _dueFrom = result.dueFrom;
        _dueTo = result.dueTo;
        _noDueDateOnly = result.noDueDateOnly;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(myTasksProvider);
    // Best-effort: pendingApprovalsProvider failing/still-loading shouldn't
    // block the whole screen the way tasksAsync's own error/loading state
    // does below -- worst case the DELEGATED group is just empty a moment
    // longer, same "don't let this take the rest of the screen down with
    // it" reasoning myTasksProvider's own 403 handling already uses.
    final pendingApprovals = ref.watch(pendingApprovalsProvider).value ?? const <Map<String, dynamic>>[];

    return Scaffold(
      appBar: AppBar(title: const Text('My tasks')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myTasksProvider);
          ref.invalidate(pendingApprovalsProvider);
        },
        child: tasksAsync.when(
          data: (myTasks) {
            final now = DateTime.now();

            // Merges in tasks from pendingApprovalsProvider -- scoped to
            // "I delegated this away and it's now waiting on MY decision",
            // which can include tasks assigned to someone outside this
            // person's own subordinate chain (a lateral delegate), so
            // myTasksProvider's assignee/subordinate-scoped list above
            // can't be assumed to already contain them. Dedupes by _id
            // (a task can legitimately appear in both, e.g. delegated to
            // one's own subordinate) and flags every pending-approval task
            // so _effectiveStatus/_displayStatus can classify it as
            // DELEGATED regardless of which list it came from.
            final pendingIds = pendingApprovals.map((p) => (p['_id'] ?? '').toString()).toSet();
            final byId = <String, Map<String, dynamic>>{};
            for (final t in myTasks) {
              final id = (t['_id'] ?? '').toString();
              byId[id] = pendingIds.contains(id) ? {...t, '_pendingMyApproval': true} : t;
            }
            for (final p in pendingApprovals) {
              final id = (p['_id'] ?? '').toString();
              byId.putIfAbsent(id, () => {...p, '_pendingMyApproval': true});
            }
            final allTasks = byId.values.toList();

            // Built from every task, not the filtered set below -- the
            // available choices in the filter sheet shouldn't shrink just
            // because other filters are already narrowing the list;
            // that's what makes it possible to combine e.g. a Priority
            // filter with a Tag that only exists on tasks of a different
            // priority and get an (empty, but intentional) result instead
            // of the option quietly vanishing from the sheet. Unlike the
            // web app, this screen has no separate members/projects
            // endpoint wired to it -- Assignee/Project options are built
            // from what's actually on these tasks, same as Tags, rather
            // than the full team roster/project list.
            final availableTags = <String>{
              for (final t in allTasks) ...List<String>.from(t['tags'] ?? const []),
            }.toList()
              ..sort();

            final availableAssignees = <String, String>{};
            final availableProjects = <String, String>{};
            // spaceName/spaceId are annotated onto every task by the
            // server (task.controller.js#listMyTasksAll) since this
            // screen already spans every Space the person has tasks in
            // -- same reasoning as the web app's "All Spaces" page
            // Space facet (TaskListView.jsx).
            final availableSpaces = <String, String>{};
            for (final t in allTasks) {
              final aId = _refId(t['assigneeId']);
              final aName = _refName(t['assigneeId'], 'employeeName');
              if (aId != null && aName != null) availableAssignees[aId] = aName;
              final pId = _refId(t['projectId']);
              final pName = _refName(t['projectId'], 'projectName');
              if (pId != null && pName != null) availableProjects[pId] = pName;
              final sId = t['spaceId']?.toString();
              final sName = t['spaceName']?.toString();
              if (sId != null && sName != null && sName.isNotEmpty) availableSpaces[sId] = sName;
            }

            final tasks = allTasks.where((t) {
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                // Matches everything a person might type to find a task
                // by -- not just its name -- mirroring
                // TaskListView.jsx#taskMatchesSearch on the web app:
                // taskId, assignee, project, tags, priority too.
                final haystack = [
                  t['title'],
                  t['name'],
                  t['taskId'],
                  _refName(t['assigneeId'], 'employeeName'),
                  _refName(t['projectId'], 'projectName'),
                  t['priority'],
                  ...List<String>.from(t['tags'] ?? const []),
                ];
                final matches = haystack.any((v) => v != null && v.toString().toLowerCase().contains(q));
                if (!matches) return false;
              }

              if (_dueFilter == _DueFilter.overdue) {
                // Only tasks that are actually OVERDUE right now (see
                // _isOverdue above) -- a completed task whose due date
                // happens to be in the past no longer belongs here, it's
                // done.
                if (!_isOverdue(t)) return false;
              } else if (_dueFilter == _DueFilter.today) {
                if (t['status'] == 'COMPLETE') return false;
                final due = t['dueDate'];
                final d = due != null ? DateTime.tryParse(due.toString()) : null;
                if (d == null) return false;
                if (!(d.year == now.year && d.month == now.month && d.day == now.day)) return false;
              } else if (_dueFilter == _DueFilter.upcoming) {
                if (t['status'] == 'COMPLETE') return false;
                final due = t['dueDate'];
                final d = due != null ? DateTime.tryParse(due.toString()) : null;
                if (d == null) return false;
                if (!(d.isAfter(now) && d.difference(now).inDays <= 7)) return false;
              }

              if (_selectedStatuses.isNotEmpty && !_selectedStatuses.contains(_effectiveStatus(t))) {
                return false;
              }
              if (_selectedPriorities.isNotEmpty && !_selectedPriorities.contains((t['priority'] ?? '').toString())) {
                return false;
              }
              if (_selectedTags.isNotEmpty) {
                final taskTags = List<String>.from(t['tags'] ?? const []);
                if (!taskTags.any(_selectedTags.contains)) return false;
              }
              if (_selectedAssigneeIds.isNotEmpty) {
                final id = _refId(t['assigneeId']);
                if (id == null || !_selectedAssigneeIds.contains(id)) return false;
              }
              if (_selectedProjectIds.isNotEmpty) {
                final id = _refId(t['projectId']);
                if (id == null || !_selectedProjectIds.contains(id)) return false;
              }
              if (_selectedSpaceIds.isNotEmpty) {
                final id = t['spaceId']?.toString();
                if (id == null || !_selectedSpaceIds.contains(id)) return false;
              }
              if (_dtrOnly && t['dtrFlag'] != true) return false;

              if (_noDueDateOnly) {
                if (t['dueDate'] != null) return false;
              } else if (_dueFrom != null || _dueTo != null) {
                final dueRaw = t['dueDate'];
                final due = dueRaw != null ? DateTime.tryParse(dueRaw.toString()) : null;
                if (due == null) return false;
                if (_dueFrom != null && due.isBefore(_dueFrom!)) return false;
                if (_dueTo != null && due.isAfter(_dueTo!.add(const Duration(days: 1)))) return false;
              }

              return true;
            }).toList();

            // Grouped by effective status in a fixed priority order --
            // still-open work first (TO DO, then IN PROGRESS, then
            // OVERDUE), completed work last (on-time COMPLETE, then
            // COMPLETE (LATE)) -- rather than just "incomplete vs.
            // complete", so e.g. an overdue task never gets buried among
            // plain in-progress ones. Each group renders as its own
            // collapsible section (tap the header to open/close it, same
            // arrow-toggle behavior for every group) -- every group header
            // always shows, with a "0" count when there's nothing in it,
            // so the full set of stages stays visible instead of the
            // section disappearing.
            final entries = <_TaskListEntry>[];
            for (final key in _statusOrder) {
              final group = tasks.where((t) => _effectiveStatus(t) == key).toList()..sort(_compareByDueDate);
              final label = _statusFacetOptions.firstWhere((o) => o.$1 == key, orElse: () => (key, key)).$2;
              entries.add(_TaskListEntry.header(key, label, group.length));
              if (group.isNotEmpty && !_collapsedGroups.contains(key)) {
                entries.addAll(group.map(_TaskListEntry.task));
              }
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Search tasks',
                            prefixIcon: const Icon(Icons.search_rounded, size: 20),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 18),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                      const SizedBox(width: Gap.sm),
                      // The "Filters" entry point -- everything past the
                      // search bar and due-date quick chips (Status,
                      // Priority, Assignee, Project, DTR, Due Date range,
                      // Tags) lives behind this one button, same shape as
                      // a mobile shopping app's filter icon with a badge
                      // showing how many facets are currently active.
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton.outlined(
                            onPressed: () => _openFilterSheet(
                              availableTags: availableTags,
                              availableAssignees: availableAssignees,
                              availableProjects: availableProjects,
                              availableSpaces: availableSpaces,
                            ),
                            icon: const Icon(Icons.tune_rounded),
                            tooltip: 'Filters',
                          ),
                          if (_activeFacetCount > 0)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(color: AppColors.indigo, shape: BoxShape.circle),
                                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                child: Text(
                                  '$_activeFacetCount',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _FilterChip(label: 'All', count: allTasks.length, selected: _dueFilter == _DueFilter.all, onTap: () => setState(() => _dueFilter = _DueFilter.all)),
                        const SizedBox(width: Gap.sm),
                        _FilterChip(label: 'Today', selected: _dueFilter == _DueFilter.today, onTap: () => setState(() => _dueFilter = _DueFilter.today)),
                        const SizedBox(width: Gap.sm),
                        _FilterChip(label: 'Upcoming 7 Days', selected: _dueFilter == _DueFilter.upcoming, onTap: () => setState(() => _dueFilter = _DueFilter.upcoming)),
                        const SizedBox(width: Gap.sm),
                        _FilterChip(label: 'Overdue', selected: _dueFilter == _DueFilter.overdue, onTap: () => setState(() => _dueFilter = _DueFilter.overdue)),
                        // Active facets surface here too, each
                        // individually removable with its own X -- same
                        // "chips echo the filter sheet's selections"
                        // pattern shopping apps use, so clearing one
                        // facet doesn't require reopening the whole sheet.
                        if (_activeFacetCount > 0) ...[
                          const SizedBox(width: Gap.md),
                          Container(width: 1, height: 20, color: AppColors.line),
                          const SizedBox(width: Gap.md),
                        ],
                        for (final s in _selectedStatuses) ...[
                          _RemovableChip(
                            label: _statusFacetOptions.firstWhere((o) => o.$1 == s, orElse: () => (s, s)).$2,
                            onRemoved: () => setState(() => _selectedStatuses = {..._selectedStatuses}..remove(s)),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        for (final p in _selectedPriorities) ...[
                          _RemovableChip(label: p, onRemoved: () => setState(() => _selectedPriorities = {..._selectedPriorities}..remove(p))),
                          const SizedBox(width: Gap.sm),
                        ],
                        for (final id in _selectedAssigneeIds) ...[
                          _RemovableChip(
                            label: availableAssignees[id] ?? 'Assignee',
                            onRemoved: () => setState(() => _selectedAssigneeIds = {..._selectedAssigneeIds}..remove(id)),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        for (final id in _selectedProjectIds) ...[
                          _RemovableChip(
                            label: availableProjects[id] ?? 'Project',
                            onRemoved: () => setState(() => _selectedProjectIds = {..._selectedProjectIds}..remove(id)),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        for (final id in _selectedSpaceIds) ...[
                          _RemovableChip(
                            label: availableSpaces[id] ?? 'Space',
                            onRemoved: () => setState(() => _selectedSpaceIds = {..._selectedSpaceIds}..remove(id)),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        if (_dtrOnly) ...[
                          _RemovableChip(label: 'DTR only', onRemoved: () => setState(() => _dtrOnly = false)),
                          const SizedBox(width: Gap.sm),
                        ],
                        if (_noDueDateOnly) ...[
                          _RemovableChip(label: 'No due date', onRemoved: () => setState(() => _noDueDateOnly = false)),
                          const SizedBox(width: Gap.sm),
                        ] else if (_dueFrom != null || _dueTo != null) ...[
                          _RemovableChip(
                            label: _dueRangeLabel(_dueFrom, _dueTo),
                            onRemoved: () => setState(() {
                              _dueFrom = null;
                              _dueTo = null;
                            }),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        for (final tag in _selectedTags) ...[
                          _RemovableChip(label: '#$tag', onRemoved: () => setState(() => _selectedTags = {..._selectedTags}..remove(tag))),
                          const SizedBox(width: Gap.sm),
                        ],
                        if (_activeFacetCount > 0)
                          TextButton(onPressed: _clearAllFacets, child: const Text('Clear all')),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? EmptyState(
                          icon: Icons.checklist_rounded,
                          title: 'No tasks here',
                          message: _query.isNotEmpty || _activeFacetCount > 0
                              ? 'Nothing matches your search/filters right now.'
                              : 'Nothing matches this filter right now.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final entry = entries[i];

                            if (entry.isHeader) {
                              final collapsed = _collapsedGroups.contains(entry.headerKey);
                              return Padding(
                                padding: EdgeInsets.only(top: i == 0 ? 0 : Gap.md, bottom: Gap.sm),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(AppRadius.field),
                                  onTap: () => setState(() {
                                    if (collapsed) {
                                      _collapsedGroups.remove(entry.headerKey);
                                    } else {
                                      _collapsedGroups.add(entry.headerKey!);
                                    }
                                  }),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                                    child: Row(
                                      children: [
                                        AnimatedRotation(
                                          turns: collapsed ? -0.25 : 0,
                                          duration: const Duration(milliseconds: 150),
                                          child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.inkMuted),
                                        ),
                                        const SizedBox(width: Gap.xs),
                                        // Flexible+ellipsis: the longest header label,
                                        // "DELEGATED (Awaiting Approval)", can overflow
                                        // the row on a narrow phone or a larger system
                                        // font-scale setting without this.
                                        Flexible(
                                          child: Text(
                                            entry.headerLabel!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                        const SizedBox(width: Gap.sm),
                                        Text(
                                          '${entry.headerCount}',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }

                            final t = entry.task!;
                            final due = t['dueDate'];
                            final spaceName = t['spaceName']?.toString();
                            final assigneeName = _refName(t['assigneeId'], 'employeeName');
                            final dueText = due != null ? 'Due ${due.toString().split('T').first}' : 'No due date';
                            // This screen now includes subordinates' tasks
                            // too (not just the viewer's own), so the
                            // assignee's name is shown alongside the due
                            // date/space -- otherwise there's no way to
                            // tell whose task a row belongs to.
                            final subtitleParts = [
                              dueText,
                              if (spaceName != null && spaceName.isNotEmpty) spaceName,
                              if (assigneeName != null && assigneeName.isNotEmpty) assigneeName,
                            ];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: Gap.sm),
                              child: EntityCard(
                                title: t['title'] ?? t['name'] ?? 'Untitled task',
                                status: _displayStatus(t),
                                leadingIcon: Icons.task_alt_rounded,
                                subtitle: subtitleParts.join(' · '),
                                onTap: () => context.push('/home/tasks/${t['_id']}'),
                              ),
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
      ),
    );
  }
}

String _dueRangeLabel(DateTime? from, DateTime? to) {
  String fmt(DateTime d) => '${d.day}/${d.month}';
  if (from != null && to != null) return '${fmt(from)}–${fmt(to)}';
  if (from != null) return 'From ${fmt(from)}';
  if (to != null) return 'Until ${fmt(to)}';
  return 'Due date';
}

class _FacetSelection {
  final Set<String> statuses;
  final Set<String> priorities;
  final Set<String> tags;
  final Set<String> assigneeIds;
  final Set<String> projectIds;
  final Set<String> spaceIds;
  final bool dtrOnly;
  final DateTime? dueFrom;
  final DateTime? dueTo;
  final bool noDueDateOnly;
  const _FacetSelection({
    required this.statuses,
    required this.priorities,
    required this.tags,
    required this.assigneeIds,
    required this.projectIds,
    required this.spaceIds,
    required this.dtrOnly,
    required this.dueFrom,
    required this.dueTo,
    required this.noDueDateOnly,
  });
}

/// Amazon-style filter sheet: independent facets, each multi-select,
/// combined with AND across facets and OR within one -- picking two Tags
/// shows tasks with either tag, but picking a Tag AND a Priority narrows
/// to tasks matching both. Local state here is only committed back to the
/// screen on "Show results" (or discarded on dismiss/Cancel), same as a
/// shopping app's filter sheet -- so browsing options doesn't affect the
/// list underneath until confirmed.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.availableTags,
    required this.availableAssignees,
    required this.availableProjects,
    required this.availableSpaces,
    required this.initialStatuses,
    required this.initialPriorities,
    required this.initialTags,
    required this.initialAssigneeIds,
    required this.initialProjectIds,
    required this.initialSpaceIds,
    required this.initialDtrOnly,
    required this.initialDueFrom,
    required this.initialDueTo,
    required this.initialNoDueDateOnly,
  });

  final List<String> availableTags;
  final Map<String, String> availableAssignees;
  final Map<String, String> availableProjects;
  final Map<String, String> availableSpaces;
  final Set<String> initialStatuses;
  final Set<String> initialPriorities;
  final Set<String> initialTags;
  final Set<String> initialAssigneeIds;
  final Set<String> initialProjectIds;
  final Set<String> initialSpaceIds;
  final bool initialDtrOnly;
  final DateTime? initialDueFrom;
  final DateTime? initialDueTo;
  final bool initialNoDueDateOnly;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<String> _statuses = {...widget.initialStatuses};
  late Set<String> _priorities = {...widget.initialPriorities};
  late Set<String> _tags = {...widget.initialTags};
  late Set<String> _assigneeIds = {...widget.initialAssigneeIds};
  late Set<String> _projectIds = {...widget.initialProjectIds};
  late Set<String> _spaceIds = {...widget.initialSpaceIds};
  late bool _dtrOnly = widget.initialDtrOnly;
  DateTime? _dueFrom;
  DateTime? _dueTo;
  late bool _noDueDateOnly = widget.initialNoDueDateOnly;

  @override
  void initState() {
    super.initState();
    _dueFrom = widget.initialDueFrom;
    _dueTo = widget.initialDueTo;
  }

  int get _count =>
      _statuses.length +
      _priorities.length +
      _tags.length +
      _assigneeIds.length +
      _projectIds.length +
      _spaceIds.length +
      (_dtrOnly ? 1 : 0) +
      (_dueFrom != null ? 1 : 0) +
      (_dueTo != null ? 1 : 0) +
      (_noDueDateOnly ? 1 : 0);

  Future<void> _pickDueFrom() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueFrom ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: _dueTo ?? DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _dueFrom = picked);
  }

  Future<void> _pickDueTo() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueTo ?? now,
      firstDate: _dueFrom ?? DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _dueTo = picked);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('Filters', style: Theme.of(context).textTheme.titleLarge)),
                    if (_count > 0)
                      TextButton(
                        onPressed: () => setState(() {
                          _statuses = {};
                          _priorities = {};
                          _tags = {};
                          _assigneeIds = {};
                          _projectIds = {};
                          _spaceIds = {};
                          _dtrOnly = false;
                          _dueFrom = null;
                          _dueTo = null;
                          _noDueDateOnly = false;
                        }),
                        child: const Text('Clear all'),
                      ),
                    IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              const Divider(height: Gap.lg),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                  children: [
                    _FacetSection(
                      title: 'Status',
                      child: Column(
                        children: [
                          for (final (key, label) in _statusFacetOptions)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              dense: true,
                              title: Text(label),
                              value: _statuses.contains(key),
                              onChanged: (v) => setState(() => v == true ? _statuses.add(key) : _statuses.remove(key)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    if (widget.availableSpaces.isNotEmpty) ...[
                      _FacetSection(
                        title: 'Space',
                        child: Column(
                          children: [
                            for (final entry in widget.availableSpaces.entries)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity: ListTileControlAffinity.leading,
                                dense: true,
                                title: Text(entry.value),
                                value: _spaceIds.contains(entry.key),
                                onChanged: (v) => setState(() => v == true ? _spaceIds.add(entry.key) : _spaceIds.remove(entry.key)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Gap.lg),
                    ],
                    _FacetSection(
                      title: 'Priority',
                      child: Column(
                        children: [
                          for (final p in _priorityOptions)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              dense: true,
                              title: Text(p),
                              value: _priorities.contains(p),
                              onChanged: (v) => setState(() => v == true ? _priorities.add(p) : _priorities.remove(p)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    _FacetSection(
                      title: 'Assignee',
                      child: widget.availableAssignees.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: Gap.md),
                              child: Text('No assignees on your tasks yet.', style: Theme.of(context).textTheme.bodyMedium),
                            )
                          : Column(
                              children: [
                                for (final entry in widget.availableAssignees.entries)
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    dense: true,
                                    title: Text(entry.value),
                                    value: _assigneeIds.contains(entry.key),
                                    onChanged: (v) => setState(() => v == true ? _assigneeIds.add(entry.key) : _assigneeIds.remove(entry.key)),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: Gap.lg),
                    _FacetSection(
                      title: 'Project',
                      child: widget.availableProjects.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: Gap.md),
                              child: Text('No projects on your tasks yet.', style: Theme.of(context).textTheme.bodyMedium),
                            )
                          : Column(
                              children: [
                                for (final entry in widget.availableProjects.entries)
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    dense: true,
                                    title: Text(entry.value),
                                    value: _projectIds.contains(entry.key),
                                    onChanged: (v) => setState(() => v == true ? _projectIds.add(entry.key) : _projectIds.remove(entry.key)),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: Gap.lg),
                    _FacetSection(
                      title: 'DTR',
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        title: const Text('DTR only'),
                        value: _dtrOnly,
                        onChanged: (v) => setState(() => _dtrOnly = v ?? false),
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    _FacetSection(
                      title: 'Due Date',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _DateField(
                                  label: 'From',
                                  value: _dueFrom,
                                  enabled: !_noDueDateOnly,
                                  onTap: _pickDueFrom,
                                  onClear: _dueFrom == null ? null : () => setState(() => _dueFrom = null),
                                ),
                              ),
                              const SizedBox(width: Gap.md),
                              Expanded(
                                child: _DateField(
                                  label: 'To',
                                  value: _dueTo,
                                  enabled: !_noDueDateOnly,
                                  onTap: _pickDueTo,
                                  onClear: _dueTo == null ? null : () => setState(() => _dueTo = null),
                                ),
                              ),
                            ],
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                            title: const Text('No due date set'),
                            value: _noDueDateOnly,
                            onChanged: (v) => setState(() {
                              _noDueDateOnly = v ?? false;
                              if (_noDueDateOnly) {
                                _dueFrom = null;
                                _dueTo = null;
                              }
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    _FacetSection(
                      title: 'Tags',
                      child: widget.availableTags.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: Gap.md),
                              child: Text(
                                'No tags on your tasks yet.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            )
                          : Wrap(
                              spacing: Gap.sm,
                              runSpacing: Gap.sm,
                              children: [
                                for (final tag in widget.availableTags)
                                  FilterChip(
                                    label: Text(tag),
                                    selected: _tags.contains(tag),
                                    onSelected: (v) => setState(() => v ? _tags.add(tag) : _tags.remove(tag)),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: Gap.xl),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      _FacetSelection(
                        statuses: _statuses,
                        priorities: _priorities,
                        tags: _tags,
                        assigneeIds: _assigneeIds,
                        projectIds: _projectIds,
                        spaceIds: _spaceIds,
                        dtrOnly: _dtrOnly,
                        dueFrom: _dueFrom,
                        dueTo: _dueTo,
                        noDueDateOnly: _noDueDateOnly,
                      ),
                    ),
                    child: Text(_count == 0 ? 'Show all results' : 'Show results ($_count filter${_count == 1 ? '' : 's'})'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.enabled, required this.onTap, this.onClear});

  final String label;
  final DateTime? value;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final text = value == null ? 'Not set' : '${value!.day}/${value!.month}/${value!.year}';
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: onClear != null && enabled
                ? IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: onClear)
                : const Icon(Icons.calendar_today_outlined, size: 16),
          ),
          child: Text(text, style: TextStyle(color: value == null ? AppColors.inkMuted : AppColors.ink)),
        ),
      ),
    );
  }
}

class _FacetSection extends StatelessWidget {
  const _FacetSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        child,
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({required this.label, this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(count != null ? '$label · $count' : label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.ink,
        fontWeight: FontWeight.w600,
      ),
      selectedColor: AppColors.indigo,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: selected ? AppColors.indigo : AppColors.line),
    );
  }
}

/// A selected-facet echo chip in the row above the list -- always
/// "selected" styling since its mere presence means it's active, with its
/// own X to drop just that one value without reopening the filter sheet.
class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.label, required this.onRemoved});

  final String label;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Text(label),
      labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      backgroundColor: AppColors.indigo,
      deleteIconColor: Colors.white,
      side: BorderSide.none,
      onDeleted: onRemoved,
    );
  }
}

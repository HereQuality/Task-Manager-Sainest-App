import 'package:flutter/material.dart';
import '../core/theme.dart';

/// A tappable field, styled like every other picker field in the Add/Edit
/// Task sheets, that opens a SEARCHABLE bottom sheet of employees instead
/// of a native DropdownButtonFormField's plain scrollable menu -- the
/// "Assign to" list is every active employee company-wide (see
/// assignableEmployeesProvider), which can run into dozens of names with
/// no way to jump straight to one by typing. Shared between
/// add_task_sheet.dart and edit_task_sheet.dart so both pickers look and
/// behave identically.
class SearchableEmployeeField extends StatelessWidget {
  final String label;
  final List<Map<String, dynamic>> employees;
  final String? value;
  final String? currentUserId;
  final ValueChanged<String?> onChanged;
  const SearchableEmployeeField({
    super.key,
    required this.label,
    required this.employees,
    required this.value,
    required this.onChanged,
    this.currentUserId,
  });

  String _displayName(Map<String, dynamic> e) =>
      e['_id'] == currentUserId ? 'Me' : (e['employeeName']?.toString() ?? 'Unnamed');

  @override
  Widget build(BuildContext context) {
    final selected = employees.where((e) => e['_id'] == value);
    final selectedName = selected.isNotEmpty ? _displayName(selected.first) : null;

    return InkWell(
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (ctx) => EmployeeSearchSheet(
            title: label,
            employees: employees,
            currentUserId: currentUserId,
            selectedId: value,
          ),
        );
        // A cancelled sheet (back button / tap outside) resolves the
        // Future with null, same as any other showModalBottomSheet<T> --
        // that must leave the current selection untouched. The sheet's own
        // "Clear selection" action instead resolves with the empty string
        // sentinel, which IS a real choice (explicitly unassign), so only
        // that case should call onChanged(null).
        if (picked == null) return;
        onChanged(picked.isEmpty ? null : picked);
      },
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value != null
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.search_rounded, size: 18),
        ),
        child: Text(
          selectedName ?? 'Not set',
          style: TextStyle(color: selectedName == null ? AppColors.inkMuted : AppColors.ink),
        ),
      ),
    );
  }
}

/// Multi-select sibling of SearchableEmployeeField above -- same tappable-
/// field-opens-a-searchable-sheet shape, but ticking several people is the
/// point: used by add_task_sheet.dart's "Assign to" when it's creating one
/// task per person rather than a single shared one (see showAddTaskSheet's
/// own doc comment on why that's a loop of separate createTaskInSpace +
/// assignTaskAndMoveSpace calls, one per id in `value`, instead of a
/// single task with several assignees -- this app's Task model only ever
/// has one assigneeId).
class MultiSearchableEmployeeField extends StatelessWidget {
  final String label;
  final List<Map<String, dynamic>> employees;
  final List<String> value;
  final String? currentUserId;
  final ValueChanged<List<String>> onChanged;
  const MultiSearchableEmployeeField({
    super.key,
    required this.label,
    required this.employees,
    required this.value,
    required this.onChanged,
    this.currentUserId,
  });

  String _displayName(Map<String, dynamic> e) =>
      e['_id'] == currentUserId ? 'Me' : (e['employeeName']?.toString() ?? 'Unnamed');

  @override
  Widget build(BuildContext context) {
    final selected = employees.where((e) => value.contains(e['_id']));
    final summary = value.isEmpty
        ? null
        : value.length == 1
            ? (selected.isNotEmpty ? _displayName(selected.first) : null)
            : '${value.length} people';

    return InkWell(
      onTap: () async {
        final picked = await showModalBottomSheet<List<String>>(
          context: context,
          isScrollControlled: true,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (ctx) => MultiEmployeeSearchSheet(
            title: label,
            employees: employees,
            currentUserId: currentUserId,
            selectedIds: value,
          ),
        );
        // Cancelled (back/tap-outside) resolves null and must leave the
        // current selection untouched -- "Done" is the only path that
        // ever resolves with a real (possibly empty, via Clear all) list.
        if (picked == null) return;
        onChanged(picked);
      },
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => onChanged(const []),
                )
              : const Icon(Icons.search_rounded, size: 18),
        ),
        child: Text(
          summary ?? 'Not set',
          style: TextStyle(color: summary == null ? AppColors.inkMuted : AppColors.ink),
        ),
      ),
    );
  }
}

class MultiEmployeeSearchSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> employees;
  final String? currentUserId;
  final List<String> selectedIds;
  const MultiEmployeeSearchSheet({
    super.key,
    required this.title,
    required this.employees,
    required this.currentUserId,
    required this.selectedIds,
  });

  @override
  State<MultiEmployeeSearchSheet> createState() => _MultiEmployeeSearchSheetState();
}

class _MultiEmployeeSearchSheetState extends State<MultiEmployeeSearchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  late List<String> _selected = [...widget.selectedIds];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _displayName(Map<String, dynamic> e) =>
      e['_id'] == widget.currentUserId ? 'Me' : (e['employeeName']?.toString() ?? 'Unnamed');

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.employees.where((e) => e['_id'] == widget.currentUserId);
    final others = widget.employees.where((e) => e['_id'] != widget.currentUserId);
    final sorted = [...me, ...others];

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty ? sorted : sorted.where((e) => _displayName(e).toLowerCase().contains(q)).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.xl,
        right: Gap.xl,
        top: Gap.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.xl,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Done'),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search employees',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            if (_selected.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _selected = []),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text('Clear selection (${_selected.length})'),
                ),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        q.isEmpty ? 'No employees found.' : 'No employees match "$_query".',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final e = filtered[i];
                        final id = e['_id'] as String;
                        final isSelected = _selected.contains(id);
                        return CheckboxListTile(
                          value: isSelected,
                          onChanged: (_) => _toggle(id),
                          title: Text(_displayName(e)),
                          controlAffinity: ListTileControlAffinity.leading,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class EmployeeSearchSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> employees;
  final String? currentUserId;
  final String? selectedId;
  const EmployeeSearchSheet({
    super.key,
    required this.title,
    required this.employees,
    required this.currentUserId,
    required this.selectedId,
  });

  @override
  State<EmployeeSearchSheet> createState() => EmployeeSearchSheetState();
}

class EmployeeSearchSheetState extends State<EmployeeSearchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _displayName(Map<String, dynamic> e) =>
      e['_id'] == widget.currentUserId ? 'Me' : (e['employeeName']?.toString() ?? 'Unnamed');

  @override
  Widget build(BuildContext context) {
    // The signed-in person sorts to the top of their own list, labeled
    // "Me" -- assigning a task to yourself is the most common pick, so it
    // shouldn't be buried wherever their real name happens to fall
    // alphabetically. Split-then-concatenate (not a comparator) keeps
    // everyone else in whatever order the caller already sorted them in.
    final me = widget.employees.where((e) => e['_id'] == widget.currentUserId);
    final others = widget.employees.where((e) => e['_id'] != widget.currentUserId);
    final sorted = [...me, ...others];

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty ? sorted : sorted.where((e) => _displayName(e).toLowerCase().contains(q)).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.xl,
        right: Gap.xl,
        top: Gap.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.xl,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search employees',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            if (widget.selectedId != null) ...[
              const SizedBox(height: Gap.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context, ''),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Clear selection'),
                ),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        q.isEmpty ? 'No employees found.' : 'No employees match "$_query".',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final e = filtered[i];
                        final id = e['_id'] as String;
                        final isSelected = id == widget.selectedId;
                        return ListTile(
                          title: Text(_displayName(e)),
                          trailing: isSelected ? const Icon(Icons.check_rounded, color: AppColors.indigo) : null,
                          onTap: () => Navigator.pop(context, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

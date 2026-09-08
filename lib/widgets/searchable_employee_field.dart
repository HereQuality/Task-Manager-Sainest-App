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
          builder: (ctx) => _EmployeeSearchSheet(
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

class _EmployeeSearchSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> employees;
  final String? currentUserId;
  final String? selectedId;
  const _EmployeeSearchSheet({
    required this.title,
    required this.employees,
    required this.currentUserId,
    required this.selectedId,
  });

  @override
  State<_EmployeeSearchSheet> createState() => _EmployeeSearchSheetState();
}

class _EmployeeSearchSheetState extends State<_EmployeeSearchSheet> {
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';

/// Task detail's Checklists panel -- mirrors Task.js's own doc comment:
/// the whole `checklists` array is replaced on every change (add/toggle/
/// delete an item or a checklist), same "send it all back" pattern as
/// `tags`, rather than dedicated per-item endpoints.
class TaskChecklistSection extends ConsumerStatefulWidget {
  final String taskId;
  final List<dynamic> checklists;
  const TaskChecklistSection({super.key, required this.taskId, required this.checklists});

  @override
  ConsumerState<TaskChecklistSection> createState() => _TaskChecklistSectionState();
}

class _TaskChecklistSectionState extends ConsumerState<TaskChecklistSection> {
  final _newChecklistCtrl = TextEditingController();
  // Keyed by checklist id so each checklist's own "add item" field keeps
  // its controller across rebuilds (checklist ids are stable; a fresh
  // controller per build would lose whatever the person was mid-typing).
  final Map<String, TextEditingController> _newItemCtrls = {};
  bool _saving = false;

  @override
  void dispose() {
    _newChecklistCtrl.dispose();
    for (final c in _newItemCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _itemCtrlFor(String checklistId) => _newItemCtrls.putIfAbsent(checklistId, () => TextEditingController());

  List<Map<String, dynamic>> _asList() => widget.checklists.map((c) => Map<String, dynamic>.from(c as Map)).toList();

  Future<void> _save(List<Map<String, dynamic>> updated) async {
    setState(() => _saving = true);
    try {
      await updateTaskChecklists(widget.taskId, updated);
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the checklist.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addChecklist() {
    final title = _newChecklistCtrl.text.trim();
    if (title.isEmpty) return;
    final updated = _asList()
      ..add({
        '_id': DateTime.now().microsecondsSinceEpoch.toString(),
        'title': title,
        'items': <Map<String, dynamic>>[],
      });
    _newChecklistCtrl.clear();
    _save(updated);
  }

  void _deleteChecklist(String checklistId) {
    _save(_asList()..removeWhere((c) => c['_id'].toString() == checklistId));
  }

  void _addItem(String checklistId) {
    final ctrl = _itemCtrlFor(checklistId);
    final text = ctrl.text.trim();
    if (text.isEmpty) return;
    final updated = _asList();
    final target = updated.firstWhere((c) => c['_id'].toString() == checklistId);
    final items = List<Map<String, dynamic>>.from(target['items'] ?? []);
    items.add({'_id': DateTime.now().microsecondsSinceEpoch.toString(), 'text': text, 'checked': false});
    target['items'] = items;
    ctrl.clear();
    _save(updated);
  }

  void _toggleItem(String checklistId, String itemId, bool checked) {
    final updated = _asList();
    final target = updated.firstWhere((c) => c['_id'].toString() == checklistId);
    final items = List<Map<String, dynamic>>.from(target['items'] ?? []);
    final item = items.firstWhere((i) => i['_id'].toString() == itemId);
    item['checked'] = checked;
    target['items'] = items;
    _save(updated);
  }

  void _deleteItem(String checklistId, String itemId) {
    final updated = _asList();
    final target = updated.firstWhere((c) => c['_id'].toString() == checklistId);
    final items = List<Map<String, dynamic>>.from(target['items'] ?? [])..removeWhere((i) => i['_id'].toString() == itemId);
    target['items'] = items;
    _save(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Checklists', style: Theme.of(context).textTheme.titleMedium)),
            if (_saving)
              const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: Gap.sm),
        for (final raw in widget.checklists)
          _ChecklistCard(
            checklist: Map<String, dynamic>.from(raw as Map),
            itemController: _itemCtrlFor((raw['_id'] ?? '').toString()),
            onToggleItem: (itemId, checked) => _toggleItem(raw['_id'].toString(), itemId, checked),
            onDeleteItem: (itemId) => _deleteItem(raw['_id'].toString(), itemId),
            onAddItem: () => _addItem(raw['_id'].toString()),
            onDeleteChecklist: () => _deleteChecklist(raw['_id'].toString()),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newChecklistCtrl,
                decoration: const InputDecoration(labelText: 'New checklist'),
                onSubmitted: (_) => _addChecklist(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_rounded, color: AppColors.indigo),
              onPressed: _addChecklist,
            ),
          ],
        ),
      ],
    );
  }
}

class _ChecklistCard extends StatelessWidget {
  final Map<String, dynamic> checklist;
  final TextEditingController itemController;
  final void Function(String itemId, bool checked) onToggleItem;
  final void Function(String itemId) onDeleteItem;
  final VoidCallback onAddItem;
  final VoidCallback onDeleteChecklist;

  const _ChecklistCard({
    required this.checklist,
    required this.itemController,
    required this.onToggleItem,
    required this.onDeleteItem,
    required this.onAddItem,
    required this.onDeleteChecklist,
  });

  @override
  Widget build(BuildContext context) {
    final items = List<Map<String, dynamic>>.from(checklist['items'] ?? []);
    final done = items.where((i) => i['checked'] == true).length;

    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${checklist['title']} ($done/${items.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.inkMuted),
                onPressed: onDeleteChecklist,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          for (final item in items)
            Row(
              children: [
                Checkbox(
                  value: item['checked'] == true,
                  onChanged: (v) => onToggleItem(item['_id'].toString(), v ?? false),
                  activeColor: AppColors.indigo,
                ),
                Expanded(
                  child: Text(
                    item['text']?.toString() ?? '',
                    style: TextStyle(
                      decoration: item['checked'] == true ? TextDecoration.lineThrough : null,
                      color: item['checked'] == true ? AppColors.inkMuted : AppColors.ink,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.inkMuted),
                  onPressed: () => onDeleteItem(item['_id'].toString()),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: itemController,
                  decoration: const InputDecoration(hintText: 'Add item', isDense: true, border: InputBorder.none),
                  onSubmitted: (_) => onAddItem(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded, size: 18, color: AppColors.indigo),
                onPressed: onAddItem,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

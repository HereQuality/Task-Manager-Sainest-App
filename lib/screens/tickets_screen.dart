import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../core/theme.dart';
import '../providers/tickets_provider.dart';
import '../widgets/status_pill.dart';
import '../widgets/empty_state.dart';

/// Support > "New ticket" -- mirrors NewTicketModal.jsx on the web: subject,
/// platform, priority, and description are all required by the server (see
/// createTicket in ticket.controller.js); the screenshot is optional.
class TicketsScreen extends ConsumerWidget {
  const TicketsScreen({super.key});

  Future<void> _openCreateSheet(BuildContext context, WidgetRef ref) async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => const _NewTicketSheet(),
    );

    if (submitted == true) {
      ref.invalidate(ticketsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ticket submitted')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticketsAsync = ref.watch(ticketsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Support tickets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreateSheet(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New ticket'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(ticketsProvider),
        child: ticketsAsync.when(
          data: (tickets) => tickets.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 60),
                  EmptyState(
                    icon: Icons.confirmation_number_outlined,
                    title: 'No tickets yet',
                    message: 'Raise one with the button below if something needs attention.',
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 90),
                  itemCount: tickets.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (context, i) => _TicketCard(ticket: tickets[i]),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(message: '$e', onRetry: () => ref.invalidate(ticketsProvider)),
        ),
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  final Map<String, dynamic> ticket;
  const _TicketCard({required this.ticket});

  @override
  Widget build(BuildContext context) {
    final id = ticket['_id']?.toString();
    final status = ticket['status']?.toString() ?? 'Pending';
    final subject = ticket['subject']?.toString() ?? 'Untitled ticket';
    final description = ticket['description']?.toString();
    final platform = ticket['platform']?.toString();
    final priority = ticket['priority']?.toString();
    final escalated = ticket['escalatedToAdmin'] == true;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: id == null ? null : () => context.push('/home/tickets/$id'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                  ),
                  const SizedBox(width: Gap.sm),
                  StatusPill(status: status),
                ],
              ),
              if (description != null && description.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
              ],
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: [
                  if (platform != null) _Chip(icon: platform == 'App' ? Icons.smartphone_rounded : Icons.language_rounded, label: platform),
                  if (priority != null) _Chip(icon: Icons.flag_outlined, label: priority, style: StatusStyle.of(priority)),
                  if (escalated) const _Chip(icon: Icons.arrow_upward_rounded, label: 'Escalated'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final StatusStyle? style;
  const _Chip({required this.icon, required this.label, this.style});

  @override
  Widget build(BuildContext context) {
    final s = style ?? const StatusStyle(AppColors.inkMuted, AppColors.neutralSoft);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
      decoration: BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: s.fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: s.fg, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _NewTicketSheet extends StatefulWidget {
  const _NewTicketSheet();

  @override
  State<_NewTicketSheet> createState() => _NewTicketSheetState();
}

class _NewTicketSheetState extends State<_NewTicketSheet> {
  final _subjectCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  // Raised from the phone app, so this always reports "App" -- same idea
  // as the web modal defaulting to "Web", just without a picker for
  // something the client already knows.
  final String _platform = 'App';
  String? _priority;
  File? _screenshot;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickScreenshot() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) setState(() => _screenshot = File(picked.path));
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    final description = _descCtrl.text.trim();
    if (subject.isEmpty || _priority == null || description.isEmpty) {
      setState(() => _error = 'Subject, priority, and description are required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await createTicket(
        subject: subject,
        platform: _platform,
        priority: _priority!,
        description: description,
        screenshotPath: _screenshot?.path,
      );
      if (mounted) Navigator.pop(context, true);
    } on DioException catch (e) {
      // Surfaces the server's actual reason (e.g. "Subject, platform,
      // priority, and description are required.") instead of a generic
      // message -- createTicket's required fields are enforced
      // server-side too, and a silent 400 here previously left no clue
      // which one failed.
      final serverMessage = e.response?.data is Map ? (e.response?.data as Map)['message']?.toString() : null;
      if (mounted) {
        setState(() => _error = serverMessage ?? 'Could not reach the server. Check your connection and try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not submit this ticket. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.xl, right: Gap.xl, top: Gap.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New support ticket', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(controller: _subjectCtrl, decoration: const InputDecoration(labelText: 'Subject')),
            const SizedBox(height: Gap.md),

            Text('Priority', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              children: kTicketPriorities.map((p) {
                final selected = p == _priority;
                return ChoiceChip(
                  label: Text(p),
                  selected: selected,
                  onSelected: (_) => setState(() => _priority = p),
                  selectedColor: AppColors.indigo,
                  labelStyle: TextStyle(color: selected ? Colors.white : AppColors.ink, fontWeight: FontWeight.w600),
                  backgroundColor: AppColors.neutralSoft,
                );
              }).toList(),
            ),
            const SizedBox(height: Gap.md),

            TextField(
              controller: _descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'What went wrong?'),
            ),
            const SizedBox(height: Gap.md),

            OutlinedButton.icon(
              onPressed: _pickScreenshot,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(_screenshot == null ? 'Attach a screenshot (optional)' : 'Screenshot attached'),
            ),
            if (_screenshot != null) ...[
              const SizedBox(height: Gap.sm),
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.field),
                    child: Image.file(_screenshot!, height: 140, width: double.infinity, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filled(
                      onPressed: () => setState(() => _screenshot = null),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      style: IconButton.styleFrom(backgroundColor: Colors.black54, minimumSize: const Size(28, 28)),
                    ),
                  ),
                ],
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: Gap.md),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],

            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Submit ticket'),
            ),
          ],
        ),
      ),
    );
  }
}

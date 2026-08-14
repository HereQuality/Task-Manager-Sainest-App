import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/tickets_provider.dart';
import '../widgets/status_pill.dart';
import '../widgets/empty_state.dart';

/// Mirrors TicketDetailModal.jsx on the web: the ticket's own
/// description(+screenshot) renders as the first message in a chat
/// thread, followed by every comment. Management actions (status,
/// Ask Confirmation, Forward to Admin) only show for someone who ISN'T
/// the raiser -- ticketsProvider's GET /tickets already only returns
/// other people's tickets to someone holding the Support desk's Full
/// Access role or a SuperAdmin (see getAllTickets in
/// ticket.controller.js), so "this ticket isn't mine" is a reliable
/// client-side stand-in for that role check; the server re-checks it
/// on every write regardless.
class TicketDetailScreen extends ConsumerStatefulWidget {
  final String ticketId;
  const TicketDetailScreen({super.key, required this.ticketId});

  @override
  ConsumerState<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends ConsumerState<TicketDetailScreen> {
  final _commentCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? successMessage}) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(ticketDetailProvider(widget.ticketId));
      ref.invalidate(ticketsProvider);
      if (mounted && successMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That action could not be completed.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendComment() async {
    final message = _commentCtrl.text.trim();
    if (message.isEmpty) return;
    _commentCtrl.clear();
    await _run(() => addTicketComment(widget.ticketId, message));
  }

  @override
  Widget build(BuildContext context) {
    final ticketAsync = ref.watch(ticketDetailProvider(widget.ticketId));
    final currentUserId = ref.watch(authProvider).user?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Ticket')),
      body: ticketAsync.when(
        data: (t) {
          final status = t['status']?.toString() ?? 'Pending';
          final subject = t['subject']?.toString() ?? 'Untitled ticket';
          final description = t['description']?.toString() ?? '';
          final screenshot = t['screenshot']?.toString();
          final platform = t['platform']?.toString();
          final priority = t['priority']?.toString();
          final escalated = t['escalatedToAdmin'] == true;
          final raisedBy = t['raisedBy'] is Map ? t['raisedBy'] as Map : null;
          final raiserId = raisedBy?['_id']?.toString();
          final isOwner = raiserId != null && raiserId == currentUserId;
          // "Me" instead of the logged-in person's own name, same
          // shorthand used elsewhere in the app.
          final raiserName = isOwner ? 'Me' : (raisedBy?['employeeName']?.toString() ?? 'Someone');
          // A ticket that showed up here despite not being this person's
          // own is only possible if the server already decided they can
          // manage it -- see the class doc above.
          final canManage = !isOwner;
          final comments = (t['comments'] as List?) ?? [];
          final dateFmt = DateFormat('dd/MM/yyyy, h:mm a');

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(subject, style: Theme.of(context).textTheme.headlineSmall)),
                        const SizedBox(width: Gap.sm),
                        StatusPill(status: status),
                      ],
                    ),
                    const SizedBox(height: Gap.xs),
                    Wrap(
                      spacing: Gap.xs,
                      runSpacing: Gap.xs,
                      children: [
                        if (platform != null) _tag(platform),
                        if (priority != null) _tag(priority),
                        if (escalated) _tag('Escalated to Admin'),
                        _tag('Raised by $raiserName'),
                      ],
                    ),
                    const SizedBox(height: Gap.lg),

                    _MessageBubble(author: raiserName, time: t['createdAt']?.toString(), dateFmt: dateFmt, message: description, imageUrl: screenshot),
                    for (final c in comments)
                      _MessageBubble(
                        author: (c['authorName'] ?? 'Unknown').toString(),
                        time: c['createdAt']?.toString(),
                        dateFmt: dateFmt,
                        message: (c['message'] ?? '').toString(),
                        isSystem: c['isSystem'] == true,
                      ),

                    if (canManage && status != 'Closed') ...[
                      const SizedBox(height: Gap.lg),
                      Text('Manage', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Gap.sm),
                      Wrap(
                        spacing: Gap.sm,
                        runSpacing: Gap.sm,
                        children: [
                          for (final s in kTicketStatuses)
                            if (s != status)
                              OutlinedButton(
                                onPressed: _busy ? null : () => _run(() => updateTicketStatus(widget.ticketId, s)),
                                child: Text('Mark $s'),
                              ),
                          if (status != 'Confirmation')
                            FilledButton(
                              onPressed: _busy ? null : () => _run(() => askTicketConfirmation(widget.ticketId), successMessage: 'Asked the raiser to confirm.'),
                              child: const Text('Ask Confirmation'),
                            ),
                          if (!escalated)
                            OutlinedButton(
                              onPressed: _busy ? null : () => _run(() => forwardTicketToAdmin(widget.ticketId), successMessage: 'Forwarded to Admin.'),
                              child: const Text('Forward to Admin'),
                            ),
                        ],
                      ),
                    ],

                    if (isOwner && status == 'Confirmation') ...[
                      const SizedBox(height: Gap.lg),
                      Text('This has been marked resolved -- is it fixed?', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Gap.sm),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy ? null : () => _run(() => confirmTicketResolution(widget.ticketId, true), successMessage: 'Ticket closed.'),
                              child: const Text('Accept & Close'),
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy ? null : () => _run(() => confirmTicketResolution(widget.ticketId, false), successMessage: 'Reopened.'),
                              child: const Text('Not Resolved'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (status != 'Closed')
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentCtrl,
                            decoration: const InputDecoration(labelText: 'Write a reply...'),
                            minLines: 1,
                            maxLines: 4,
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        IconButton.filled(
                          onPressed: _busy ? null : _sendComment,
                          icon: const Icon(Icons.send_rounded, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: 'Could not load this ticket.',
          onRetry: () => ref.invalidate(ticketDetailProvider(widget.ticketId)),
        ),
      ),
    );
  }

  Widget _tag(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
        decoration: BoxDecoration(color: AppColors.neutralSoft, borderRadius: BorderRadius.circular(AppRadius.chip)),
        child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.inkMuted)),
      );
}

class _MessageBubble extends StatelessWidget {
  final String author;
  final String? time;
  final DateFormat dateFmt;
  final String message;
  final String? imageUrl;
  final bool isSystem;
  const _MessageBubble({
    required this.author,
    required this.time,
    required this.dateFmt,
    required this.message,
    this.imageUrl,
    this.isSystem = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Center(
          child: Text(message, style: const TextStyle(color: AppColors.inkMuted, fontSize: 12, fontStyle: FontStyle.italic)),
        ),
      );
    }
    final parsed = time == null ? null : DateTime.tryParse(time!)?.toLocal();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.field), border: Border.all(color: AppColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(author, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink))),
              if (parsed != null) Text(dateFmt.format(parsed), style: const TextStyle(fontSize: 11, color: AppColors.inkMuted)),
            ],
          ),
          if (message.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink)),
          ],
          if (imageUrl != null && imageUrl!.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.field),
              child: Image.network(imageUrl!, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }
}

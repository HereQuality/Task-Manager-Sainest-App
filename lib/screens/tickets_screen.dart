import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../providers/tickets_provider.dart';
import '../widgets/entity_card.dart';
import '../widgets/empty_state.dart';

class TicketsScreen extends ConsumerWidget {
  const TicketsScreen({super.key});

  Future<void> _openCreateSheet(BuildContext context, WidgetRef ref) async {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: Gap.xl, right: Gap.xl, top: Gap.xl,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New support ticket', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: Gap.md),
              TextField(
                controller: descCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'What went wrong?'),
              ),
              const SizedBox(height: Gap.xl),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Submit ticket'),
              ),
            ],
          ),
        );
      },
    );

    if (submitted == true && titleCtrl.text.trim().isNotEmpty) {
      await createTicket(title: titleCtrl.text.trim(), description: descCtrl.text.trim());
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
                  itemBuilder: (context, i) {
                    final t = tickets[i];
                    return EntityCard(
                      title: t['title'] ?? 'Untitled ticket',
                      status: t['status'] ?? 'open',
                      leadingIcon: Icons.confirmation_number_outlined,
                      subtitle: t['description'],
                    );
                  },
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(message: '$e', onRetry: () => ref.invalidate(ticketsProvider)),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text("You'll need to sign in again to access your tasks and tickets."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger, minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final initial = (user != null && user.name.isNotEmpty) ? user.name[0].toUpperCase() : '?';

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(color: AppColors.indigo, shape: BoxShape.circle),
                  child: Center(
                    child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(height: Gap.md),
                Text(user?.name ?? '', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(user?.email ?? '', style: Theme.of(context).textTheme.bodyMedium),
                if (user?.roleName != null) ...[
                  const SizedBox(height: Gap.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 5),
                    decoration: BoxDecoration(color: AppColors.indigoSoft, borderRadius: BorderRadius.circular(AppRadius.chip)),
                    child: Text(user!.roleName!, style: const TextStyle(color: AppColors.indigo, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Gap.xxl),
          Card(
            child: Column(
              children: [
                _MenuTile(
                  icon: Icons.notifications_none_rounded,
                  label: 'Notifications',
                  onTap: () => context.push('/home/notifications'),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _MenuTile(
                  icon: Icons.tune_rounded,
                  label: 'Notification settings',
                  onTap: () => context.push('/home/settings'),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _MenuTile(
                  icon: Icons.confirmation_number_outlined,
                  label: 'Support tickets',
                  onTap: () => context.push('/home/tickets'),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _MenuTile(
                  icon: Icons.fact_check_outlined,
                  label: 'Pending Approvals',
                  onTap: () => context.push('/home/pending-approvals'),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _MenuTile(
                  icon: Icons.hourglass_empty_rounded,
                  label: 'Awaiting Approval',
                  onTap: () => context.push('/home/awaiting-approval'),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.xl),
          OutlinedButton.icon(
            onPressed: () => _confirmLogout(context, ref),
            icon: const Icon(Icons.logout_rounded, color: AppColors.danger, size: 18),
            label: const Text('Log out', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: const BorderSide(color: AppColors.line),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MenuTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: AppColors.neutralSoft, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 18, color: AppColors.ink),
      ),
      title: Text(label, style: Theme.of(context).textTheme.titleMedium),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.inkMuted),
    );
  }
}

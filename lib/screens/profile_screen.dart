import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  // Guards against a second tap firing a second, concurrent logout() call.
  // Without this (and the spinner it also gates below), the Log out
  // button gave no feedback at all while logout() ran -- on iOS in
  // particular, PushService.unregisterCurrentToken() inside logout() can
  // take several seconds (it waits on the device's APNs token), so the
  // button looked dead and people tapped it again, sometimes 2-3 times,
  // each tap starting its own overlapping logout() call.
  bool _loggingOut = false;

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    if (_loggingOut) return;
    // Captured synchronously, right here, before any await -- the
    // AuthNotifier itself lives in the app-wide ProviderScope, not tied
    // to this screen's lifecycle, so it stays perfectly valid to call
    // even if ProfileScreen gets unmounted later (a concurrent session
    // expiry, or any navigation away while the dialog below was still
    // open). Calling ref.read(...) again AFTER an await, gated on
    // `mounted`, would instead skip logout() entirely whenever that
    // happened -- someone who explicitly confirmed "Log out" would end up
    // still logged in with no error shown.
    final authNotifier = ref.read(authProvider.notifier);
    // Set BEFORE showDialog, not after it resolves -- showDialog's modal
    // barrier blocks a second tap once its route has actually been pushed,
    // but two taps landing in the same frame (a fast double-tap, or a
    // device occasionally delivering a duplicate pointer event) can both
    // pass the `if (_loggingOut) return;` guard above and each call
    // showDialog before either route exists yet, opening two overlapping
    // confirmation dialogs -- and, if both get confirmed, the exact
    // concurrent-logout() race this flag exists to prevent. Reset below
    // if the person cancels, since only an actual logout() call should
    // keep the button disabled.
    setState(() => _loggingOut = true);
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
    if (confirmed != true) {
      if (mounted) setState(() => _loggingOut = false);
      return;
    }
    try {
      await authNotifier.logout();
    } catch (_) {
      // logout() itself isn't documented to throw, but it awaits
      // several platform-channel/secure-storage calls (clearToken,
      // clearRememberMe) that CAN -- see api_client.dart's own
      // doc comment on flutter_secure_storage's KeyStore failures on
      // some Android devices. Without this catch, that exception would
      // propagate straight out of this async callback uncaught and the
      // `finally` below would be the only thing left to reset
      // _loggingOut, which is the actual fix -- this catch just stops
      // the exception from surfacing as an unhandled error too.
    } finally {
      // No need to reset _loggingOut on success -- a successful logout
      // tears this whole screen down via the router's redirect to /login,
      // so by the time this runs `mounted` is already false and this is
      // a no-op. Only matters on the (rare) chance logout() throws, so
      // the button doesn't stay stuck disabled forever.
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _loggingOut ? null : () => _confirmLogout(context, ref),
            icon: _loggingOut
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.danger),
                  )
                : const Icon(Icons.logout_rounded, color: AppColors.danger, size: 18),
            label: Text(
              _loggingOut ? 'Logging out…' : 'Log out',
              style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
            ),
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

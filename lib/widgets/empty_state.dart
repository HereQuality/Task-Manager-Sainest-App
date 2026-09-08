import 'package:flutter/material.dart';
import '../core/theme.dart';

/// An empty screen is an invitation to act, not a dead end — every empty
/// state here says plainly what's missing and, where relevant, what to do
/// about it.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const EmptyState({super.key, required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    // A plain Center can't shrink its child, so on a short available
    // height -- a small phone, a large system font-scale setting, or (as
    // on the Calendar screen) just less room left after other content --
    // this would overflow instead of adjusting. LayoutBuilder +
    // SingleChildScrollView + a minHeight-constrained box keeps the same
    // centered look when everything fits, but scrolls instead of
    // overflowing when it doesn't (same pattern alarm_screen.dart uses).
    //
    // Some callers (dashboard/tickets/notifications screens) place this
    // directly as a ListView child instead of behind Expanded/a Scaffold
    // body, which hands LayoutBuilder an unbounded maxHeight -- forcing
    // minHeight to that would build an invalid infinite-height
    // BoxConstraints and crash performLayout. Falling back to 0 there just
    // means the content sizes to itself instead of centering in unused
    // space, which doesn't apply when there's no bound to center within.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(color: AppColors.neutralSoft, shape: BoxShape.circle),
                    child: Icon(icon, color: AppColors.inkMuted, size: 28),
                  ),
                  const SizedBox(height: Gap.lg),
                  Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                  const SizedBox(height: Gap.xs),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Same overflow fix as EmptyState above -- see its doc comment.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off_rounded, color: AppColors.danger, size: 32),
                  const SizedBox(height: Gap.md),
                  Text("Couldn't load this", style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  Text(message, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
                  if (onRetry != null) ...[
                    const SizedBox(height: Gap.lg),
                    OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

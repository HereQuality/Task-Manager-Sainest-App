import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../core/notification_service.dart';
import '../core/theme.dart';

/// The full-screen "ringing" view for a task reminder -- reached when the
/// alarm notification's full-screen intent fires (device locked or
/// screen off) or is tapped (device unlocked), via router.dart's redirect
/// watching NotificationService's pendingAlarmNotifier. Deliberately its
/// own top-of-stack screen rather than a dialog: an alarm should be hard
/// to miss and hard to accidentally dismiss with a stray tap.
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key});

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> with SingleTickerProviderStateMixin {
  late final String _taskId;
  late final String _taskName;
  late final String _spaceName;
  bool _busy = false;

  late final AnimationController _pulseController;
  late final Timer _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    final data = pendingAlarmNotifier.value ?? const <String, dynamic>{};
    _taskId = (data['taskId'] ?? '').toString();
    _taskName = (data['taskName'] ?? 'Task').toString();
    _spaceName = (data['spaceName'] ?? '').toString();
    // Consumed -- clears the router's redirect trigger so leaving this
    // screen (Snooze/End) doesn't immediately bounce straight back into
    // it. Deferred to after this frame:
    // clearing it synchronously here notifies the router's
    // refreshListenable WHILE this very widget is still being built as
    // part of that same redirect, which crashes with "setState() or
    // markNeedsBuild() called during build" (a router rebuild triggered
    // from inside a widget's own initState, mid-build, is never legal).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pendingAlarmNotifier.value = null;
      // Defensive: if this screen was somehow reached with no task id
      // (a malformed/stale trigger), Snooze and End both silently no-op
      // on an empty id (see below) and the back gesture is blocked by
      // PopScope(canPop: false) -- leaving no way off this screen at
      // all, which reads as the app having crashed/frozen. Bouncing
      // straight back to Home is strictly better than a full-screen red
      // alarm nobody can dismiss.
      if (_taskId.isEmpty && mounted) context.go('/home');
    });

    // Slow, looping ring pulse behind the alarm icon -- purely decorative,
    // but it's what reads as "actively ringing" rather than a static error
    // screen at a glance, same cue a real alarm clock's flashing display
    // gives.
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
    // A live clock is what makes this feel like an actual alarm clock face
    // instead of a generic error dialog -- ticks once a second, cheap
    // enough not to matter next to the pulse animation already rebuilding
    // every frame.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _clockTimer.cancel();
    super.dispose();
  }

  static const _snoozeOptions = [
    ('1 min', Duration(minutes: 1)),
    ('10 min', Duration(minutes: 10)),
    ('1 hour', Duration(hours: 1)),
    ('2 hours', Duration(hours: 2)),
  ];

  Future<void> _pickSnoozeDuration() async {
    if (_taskId.isEmpty || _busy) return;
    final chosen = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: const Color(0xFF7A1030),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Gap.sm),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: Text(
                'SNOOZE FOR',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 12),
              ),
            ),
            for (final option in _snoozeOptions)
              ListTile(
                leading: const Icon(Icons.snooze_rounded, color: Colors.white70),
                title: Text(
                  option.$1,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17),
                ),
                onTap: () => Navigator.of(sheetContext).pop(option.$2),
              ),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
    if (chosen != null) await _snooze(chosen);
  }

  Future<void> _snooze(Duration duration) async {
    if (_taskId.isEmpty || _busy || !mounted) return;
    setState(() => _busy = true);
    try {
      // Unlike cancelOverdueAlarm below (best-effort -- its own internals
      // swallow every error), this can genuinely throw: scheduleOverdueAlarmAt
      // deliberately rethrows a failed zonedSchedule call (see its own doc
      // comment) so a caller that cares can tell "scheduled" apart from
      // "silently didn't". Without this try/catch, that exception used to
      // propagate straight out of this async callback uncaught -- _busy
      // stayed true forever (nothing below it ever ran to reset it) and
      // every button on this screen (Snooze/End are both gated on _busy)
      // went dead, trapping the person on a still-ringing alarm with no
      // way off it.
      await NotificationService.instance.snoozeOverdueAlarm(
        taskId: _taskId,
        taskName: _taskName,
        spaceName: _spaceName,
        duration: duration,
      );
      if (mounted) context.go('/home');
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not snooze this alarm — try again.')));
      }
    }
  }

  // "End" -- silences this ringing/pending alarm without marking the task
  // complete. Just cancels whatever alarm is currently scheduled for it
  // (the one that just rang, or a snooze that hadn't fired yet); it
  // deliberately does NOT touch the task's status, so an overdue task
  // stays overdue in the task list same as before. Since the task was
  // already recorded in the "alerted" set the moment this alarm first
  // fired (see background_watcher_service.dart/notifications_provider.dart's
  // shared alertedIds tracking), it won't ring again on its own -- only a
  // real change to the task's reminder time can bring the alarm back.
  Future<void> _end() async {
    if (_taskId.isEmpty || _busy) return;
    setState(() => _busy = true);
    await NotificationService.instance.cancelOverdueAlarm(_taskId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Alarm dismissed')));
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Blocks the back gesture/button from silently dismissing an active
    // alarm -- Snooze or End are the only ways out, same as a real alarm
    // clock.
    // The old layout used bare Spacer()s in an unscrollable Column -- fine
    // on the one test device this screen was built against, but Spacer
    // can't shrink below its natural size, so a short phone screen, a
    // long task name wrapping to extra lines, or a large system font-scale
    // setting could all push this past the available height with no way
    // out (this is a full-screen alarm -- there's no scrolling past it to
    // "see the rest", the content just needs to fit or scroll in place).
    // LayoutBuilder + a scrollable ConstrainedBox(minHeight: ...) below
    // keeps the same "top group / bottom group, space distributed between
    // them" look when everything fits, but falls back to scrolling instead
    // of clipping/overflowing when it doesn't.
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: DecoratedBox(
          // A diagonal gradient reads far more like a deliberately designed
          // "alarm" surface than the old flat AppColors.danger fill did,
          // while staying inside the same red family so status/urgency
          // still reads instantly.
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF4D6D), Color(0xFFB3123B), Color(0xFF6E0B29)],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              DateFormat('h:mm').format(_now),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w300,
                                fontSize: 64,
                                height: 1,
                                letterSpacing: -1,
                              ),
                            ),
                            Text(
                              DateFormat('a · EEEE, d MMM').format(_now).toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white60,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: Gap.xxl),
                            _PulsingAlarmIcon(controller: _pulseController),
                            const SizedBox(height: Gap.lg),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(AppRadius.chip),
                              ),
                              child: const Text(
                                'TASK REMINDER',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(height: Gap.lg),
                            Text(
                              _taskName,
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 28, height: 1.2),
                            ),
                            if (_spaceName.isNotEmpty) ...[
                              const SizedBox(height: Gap.sm),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(AppRadius.chip),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.folder_outlined, color: Colors.white70, size: 14),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        _spaceName,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: Gap.xl),
                            _buildActionRow(),
                            const SizedBox(height: Gap.sm),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _pickSnoozeDuration,
            icon: const Icon(Icons.snooze_rounded, size: 20),
            label: const Text('Snooze'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              side: const BorderSide(color: Colors.white70, width: 1.5),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: FilledButton.icon(
            onPressed: _busy ? null : _end,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.danger),
                  )
                : const Icon(Icons.notifications_off_rounded, size: 20),
            label: const Text('End'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: Colors.white,
              foregroundColor: AppColors.danger,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}

/// The alarm icon sits inside two rings that expand and fade out on a
/// loop, restarting from the center each cycle -- the same "sonar ping"
/// cue most alarm/call UIs use to signal "this is actively happening now",
/// which a static icon can't communicate on its own.
class _PulsingAlarmIcon extends StatelessWidget {
  const _PulsingAlarmIcon({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      height: 160,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              _pulseRing(controller.value),
              _pulseRing((controller.value + 0.5) % 1.0),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.22),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20, spreadRadius: 2),
                  ],
                ),
                child: const Icon(Icons.alarm_rounded, color: Colors.white, size: 46),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pulseRing(double t) {
    final size = 96 + t * 64;
    return Opacity(
      opacity: (1 - t).clamp(0.0, 1.0) * 0.5,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
      ),
    );
  }
}

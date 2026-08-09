import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/notification_service.dart';
import '../core/theme.dart';
import '../providers/notifications_provider.dart';
import '../providers/tasks_provider.dart';

/// The full-screen "ringing" view for an overdue task -- reached when the
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

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  late final String _taskId;
  late final String _taskName;
  late final String _spaceName;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final data = pendingAlarmNotifier.value ?? const <String, dynamic>{};
    _taskId = (data['taskId'] ?? '').toString();
    _taskName = (data['taskName'] ?? 'Task').toString();
    _spaceName = (data['spaceName'] ?? '').toString();
    // Consumed -- clears the router's redirect trigger so leaving this
    // screen (Snooze/Complete, or the back gesture) doesn't immediately
    // bounce straight back into it. Deferred to after this frame:
    // clearing it synchronously here notifies the router's
    // refreshListenable WHILE this very widget is still being built as
    // part of that same redirect, which crashes with "setState() or
    // markNeedsBuild() called during build" (a router rebuild triggered
    // from inside a widget's own initState, mid-build, is never legal).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pendingAlarmNotifier.value = null;
    });
  }

  void _refreshTaskData() {
    ref.invalidate(myTasksProvider);
    ref.invalidate(dashboardStatsProvider);
    ref.invalidate(notificationsFeedProvider);
  }

  static const _snoozeOptions = [
    ('10 min', Duration(minutes: 10)),
    ('1 hour', Duration(hours: 1)),
    ('2 hours', Duration(hours: 2)),
  ];

  Future<void> _pickSnoozeDuration() async {
    if (_taskId.isEmpty || _busy) return;
    final chosen = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: AppColors.danger,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: Text(
                'Snooze for',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, letterSpacing: 1, fontSize: 13),
              ),
            ),
            for (final option in _snoozeOptions)
              ListTile(
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
    await NotificationService.instance.snoozeOverdueAlarm(
      taskId: _taskId,
      taskName: _taskName,
      spaceName: _spaceName,
      duration: duration,
    );
    if (mounted) context.go('/home');
  }

  // "End" -- silences this ringing/pending alarm without marking the task
  // complete, unlike _complete below. Just cancels whatever alarm is
  // currently scheduled for it (the one that just rang, or a snooze that
  // hadn't fired yet); it deliberately does NOT touch the task's status, so
  // it stays overdue in the task list same as before. Since the task was
  // already recorded in the "alerted" set the moment this alarm first
  // fired (see background_watcher_service.dart/notifications_provider.dart's
  // shared alertedIds tracking), it won't ring again on its own -- only a
  // real change to the task (a new due date pushing it overdue again) can
  // bring the alarm back.
  Future<void> _end() async {
    if (_taskId.isEmpty || _busy) return;
    setState(() => _busy = true);
    await NotificationService.instance.cancelOverdueAlarm(_taskId);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Alarm dismissed — task is still overdue')));
      context.go('/home');
    }
  }

  Future<void> _complete() async {
    if (_taskId.isEmpty || _busy) return;
    setState(() => _busy = true);
    await NotificationService.instance.completeOverdueTask(_taskId);
    _refreshTaskData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Task marked complete')));
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Blocks the back gesture/button from silently dismissing an active
    // alarm -- Snooze or Complete are the only ways out, same as a real
    // alarm clock.
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
        backgroundColor: AppColors.danger,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: Gap.xl),
                          Container(
                            width: 88,
                            height: 88,
                            decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                            child: const Icon(Icons.alarm_rounded, color: Colors.white, size: 44),
                          ),
                          const SizedBox(height: Gap.lg),
                          const Text(
                            'TASK OVERDUE',
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 3,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: Gap.md),
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
                            Text(
                              _spaceName,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ],
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: Gap.xl),
                          _buildActionRow(),
                          const SizedBox(height: Gap.md),
                          _SlideToComplete(
                            busy: _busy,
                            onComplete: _complete,
                          ),
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
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _pickSnoozeDuration,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: const BorderSide(color: Colors.white, width: 1.5),
              foregroundColor: Colors.white,
            ),
            child: const Text('Snooze', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _end,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: const BorderSide(color: Colors.white54, width: 1.5),
              foregroundColor: Colors.white70,
            ),
            child: const Text('End', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

/// iOS-style "slide to unlock" control, repurposed as "slide to complete".
/// Deliberately a drag gesture rather than a tap target -- a single stray
/// tap dismissing a real alarm (or accidentally completing the wrong task
/// half-asleep) is the exact failure mode PopScope(canPop: false) above is
/// already guarding against for the back button; requiring a full
/// deliberate swipe across the track applies that same "hard to trigger by
/// accident" bar to the Complete action too.
class _SlideToComplete extends StatefulWidget {
  const _SlideToComplete({required this.busy, required this.onComplete});

  final bool busy;
  final VoidCallback onComplete;

  @override
  State<_SlideToComplete> createState() => _SlideToCompleteState();
}

class _SlideToCompleteState extends State<_SlideToComplete> with SingleTickerProviderStateMixin {
  static const _trackHeight = 60.0;
  static const _thumbPadding = 4.0;
  static const _thumbSize = _trackHeight - _thumbPadding * 2;

  late final AnimationController _snapBack = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _dragX = 0;
  double _maxDrag = 0;
  bool _completed = false;

  @override
  void dispose() {
    _snapBack.dispose();
    super.dispose();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (widget.busy || _completed || _maxDrag <= 0) return;
    setState(() => _dragX = (_dragX + details.delta.dx).clamp(0, _maxDrag));
  }

  void _onPanEnd(DragEndDetails details) {
    if (widget.busy || _completed || _maxDrag <= 0) return;
    // 75% across counts as "completed the slide" -- matches the forgiving
    // threshold iOS's own slide-to-unlock uses, since dragging a thumb
    // fully into the far rounded corner pixel-for-pixel is fiddly on a
    // real device (one-handed, half-asleep, screen still locked).
    if (_dragX >= _maxDrag * 0.75) {
      _completeSlide();
    } else {
      _animateTo(0);
    }
  }

  void _completeSlide() {
    setState(() => _completed = true);
    _animateTo(_maxDrag);
    widget.onComplete();
  }

  void _animateTo(double target) {
    final start = _dragX;
    _snapBack
      ..reset()
      ..addListener(() {
        setState(() => _dragX = start + (target - start) * _snapBack.value);
      })
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxDrag = constraints.maxWidth - _thumbSize - _thumbPadding * 2;
        final progress = _maxDrag > 0 ? (_dragX / _maxDrag).clamp(0.0, 1.0) : 0.0;
        return Container(
          height: _trackHeight,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.18),
            borderRadius: BorderRadius.circular(_trackHeight / 2),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Center(
                child: Opacity(
                  opacity: 1 - progress,
                  child: const Text(
                    'Slide to complete',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(_thumbPadding),
                child: Transform.translate(
                  offset: Offset(_dragX, 0),
                  child: GestureDetector(
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    child: Container(
                      width: _thumbSize,
                      height: _thumbSize,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: widget.busy || _completed
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.danger),
                            )
                          : const Icon(Icons.arrow_forward_rounded, color: AppColors.danger),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

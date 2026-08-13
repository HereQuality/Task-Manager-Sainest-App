import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/notification_service.dart';
import '../core/theme.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with WidgetsBindingObserver {
  bool? _batteryExempt;
  bool? _exactAlarmsAllowed;
  bool _autoStartTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Both the OS's own permission dialog and the OEM autostart screen this
  // screen can launch (see _fixBackgroundAlarms/_openAutoStart) hand
  // control back to this screen via onResume, not via any callback this
  // app gets to see -- without re-checking here, granting either setting
  // from outside the app (the phone's own Settings app, or a dialog this
  // screen only triggered but didn't own) left the red warning showing
  // stale even after it had actually been fixed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  void _refreshStatus() {
    NotificationService.instance.isBatteryOptimizationExempt().then((v) {
      if (mounted) setState(() => _batteryExempt = v);
    });
    NotificationService.instance.canScheduleExactAlarms().then((v) {
      if (mounted) setState(() => _exactAlarmsAllowed = v);
    });
  }

  Future<void> _fixBackgroundAlarms() async {
    await NotificationService.instance.requestBatteryOptimizationExemption();
    // The dialog this triggers is itself a resume boundary, so
    // didChangeAppLifecycleState above will also re-check -- doing it
    // again here too just means the UI updates the instant this
    // particular call returns, without waiting on that lifecycle event.
    _refreshStatus();
  }

  Future<void> _requestFullScreenIntent() async {
    final granted = await NotificationService.instance.requestFullScreenIntentPermission();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        granted
            ? 'Full-screen alarm permission is granted.'
            : "Still not granted — make sure \"Full screen notifications\" is switched on for this app.",
      ),
    ));
  }

  Future<void> _openAutoStart() async {
    final opened = await NotificationService.instance.openAutoStartSettings();
    if (mounted) {
      setState(() => _autoStartTried = true);
      if (!opened) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't find an autostart screen for this phone — check its own Settings/App management app manually."),
        ));
      }
    }
  }

  Future<void> _sendTestAlarm() async {
    // Exercises the exact same OS scheduling path as a real overdue task
    // (alarmClock-mode zonedSchedule -> full-screen alarm channel) but
    // skips the whole task-data pipeline entirely, so a failure here can
    // only be the OS/OEM actually dropping the alarm, not a task-parsing
    // or timezone bug elsewhere in the app.
    await NotificationService.instance.scheduleOverdueAlarmAt(
      taskId: 'test_alarm',
      taskName: 'Test alarm',
      spaceName: 'Settings test',
      when: DateTime.now().add(const Duration(seconds: 60)),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Test alarm set for 60 seconds from now — close the app and lock the screen to test.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Notification settings')),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          // Every control in this card (full-screen-intent permission,
          // battery-optimization exemption, OEM autostart screens, exact
          // alarms) is an Android-only concept -- iOS schedules local
          // notifications at the OS level with none of these caveats, so
          // there's nothing here for an iPhone user to act on.
          if (Platform.isAndroid) ...[
          _SectionLabel('Background reliability'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          'Full-screen alarm permission',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(
                    'Android 14+ needs a SEPARATE toggle, on top of the notification '
                    'permission, before the overdue alarm can take over the lock screen '
                    'instead of just showing a normal banner. Tap below and make sure '
                    '"Full screen notifications" is allowed for this app.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.md),
                  OutlinedButton(
                    onPressed: _requestFullScreenIntent,
                    child: const Text('Grant full-screen alarm permission'),
                  ),
                  const Divider(height: Gap.xl * 1.5),
                  Row(
                    children: [
                      Icon(
                        _batteryExempt == true ? Icons.check_circle : Icons.warning_amber_rounded,
                        color: _batteryExempt == true ? AppColors.success : AppColors.danger,
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          _batteryExempt == true
                              ? 'Background alarms allowed'
                              : 'Battery settings may block alarms when closed',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(
                    'The overdue alarm rings from a system alarm, not the app itself, so it '
                    'still works after you close the app — but the phone\'s battery saver can '
                    'delay or block it. Tap below and choose "Allow" / "Don\'t optimize" for '
                    'this app.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.md),
                  if (_batteryExempt != true)
                    FilledButton(
                      onPressed: _fixBackgroundAlarms,
                      child: const Text('Allow background alarms'),
                    ),
                  if (_exactAlarmsAllowed == false) ...[
                    const SizedBox(height: Gap.md),
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text(
                            'Exact alarm scheduling isn\'t allowed — the alarm can drift or not ring at all until you grant "Alarms & reminders" for this app in the phone\'s Settings.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: Gap.xl * 1.5),
                  Text(
                    'On some phones (Vivo, Xiaomi, Oppo, Huawei, OnePlus) the alarm can still '
                    'be silently cancelled the moment you swipe the app away, unless you also '
                    'allow it in the phone\'s own "Autostart" or "App management" settings — '
                    'a step no in-app permission covers. This button jumps straight to that '
                    'screen where possible; on some newer phones it can only open this app\'s '
                    'own "App info" page instead — from there, look for "Battery" and turn off '
                    'any restriction, or enable "Autostart"/"Allow background activity".',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.md),
                  OutlinedButton(
                    onPressed: _openAutoStart,
                    child: Text(_autoStartTried ? 'Open background settings again' : 'Open background settings'),
                  ),
                  const Divider(height: Gap.xl * 1.5),
                  Text(
                    'To test: tap below, then fully close this app and lock the screen. '
                    'The alarm should ring full-screen in 60 seconds.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.md),
                  OutlinedButton(
                    onPressed: _sendTestAlarm,
                    child: const Text('Send test alarm in 60 seconds'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.xl),
          ],
          _SectionLabel('General'),
          Card(
            child: _SettingTile(
              title: 'Allow notifications',
              subtitle: 'Turn everything below on or off at once',
              value: settings.masterEnabled,
              onChanged: (v) async {
                if (v) await NotificationService.instance.requestPermission();
                notifier.update((s) => s.copyWith(masterEnabled: v));
              },
            ),
          ),
          const SizedBox(height: Gap.xl),
          _SectionLabel('What you hear about'),
          Card(
            child: Column(
              children: [
                _SettingTile(
                  title: 'Task due reminders',
                  subtitle: 'A reminder before a task assigned to you is due',
                  value: settings.taskDueReminders,
                  enabled: settings.masterEnabled,
                  onChanged: (v) => notifier.update((s) => s.copyWith(taskDueReminders: v)),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _SettingTile(
                  title: 'Ticket updates',
                  subtitle: 'When a ticket you raised or work on changes status',
                  value: settings.ticketUpdates,
                  enabled: settings.masterEnabled,
                  onChanged: (v) => notifier.update((s) => s.copyWith(ticketUpdates: v)),
                ),
                const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                _SettingTile(
                  title: 'Daily digest',
                  subtitle: "A morning summary of today's tasks",
                  value: settings.dailyDigest,
                  enabled: settings.masterEnabled,
                  onChanged: (v) => notifier.update((s) => s.copyWith(dailyDigest: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.xl),
          _SectionLabel('Timing'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Remind me before a task is due', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  Text(
                    '${settings.reminderHoursBefore} hours ahead',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Slider(
                    value: settings.reminderHoursBefore.toDouble(),
                    min: 1,
                    max: 24,
                    divisions: 23,
                    activeColor: AppColors.indigo,
                    label: '${settings.reminderHoursBefore}h',
                    onChanged: settings.masterEnabled && settings.taskDueReminders
                        ? (v) => notifier.update((s) => s.copyWith(reminderHoursBefore: v.round()))
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: Text(
              'Reminders are scheduled on this device from your task due dates. '
              'They keep working in the background, but only on this phone — '
              'they won\'t follow you to another device yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: Gap.sm, bottom: Gap.sm),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.inkMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SettingTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            Switch(value: value, onChanged: enabled ? onChanged : null),
          ],
        ),
      ),
    );
  }
}

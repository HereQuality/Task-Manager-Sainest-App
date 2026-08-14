import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Notification preferences, persisted on-device (see README for why this
/// isn't synced server-side yet — the API has no notification-preference
/// fields today). Every toggle here maps to something the app itself can
/// act on: task reminders schedule local notifications; the others govern
/// what shows up in the in-app Notifications feed.
class NotificationSettings {
  final bool masterEnabled;
  final bool taskDueReminders;
  final bool ticketUpdates;
  final bool dailyDigest;
  final int reminderHoursBefore; // how long before a due date to remind
  // Split out from taskDueReminders (which only covers the due-date/
  // overdue-alarm side) -- these cover the "something happened to a task"
  // side: a fresh assignment, an edit to a task already assigned to you,
  // a delegator's approval decision waiting on you, and a manager's
  // "your report's task is overdue" escalation. Every employee gets the
  // same controls here (there's no admin-only notification config yet --
  // this is a per-device preference, same as everything else in this
  // file), which is what makes it "for all employees" from the app's
  // point of view: whatever any one person sets only affects their own
  // device.
  final bool taskAssigned;
  final bool taskUpdates;
  final bool approvalAlerts;
  final bool teamEscalations;

  const NotificationSettings({
    this.masterEnabled = true,
    this.taskDueReminders = true,
    this.ticketUpdates = true,
    this.dailyDigest = false,
    this.reminderHoursBefore = 3,
    this.taskAssigned = true,
    this.taskUpdates = true,
    this.approvalAlerts = true,
    this.teamEscalations = true,
  });

  NotificationSettings copyWith({
    bool? masterEnabled,
    bool? taskDueReminders,
    bool? ticketUpdates,
    bool? dailyDigest,
    int? reminderHoursBefore,
    bool? taskAssigned,
    bool? taskUpdates,
    bool? approvalAlerts,
    bool? teamEscalations,
  }) {
    return NotificationSettings(
      masterEnabled: masterEnabled ?? this.masterEnabled,
      taskDueReminders: taskDueReminders ?? this.taskDueReminders,
      ticketUpdates: ticketUpdates ?? this.ticketUpdates,
      dailyDigest: dailyDigest ?? this.dailyDigest,
      reminderHoursBefore: reminderHoursBefore ?? this.reminderHoursBefore,
      taskAssigned: taskAssigned ?? this.taskAssigned,
      taskUpdates: taskUpdates ?? this.taskUpdates,
      approvalAlerts: approvalAlerts ?? this.approvalAlerts,
      teamEscalations: teamEscalations ?? this.teamEscalations,
    );
  }

  Map<String, Object> toJson() => {
        'masterEnabled': masterEnabled,
        'taskDueReminders': taskDueReminders,
        'ticketUpdates': ticketUpdates,
        'dailyDigest': dailyDigest,
        'reminderHoursBefore': reminderHoursBefore,
        'taskAssigned': taskAssigned,
        'taskUpdates': taskUpdates,
        'approvalAlerts': approvalAlerts,
        'teamEscalations': teamEscalations,
      };

  factory NotificationSettings.fromPrefs(SharedPreferences prefs) => NotificationSettings(
        masterEnabled: prefs.getBool('notif_master') ?? true,
        taskDueReminders: prefs.getBool('notif_task_due') ?? true,
        ticketUpdates: prefs.getBool('notif_ticket_updates') ?? true,
        dailyDigest: prefs.getBool('notif_daily_digest') ?? false,
        reminderHoursBefore: prefs.getInt('notif_reminder_hours') ?? 3,
        taskAssigned: prefs.getBool('notif_task_assigned') ?? true,
        taskUpdates: prefs.getBool('notif_task_updates') ?? true,
        approvalAlerts: prefs.getBool('notif_approval_alerts') ?? true,
        teamEscalations: prefs.getBool('notif_team_escalations') ?? true,
      );
}

class SettingsNotifier extends StateNotifier<NotificationSettings> {
  SettingsNotifier() : super(const NotificationSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = NotificationSettings.fromPrefs(prefs);
  }

  Future<void> _persist(NotificationSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notif_master', s.masterEnabled);
    await prefs.setBool('notif_task_due', s.taskDueReminders);
    await prefs.setBool('notif_ticket_updates', s.ticketUpdates);
    await prefs.setBool('notif_daily_digest', s.dailyDigest);
    await prefs.setInt('notif_reminder_hours', s.reminderHoursBefore);
    await prefs.setBool('notif_task_assigned', s.taskAssigned);
    await prefs.setBool('notif_task_updates', s.taskUpdates);
    await prefs.setBool('notif_approval_alerts', s.approvalAlerts);
    await prefs.setBool('notif_team_escalations', s.teamEscalations);
  }

  void update(NotificationSettings Function(NotificationSettings) fn) {
    state = fn(state);
    _persist(state);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, NotificationSettings>(
  (ref) => SettingsNotifier(),
);

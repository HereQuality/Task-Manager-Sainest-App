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
  // A morning "today's tasks" push and an end-of-day "how today went"
  // push, sent by background_watcher_service.dart's
  // _checkDailyDigestOnce at the company's configured office start/end
  // times (see notification_schedule.dart) -- Android-only, same as the
  // rest of that file's watcher subsystem.
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
  // Dedicated group toggle just for "My Task" push notifications --
  // new-assignment and task-update pushes (taskAssigned/taskUpdates above)
  // only fire while this is also on, on top of their own individual
  // toggles. Separate from taskDueReminders (the due-date/alarm side) and
  // from approvalAlerts/teamEscalations (about other people's actions on
  // your delegated tasks or reports), since those aren't "my task" pushes
  // in the same sense.
  final bool myTaskNotifications;
  // The team-member mirror of taskAssigned/taskUpdates/myTaskNotifications
  // above -- myTasksProvider ("/tasks/mine/all") already mixes a manager/
  // senior's own tasks together with every subordinate's, but until now
  // there was no way to hear about a REPORT's task being assigned/updated
  // without also turning on notifications for your own tasks (or vice
  // versa). teamEscalations above stays its own separate thing -- it's
  // specifically the 24h+-overdue alert, not general activity.
  final bool teamTaskNotifications;
  final bool teamTaskAssigned;
  final bool teamTaskUpdates;

  const NotificationSettings({
    this.masterEnabled = true,
    this.taskDueReminders = true,
    this.ticketUpdates = true,
    this.dailyDigest = true,
    this.reminderHoursBefore = 3,
    this.taskAssigned = true,
    this.taskUpdates = true,
    this.approvalAlerts = true,
    this.teamEscalations = true,
    this.myTaskNotifications = true,
    this.teamTaskNotifications = true,
    this.teamTaskAssigned = true,
    this.teamTaskUpdates = true,
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
    bool? myTaskNotifications,
    bool? teamTaskNotifications,
    bool? teamTaskAssigned,
    bool? teamTaskUpdates,
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
      myTaskNotifications: myTaskNotifications ?? this.myTaskNotifications,
      teamTaskNotifications: teamTaskNotifications ?? this.teamTaskNotifications,
      teamTaskAssigned: teamTaskAssigned ?? this.teamTaskAssigned,
      teamTaskUpdates: teamTaskUpdates ?? this.teamTaskUpdates,
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
        'myTaskNotifications': myTaskNotifications,
        'teamTaskNotifications': teamTaskNotifications,
        'teamTaskAssigned': teamTaskAssigned,
        'teamTaskUpdates': teamTaskUpdates,
      };

  factory NotificationSettings.fromPrefs(SharedPreferences prefs) => NotificationSettings(
        masterEnabled: prefs.getBool('notif_master') ?? true,
        taskDueReminders: prefs.getBool('notif_task_due') ?? true,
        ticketUpdates: prefs.getBool('notif_ticket_updates') ?? true,
        dailyDigest: prefs.getBool('notif_daily_digest') ?? true,
        reminderHoursBefore: prefs.getInt('notif_reminder_hours') ?? 3,
        taskAssigned: prefs.getBool('notif_task_assigned') ?? true,
        taskUpdates: prefs.getBool('notif_task_updates') ?? true,
        approvalAlerts: prefs.getBool('notif_approval_alerts') ?? true,
        teamEscalations: prefs.getBool('notif_team_escalations') ?? true,
        myTaskNotifications: prefs.getBool('notif_my_task') ?? true,
        teamTaskNotifications: prefs.getBool('notif_team_task') ?? true,
        teamTaskAssigned: prefs.getBool('notif_team_task_assigned') ?? true,
        teamTaskUpdates: prefs.getBool('notif_team_task_updates') ?? true,
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
    await prefs.setBool('notif_my_task', s.myTaskNotifications);
    await prefs.setBool('notif_team_task', s.teamTaskNotifications);
    await prefs.setBool('notif_team_task_assigned', s.teamTaskAssigned);
    await prefs.setBool('notif_team_task_updates', s.teamTaskUpdates);
  }

  void update(NotificationSettings Function(NotificationSettings) fn) {
    state = fn(state);
    _persist(state);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, NotificationSettings>(
  (ref) => SettingsNotifier(),
);

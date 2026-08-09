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

  const NotificationSettings({
    this.masterEnabled = true,
    this.taskDueReminders = true,
    this.ticketUpdates = true,
    this.dailyDigest = false,
    this.reminderHoursBefore = 3,
  });

  NotificationSettings copyWith({
    bool? masterEnabled,
    bool? taskDueReminders,
    bool? ticketUpdates,
    bool? dailyDigest,
    int? reminderHoursBefore,
  }) {
    return NotificationSettings(
      masterEnabled: masterEnabled ?? this.masterEnabled,
      taskDueReminders: taskDueReminders ?? this.taskDueReminders,
      ticketUpdates: ticketUpdates ?? this.ticketUpdates,
      dailyDigest: dailyDigest ?? this.dailyDigest,
      reminderHoursBefore: reminderHoursBefore ?? this.reminderHoursBefore,
    );
  }

  Map<String, Object> toJson() => {
        'masterEnabled': masterEnabled,
        'taskDueReminders': taskDueReminders,
        'ticketUpdates': ticketUpdates,
        'dailyDigest': dailyDigest,
        'reminderHoursBefore': reminderHoursBefore,
      };

  factory NotificationSettings.fromPrefs(SharedPreferences prefs) => NotificationSettings(
        masterEnabled: prefs.getBool('notif_master') ?? true,
        taskDueReminders: prefs.getBool('notif_task_due') ?? true,
        ticketUpdates: prefs.getBool('notif_ticket_updates') ?? true,
        dailyDigest: prefs.getBool('notif_daily_digest') ?? false,
        reminderHoursBefore: prefs.getInt('notif_reminder_hours') ?? 3,
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
  }

  void update(NotificationSettings Function(NotificationSettings) fn) {
    state = fn(state);
    _persist(state);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, NotificationSettings>(
  (ref) => SettingsNotifier(),
);

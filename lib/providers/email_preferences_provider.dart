import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

/// Per-user EMAIL notification preferences -- a separate, server-synced
/// concept from settings_provider.dart's push/local toggles (which are
/// on-device only, since the API has no field for those). This one is
/// backed by Employee.js/user.model.js's `preferences.emailNotifications`
/// (added for the web app's Settings page), read via GET /auth/me and
/// written via PUT /auth/me/preferences -- same endpoint/shape the web
/// app's AuthContext#updatePreferences already uses, so a change made on
/// either surface is immediately visible on the other.
///
/// A missing key means "not yet saved", not "turned off" -- every category
/// defaults to on, same opt-out semantics as the company-wide switch this
/// mirrors (server/utils/emailSettings.js) and the web app's own
/// `isEmailOn` helper (Settings.jsx).
class EmailCategory {
  final String key;
  final String label;
  final String desc;
  const EmailCategory(this.key, this.label, this.desc);
}

const emailCategories = [
  EmailCategory('taskCreated', 'Task assigned to me', 'When a new task is created and assigned to you.'),
  EmailCategory('statusChanged', 'Task updated', 'When a task assigned to you (or one you created) changes.'),
  EmailCategory('taskCompleted', 'Task completed', 'When a task assigned to you (or one you created) is marked complete.'),
  EmailCategory('taskDeleted', 'Task deleted', 'When a task assigned to you (or one you created) is deleted.'),
  EmailCategory('bulkImport', 'Bulk Excel import', 'A summary email after you import tasks from Excel, plus one per assigned task.'),
  EmailCategory('overdueEscalation', 'Overdue 24h+ escalation', "When one of your tasks (or a direct report's) passes 24 hours overdue."),
  EmailCategory('completionApprovalRequested', 'Approval requested', 'When someone you delegated a task to asks you to approve marking it complete.'),
];

class EmailPreferencesNotifier extends StateNotifier<AsyncValue<Map<String, bool>>> {
  EmailPreferencesNotifier() : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.instance.dio.get('/auth/me');
      final raw = res.data['data']?['preferences']?['emailNotifications'];
      state = AsyncValue.data(_normalize(raw));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Map<String, bool> _normalize(dynamic raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return {for (final c in emailCategories) c.key: map[c.key] != false};
  }

  /// Optimistic -- flips the local switch immediately, then persists.
  /// Reverts back on failure so the UI never shows a toggle that didn't
  /// actually save.
  Future<void> setCategory(String key, bool value) async {
    final current = state.valueOrNull ?? {for (final c in emailCategories) c.key: true};
    final next = {...current, key: value};
    state = AsyncValue.data(next);
    try {
      await ApiClient.instance.dio.put('/auth/me/preferences', data: {
        'emailNotifications': next,
      });
    } catch (_) {
      state = AsyncValue.data(current);
    }
  }
}

final emailPreferencesProvider =
    StateNotifierProvider<EmailPreferencesNotifier, AsyncValue<Map<String, bool>>>(
  (ref) => EmailPreferencesNotifier(),
);

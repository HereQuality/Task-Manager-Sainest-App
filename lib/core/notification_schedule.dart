import 'api_client.dart';

/// Mirrors server/utils/notificationSchedule.js -- the company-wide
/// holidays/weekly-off-days/office-hours window a Full Access person sets
/// on the Teams page (Settings -> "Notification Schedule"). That file
/// already gates every task EMAIL through the equivalent
/// isWithinNotificationWindow() check; this is the same rule applied to
/// the mobile app's own push notifications (including the full-screen
/// Urgent-task alarm), which until now ignored it entirely.
///
/// All date/time math uses a fixed +05:30 offset (Asia/Kolkata, no DST)
/// rather than the device's own local timezone -- same "kept in sync by
/// hand" convention as atsCalculator.js/atsCalculator.client.js elsewhere
/// in this codebase, and for the same reason: a person's phone set to a
/// different timezone must not shift when their own company's office
/// hours are considered to start/end.
const _businessOffsetMinutes = 330; // Asia/Kolkata, +05:30, fixed (no DST)

/// A single business-timezone calendar day, used as a comparison key for
/// holidays/"is this the same day" checks -- deliberately not a real
/// instant (no time-of-day), so two DateTimes landing on the same
/// business-tz day always compare equal regardless of their exact clock
/// time.
class _BusinessDay {
  final int year;
  final int month;
  final int day;
  const _BusinessDay(this.year, this.month, this.day);

  factory _BusinessDay.of(DateTime instant) {
    final shifted = instant.toUtc().add(const Duration(minutes: _businessOffsetMinutes));
    return _BusinessDay(shifted.year, shifted.month, shifted.day);
  }

  _BusinessDay addDays(int n) {
    final d = DateTime.utc(year, month, day).add(Duration(days: n));
    return _BusinessDay(d.year, d.month, d.day);
  }

  /// The absolute instant this business-tz day reaches [minuteOfDay]
  /// (0-1439) -- inverse of the shift in `.of()` above.
  DateTime instantAt(int minuteOfDay) {
    return DateTime.utc(year, month, day, minuteOfDay ~/ 60, minuteOfDay % 60)
        .subtract(const Duration(minutes: _businessOffsetMinutes));
  }

  /// 0=Sunday..6=Saturday, matching server/utils/atsCalculator.js's
  /// getBusinessWeekday (JS Date#getUTCDay convention) -- Dart's own
  /// DateTime.weekday is 1=Monday..7=Sunday, so `% 7` remaps Sunday from
  /// 7 down to 0 while leaving Monday..Saturday (1..6) unchanged.
  int get weekday => DateTime.utc(year, month, day).weekday % 7;

  @override
  bool operator ==(Object other) => other is _BusinessDay && other.year == year && other.month == month && other.day == day;
  @override
  int get hashCode => Object.hash(year, month, day);
}

int _minuteOfDay(DateTime instant) {
  final shifted = instant.toUtc().add(const Duration(minutes: _businessOffsetMinutes));
  return shifted.hour * 60 + shifted.minute;
}

/// A stable "yyyy-MM-dd" key for [instant]'s business-tz calendar day --
/// used by background_watcher_service.dart to record which day the daily
/// digest was already sent for, so a 5-minute detection window (see
/// isWithinOfficeStartWindow/isWithinOfficeEndWindow) can't fire twice in
/// the same day.
String businessDayKeyFor(DateTime instant) {
  final d = _BusinessDay.of(instant);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

int _parseTimeToMinutes(String? value, int fallback) {
  final match = value == null ? null : RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(value);
  if (match == null) return fallback;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

class NotificationSchedule {
  final Set<_BusinessDay> holidays;
  final Set<int> weeklyOffDays; // 0=Sun..6=Sat
  final bool officeHoursEnabled;
  final int officeStartMinutes;
  final int officeEndMinutes;

  const NotificationSchedule({
    required this.holidays,
    required this.weeklyOffDays,
    required this.officeHoursEnabled,
    required this.officeStartMinutes,
    required this.officeEndMinutes,
  });

  /// No schedule configured yet (fresh install, endpoint unreachable, or
  /// the company genuinely hasn't set one up) -- restricts nothing, same
  /// "missing = doesn't restrict anything yet" default the server side
  /// uses for DEFAULT_SCHEDULE.
  static const unrestricted = NotificationSchedule(
    holidays: {},
    weeklyOffDays: {},
    officeHoursEnabled: false,
    officeStartMinutes: 0,
    officeEndMinutes: 24 * 60 - 1,
  );

  factory NotificationSchedule.fromJson(Map<String, dynamic> json) {
    final holidaysRaw = json['holidays'];
    final holidays = <_BusinessDay>{};
    if (holidaysRaw is List) {
      for (final h in holidaysRaw) {
        final raw = h is Map ? h['date'] : null;
        final parsed = raw == null ? null : DateTime.tryParse(raw.toString());
        if (parsed != null) holidays.add(_BusinessDay.of(parsed));
      }
    }
    final weeklyOffRaw = json['weeklyOffDays'];
    final weeklyOff = weeklyOffRaw is List
        ? weeklyOffRaw.map((d) => (d as num).toInt()).where((d) => d >= 0 && d <= 6).toSet()
        : <int>{};
    final office = json['officeHours'];
    final officeMap = office is Map ? office : const {};
    return NotificationSchedule(
      holidays: holidays,
      weeklyOffDays: weeklyOff,
      officeHoursEnabled: officeMap['enabled'] == true,
      officeStartMinutes: _parseTimeToMinutes(officeMap['start']?.toString(), 0),
      officeEndMinutes: _parseTimeToMinutes(officeMap['end']?.toString(), 24 * 60 - 1),
    );
  }

  /// True if [instant] falls inside the allowed notification window --
  /// not a listed holiday, not a weekly-off day, and (only if office
  /// hours are turned on) inside the configured start/end. Mirrors
  /// isWithinNotificationWindow in server/utils/notificationSchedule.js
  /// field-for-field.
  bool isWithinWindow(DateTime instant) {
    final day = _BusinessDay.of(instant);
    if (holidays.contains(day)) return false;
    if (weeklyOffDays.contains(day.weekday)) return false;
    if (officeHoursEnabled) {
      final minutes = _minuteOfDay(instant);
      if (minutes < officeStartMinutes || minutes > officeEndMinutes) return false;
    }
    return true;
  }

  /// True during the first 5 minutes of the configured office start time
  /// (business tz) -- used by the daily-digest check in
  /// background_watcher_service.dart, which polls once a minute and needs
  /// a short window rather than an exact-minute match since consecutive
  /// ticks aren't guaranteed to land on the exact wall-clock minute (see
  /// _scheduleNextTick's own doc comment on tick drift). Deduping which
  /// business day a digest was already sent for (see
  /// _digestMorningSentKey/_digestEveningSentKey) is what stops this
  /// 5-minute window from sending more than once.
  bool isWithinOfficeStartWindow(DateTime instant) {
    if (!officeHoursEnabled) return false;
    final m = _minuteOfDay(instant);
    return m >= officeStartMinutes && m < officeStartMinutes + 5;
  }

  /// Mirrors isWithinOfficeStartWindow, for the end-of-day digest.
  bool isWithinOfficeEndWindow(DateTime instant) {
    if (!officeHoursEnabled) return false;
    final m = _minuteOfDay(instant);
    return m >= officeEndMinutes && m < officeEndMinutes + 5;
  }

  /// The earliest instant at or after [candidate] that isWithinWindow
  /// would allow -- used to defer an exact-time OS alarm (which, once
  /// armed via AlarmManager/zonedSchedule, fires at that wall-clock
  /// moment no matter what) so it never rings during a holiday, a weekly
  /// off day, or outside office hours. Returns [candidate] unchanged when
  /// it's already allowed. Bounded to 60 days out as a safety net against
  /// a pathological schedule (e.g. every single weekday marked off)
  /// looping effectively forever.
  DateTime resolveNextAllowedInstant(DateTime candidate) {
    if (isWithinWindow(candidate)) return candidate;
    var day = _BusinessDay.of(candidate);
    var minute = _minuteOfDay(candidate);
    for (var i = 0; i < 60; i++) {
      final blocked = holidays.contains(day) || weeklyOffDays.contains(day.weekday);
      if (blocked) {
        day = day.addDays(1);
        minute = officeHoursEnabled ? officeStartMinutes : 0;
        continue;
      }
      if (officeHoursEnabled) {
        if (minute < officeStartMinutes) {
          minute = officeStartMinutes;
        } else if (minute > officeEndMinutes) {
          day = day.addDays(1);
          minute = officeStartMinutes;
          continue;
        }
      }
      return day.instantAt(minute);
    }
    // Every probed day was blocked -- fall back to the original instant
    // rather than an unbounded loop; a schedule this restrictive is a
    // configuration problem, not something to silently hang on.
    return candidate;
  }
}

NotificationSchedule? _cachedSchedule;
DateTime? _cachedAt;

/// Fetches GET /company/notification-schedule (see
/// company.controller.js#getNotificationSchedule -- readable by any
/// authenticated person, only editing it is Full-Access-gated), cached
/// for a few minutes since this is checked on every poll (the background
/// watcher ticks once a minute) and the schedule itself rarely changes.
/// Fails OPEN on any error (offline, server hasn't deployed this endpoint
/// yet, ...) -- returns the last good value if there is one, otherwise
/// `unrestricted`, so a person is never left with silently broken
/// notifications just because this one lookup couldn't complete.
Future<NotificationSchedule> fetchNotificationSchedule({bool forceRefresh = false}) async {
  final now = DateTime.now();
  if (!forceRefresh && _cachedSchedule != null && _cachedAt != null && now.difference(_cachedAt!) < const Duration(minutes: 5)) {
    return _cachedSchedule!;
  }
  try {
    final res = await ApiClient.instance.dio.get('/company/notification-schedule').timeout(const Duration(seconds: 8));
    final schedule = NotificationSchedule.fromJson(Map<String, dynamic>.from(res.data['data'] ?? {}));
    _cachedSchedule = schedule;
    _cachedAt = now;
    return schedule;
  } catch (_) {
    return _cachedSchedule ?? NotificationSchedule.unrestricted;
  }
}

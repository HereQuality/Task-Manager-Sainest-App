import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Shows a scrollable hour(1-12) / minute / AM-PM wheel picker instead of
/// Material's default showTimePicker dial -- that dial renders as two
/// tappable circles (hour ring, then minute ring), which read as confusing
/// "selected circles" rather than a plain time list. This always spins as a
/// simple 1-12 + AM/PM wheel, regardless of the device's own 24-hour system
/// setting. Shared by add_task_sheet.dart and edit_task_sheet.dart so every
/// Due/Reminder time field in the app picks the same way.
Future<TimeOfDay?> pickTime12h(BuildContext context, {TimeOfDay? initialTime, String? title}) {
  final now = DateTime.now();
  var selected = initialTime == null
      ? now
      : DateTime(now.year, now.month, now.day, initialTime.hour, initialTime.minute);

  return showModalBottomSheet<TimeOfDay>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                if (title != null)
                  Text(title, style: Theme.of(ctx).textTheme.titleMedium)
                else
                  const SizedBox.shrink(),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, TimeOfDay(hour: selected.hour, minute: selected.minute)),
                  child: const Text('Done'),
                ),
              ],
            ),
            SizedBox(
              height: 216,
              child: CupertinoTheme(
                data: const CupertinoThemeData(brightness: Brightness.light),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: false,
                  initialDateTime: selected,
                  onDateTimeChanged: (dt) => selected = dt,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Formats a TimeOfDay as 12-hour + AM/PM unconditionally, independent of
/// the device's own 24-hour display setting -- used for every Due/Reminder
/// time label so it always reads e.g. "2:30 PM" no matter what the phone's
/// system clock format is set to.
String formatTimeOfDay12h(TimeOfDay t) {
  final hour = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final minute = t.minute.toString().padLeft(2, '0');
  final period = t.period == DayPeriod.am ? 'AM' : 'PM';
  return '$hour:$minute $period';
}

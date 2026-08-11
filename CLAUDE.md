# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Flutter mobile client ("Q Task360") for HQEPL's task/ticket management platform. This repo is the **app only** — it talks to an existing backend (Node/Express + MongoDB, referenced in code comments as `task.controller.js`, `employee.controller.js`, `auth.controller.js`, `Task.js`, etc.) over the same REST API a separate web app already uses. There's no server code here; when a comment says "same endpoint the web app uses," take the API contract as given rather than trying to infer it from this repo alone.

## Commands

```bash
flutter pub get                                    # install deps

# Run against a local backend (defaults to https://task.hqepl.com/api/v1 otherwise):
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000/api/v1      # Android emulator
flutter run --dart-define=API_BASE_URL=http://localhost:5000/api/v1     # iOS simulator

flutter analyze                                     # static analysis (flutter_lints)
flutter test                                        # run all tests
flutter test test/widget_test.dart                  # run a single test file

flutter build apk --dart-define=API_BASE_URL=...    # Android build
flutter build appbundle --dart-define=API_BASE_URL=... # Play Store bundle
flutter build ios --dart-define=API_BASE_URL=...    # iOS build

dart run flutter_launcher_icons                     # regenerate app icons after editing pubspec's icon config
dart run tool/pad_logo.dart                         # regenerate padded icon source images after app_logo.png changes (run before flutter_launcher_icons)
```

There is no CI config in this repo and the test suite is currently a placeholder (`test/widget_test.dart`) — don't assume `flutter test` catches regressions.

Android release builds sign with `android/key.properties` (gitignored; template at `android/key.properties.example`) if present, otherwise silently fall back to debug signing — this is intentional so local builds/CI without the signing secret still work.

## Architecture

### State management
Riverpod (`flutter_riverpod`), no code generation. Two shapes are used deliberately:
- `StateNotifierProvider` for real client state: `authProvider` (session), `settingsProvider` (notification prefs).
- `FutureProvider.autoDispose` for server data: `myTasksProvider`, `dashboardStatsProvider`, `spacesProvider`, `ticketsProvider`, `assignableEmployeesProvider`, `notificationsFeedProvider`, etc.

Most API responses are passed around as raw `Map<String, dynamic>` rather than typed models — only `AppUser` (`lib/models/user.dart`) and `AppNotification` (`lib/models/notification_item.dart`) are modeled classes. Follow that pattern rather than introducing new DTOs for tasks/tickets/spaces unless a screen's complexity actually demands it.

### Routing
`lib/core/router.dart` uses `go_router` with a single `redirect` callback driven by two independent signals merged via `Listenable.merge`: `authProvider` (wrapped in a small `ChangeNotifier` bridge, `_AuthListenable`) and `pendingAlarmNotifier`, a plain `ValueNotifier` set whenever the overdue alarm needs to force-navigate to `/home/alarm` (see below). `AuthStatus.unknown` routes to `/splash` while the token is being verified against `/auth/me`, so a remembered session never flashes the login screen.

### API client
`lib/core/api_client.dart` is a Dio singleton (`ApiClient.instance`). A request interceptor injects the bearer token from `flutter_secure_storage` on every call (no in-memory token cache — reads happen per request); a response interceptor clears the token on 401. Also holds the "remember me" flag and the current user's id (in plain `SharedPreferences`, needed by background isolates that have no Riverpod tree — see below).

Backend response shape is inconsistent across endpoints and this is load-bearing, not a bug to "fix": `/auth/me` returns the user directly under `data`, but `/auth/login` nests it under `data.user`. Most list endpoints fall back through 1-2 possible keys (`res.data['data'] ?? res.data['tasks'] ?? []`). Check the existing provider for an endpoint before assuming a response shape.

Dates sent to the backend are always `.toUtc()` first — a bare `DateTime` from a picker serializes without a `Z` suffix, and the Node server then parses it as local time in whatever timezone *it* runs in, silently shifting times. Keep this conversion on any new endpoint that accepts a date.

### Background overdue-alarm watcher
This is the most complex subsystem in the app (`lib/core/background_watcher_service.dart`, `lib/core/notification_service.dart`, `lib/core/task_update_tracker.dart`) and exists because plain scheduled notifications (`zonedSchedule`) were found to silently never fire on some OEM Android devices once the app was swiped from Recents. The fix is architectural, not another permission:

- A persistent Android **foreground service** (`flutter_background_service`) polls the backend every minute for overdue/urgent tasks, task changes, team escalations, and pending approvals, firing local notifications/full-screen alarms directly.
- The minute-by-minute tick is a **self-rescheduling `AndroidAlarmManager.oneShot`**, not `Timer.periodic` — a live device test showed in-process timers stall for 8+ minutes even while the process stays alive; each tick only arms the next one after finishing.
- A separate **2-hour `AndroidAlarmManager.periodic` watchdog** (`armWatchdog`, started from `main.dart`) independently restarts the foreground service if Android has killed it — necessary because Android 15 hard-kills long-running `dataSync` foreground services around 6 hours, with no callback the app can react to.
- The foreground service and its `AlarmManager` callbacks run in **separate isolates with no `ProviderScope`**, so the logic they share with the foreground Riverpod code (`detectTaskChanges` in `task_update_tracker.dart`, `fetchTeamOverdueEscalations`/`fetchPendingApprovals` in `tasks_provider.dart`) is written as plain top-level functions, not providers, and persists "already alerted" state via `SharedPreferences` string-list keys that are **intentionally duplicated by matching key name** between `notifications_provider.dart` (foreground feed) and `background_watcher_service.dart` (background poll), so whichever path sees a change first is the one that records it and the other doesn't re-announce it. If you rename or add one of these keys, update it in both places.
- iOS has no equivalent background watcher (`autoStart: false` there) — only local `zonedSchedule` reminders.

When touching notification logic, read the doc comments in these three files first — they record specific on-device failure modes (with reasoning) that motivated the current design; don't simplify them without understanding what broke before.

### Theming
`lib/core/theme.dart` defines the full palette as tokens on `AppColors` plus a single `StatusStyle.of(status)` mapping used everywhere a task/ticket status needs a color (Tasks, Tickets, notification feed) — reuse that mapping rather than hardcoding status colors in a screen.

### Navigation shell
`lib/screens/home_shell.dart` has 5 bottom-nav slots but only 4 real pages (Home/Tasks/Calendar/Profile) — the middle slot opens the "Add task" sheet as an overlay rather than navigating, and index math shifts around that gap (`_navIndexForPage`/`_onDestinationSelected`). Tickets, Notifications, and Settings are reached from Profile/the bell icon rather than being top-level tabs.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'api_client.dart';

/// Set once checkForRequiredUpdate() resolves (see main.dart) -- router.dart
/// watches this alongside pendingAlarmNotifier/pendingTaskOpenNotifier etc
/// (same ValueNotifier-bridge pattern used throughout this app) and
/// redirects to /force-update the instant it's non-null and required,
/// ahead of every other redirect including the auth check -- a person on a
/// build old enough to be blocked shouldn't be able to reach login, Home,
/// or anywhere else first.
final forceUpdateNotifier = ValueNotifier<AppUpdateResult?>(null);

/// Mandatory-update gate -- checked once at cold start (see main.dart),
/// before the person reaches login or any real screen. Mirrors
/// server/models/Company.js#appUpdateConfig field-for-field: an admin
/// sets a per-platform minVersion + storeUrl via PUT
/// /companies/app-update-config (Full Access/SuperAdmin only), and every
/// device compares its own installed version against it on launch.
///
/// Deliberately NOT a Riverpod provider -- this runs once, synchronously
/// in main() before runApp(), the same reasoning notification_service.dart's
/// init() and push_service.dart's init() already establish for
/// startup-sequence code in this app.
class AppUpdateResult {
  const AppUpdateResult({required this.required, this.storeUrl});
  final bool required;
  final String? storeUrl;
}

/// "1.4.2" -> [1, 4, 2]. Non-numeric/missing segments read as 0, so a
/// short or malformed version string (e.g. an admin typo) compares as
/// "very old" rather than throwing and taking down the whole startup
/// check -- same "fail toward safety, not toward a crash" reasoning as
/// notification_schedule.dart's fail-open default, just inverted: THIS
/// gate fails open in the other direction on a truly unparseable server
/// value (see compareVersions' 0-vs-0 case below), never on a merely
/// short one.
List<int> _parseVersion(String v) {
  final parts = v.trim().split('.');
  return List.generate(3, (i) => i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0);
}

/// -1 if [a] < [b], 0 if equal, 1 if [a] > [b] -- plain dot-separated
/// integer comparison (see Company.js#appUpdateConfig's own doc comment
/// on why this is never treated as full semver).
int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

/// Fetches the server's current per-platform config and compares it
/// against this install's own version. Fails OPEN on any error (offline,
/// server unreachable, endpoint not deployed yet) -- a person should
/// never be locked out of an app they can't already reach the internet
/// with, and a fresh deploy that hasn't set this up yet must never block
/// anyone. An empty/missing minVersion on the server (the field's own
/// default) is the same "not configured" signal and also never blocks.
Future<AppUpdateResult> checkForRequiredUpdate() async {
  try {
    final res = await ApiClient.instance.dio
        .get('/companies/app-update-config')
        .timeout(const Duration(seconds: 8));
    // ignore: avoid_print
    print('[AppUpdate] response data: ${res.data}');
    final data = Map<String, dynamic>.from(res.data['data'] ?? {});
    final platformConfig = Platform.isIOS ? data['ios'] : (Platform.isAndroid ? data['android'] : null);
    // ignore: avoid_print
    print('[AppUpdate] platform=${Platform.isIOS ? 'ios' : 'android'} platformConfig=$platformConfig');
    if (platformConfig == null) return const AppUpdateResult(required: false);

    final minVersion = (platformConfig['minVersion'] ?? '').toString().trim();
    if (minVersion.isEmpty) return const AppUpdateResult(required: false);

    final packageInfo = await PackageInfo.fromPlatform();
    // ignore: avoid_print
    print('[AppUpdate] installed version=${packageInfo.version} minVersion=$minVersion');
    final isRequired = compareVersions(packageInfo.version, minVersion) < 0;
    // ignore: avoid_print
    print('[AppUpdate] isRequired=$isRequired');
    if (!isRequired) return const AppUpdateResult(required: false);

    final storeUrl = (platformConfig['storeUrl'] ?? '').toString().trim();
    return AppUpdateResult(required: true, storeUrl: storeUrl.isEmpty ? null : storeUrl);
  } catch (e, st) {
    // ignore: avoid_print
    print('[AppUpdate] checkForRequiredUpdate FAILED: $e');
    // ignore: avoid_print
    print(st);
    return const AppUpdateResult(required: false);
  }
}

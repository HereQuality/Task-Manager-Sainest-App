import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_update_service.dart';
import '../core/theme.dart';

/// Full-screen, undismissable gate reached when router.dart's redirect
/// sees forceUpdateNotifier.value?.required == true -- an admin has set
/// this device's platform below its configured minimum version (see
/// Company.js#appUpdateConfig). No PopScope escape and no other route in
/// this app is reachable while this is up; the only way off it is
/// actually updating (which replaces this build) or the admin lowering
/// the server's minVersion.
class ForceUpdateScreen extends StatefulWidget {
  const ForceUpdateScreen({super.key});

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  bool _opening = false;

  Future<void> _openStore() async {
    final storeUrl = forceUpdateNotifier.value?.storeUrl;
    if (storeUrl == null || storeUrl.isEmpty || _opening) return;
    setState(() => _opening = true);
    try {
      final uri = Uri.parse(storeUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort -- a malformed/unreachable storeUrl (an admin typo,
      // or the iOS placeholder before a real App Store id is set) must
      // never crash this screen; the person is just stuck here until
      // it's corrected server-side, same as every other config-driven
      // fail-safe in this app.
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasStoreUrl = (forceUpdateNotifier.value?.storeUrl ?? '').isNotEmpty;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.ink,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  child: const Icon(Icons.system_update_rounded, color: Colors.white, size: 48),
                ),
                const SizedBox(height: Gap.xl),
                const Text(
                  'Update Required',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 26),
                ),
                const SizedBox(height: Gap.sm),
                const Text(
                  'A newer version of Q Task360 is required to continue. Please update to keep using the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: Gap.xxl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: hasStoreUrl && !_opening ? _openStore : null,
                    icon: _opening
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.ink),
                          )
                        : const Icon(Icons.open_in_new_rounded, size: 20),
                    label: const Text('Update Now'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.ink,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
                      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                ),
                if (!hasStoreUrl) ...[
                  const SizedBox(height: Gap.md),
                  const Text(
                    'The update link isn’t available yet -- please check back shortly.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

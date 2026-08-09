import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Shown only while AuthStatus is still `unknown` -- i.e. while
/// _restoreSession (auth_provider.dart) is checking secure storage and,
/// if a token's there, verifying it against /auth/me. Router.dart routes
/// here first instead of straight to /login, so a "remembered" session
/// lands on Home directly instead of showing the login form for a
/// flash before redirecting away from it.
///
/// Kept deliberately quiet -- generous whitespace, the brand mark
/// doing all the talking, a hairline progress bar instead of a bold
/// spinner -- since this is on screen for well under a second on a
/// warm launch and shouldn't compete with what shows up right after it.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _fade = CurvedAnimation(parent: _controller, curve: const Interval(0, 0.7, curve: Curves.easeOut));
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/app_logo.png',
                        width: 132,
                        height: 132,
                      ),
                      const SizedBox(height: Gap.lg),
                      const Text(
                        'TASK MANAGER',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 3.2,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 64,
              right: 64,
              bottom: 56,
              child: FadeTransition(
                opacity: _fade,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: const SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      backgroundColor: AppColors.indigoSoft,
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.indigo),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

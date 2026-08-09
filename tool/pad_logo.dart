// One-off build tool: derives launcher-icon-safe variants of the brand
// mark from assets/images/app_logo.png. Not run as part of the app --
// invoke with `dart run tool/pad_logo.dart` whenever the source logo
// changes, then re-run `dart run flutter_launcher_icons`.
//
// The source PNG has the mark filling the canvas edge-to-edge (including
// the "Lean" tag poking into the top-left corner), which is fine for an
// unmasked context like the splash screen or login header, but Android's
// adaptive icon system only guarantees the center ~66% of the foreground
// layer survives its circle/rounded-square/squircle mask -- anything
// outside that safe zone gets clipped, which is exactly the bad crop
// seen on-device. Fix: scale the mark down and center it on a padded
// canvas before handing it to flutter_launcher_icons.
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final source = img.decodePng(File('assets/images/app_logo.png').readAsBytesSync())!;

  // Adaptive foreground: transparent canvas, mark scaled to ~55% of the
  // canvas so it sits comfortably inside every launcher's safe zone
  // (66%) with margin to spare, since some OEM masks are stricter than
  // stock Android's.
  final adaptiveCanvas = img.Image(width: 1024, height: 1024, numChannels: 4);
  final adaptiveMark = img.copyResize(source, width: (1024 * 0.55).round());
  img.compositeImage(
    adaptiveCanvas,
    adaptiveMark,
    dstX: (1024 - adaptiveMark.width) ~/ 2,
    dstY: (1024 - adaptiveMark.height) ~/ 2,
  );
  File('assets/images/app_logo_adaptive_fg.png').writeAsBytesSync(img.encodePng(adaptiveCanvas));

  // Base/iOS icon: white square canvas (iOS never masks to transparent,
  // and this is also the fallback for pre-adaptive-icon Android), mark
  // scaled to ~72% so there's breathing room but it still reads clearly
  // at small launcher sizes.
  final baseCanvas = img.Image(width: 1024, height: 1024, numChannels: 4);
  img.fill(baseCanvas, color: img.ColorRgba8(255, 255, 255, 255));
  final baseMark = img.copyResize(source, width: (1024 * 0.72).round());
  img.compositeImage(
    baseCanvas,
    baseMark,
    dstX: (1024 - baseMark.width) ~/ 2,
    dstY: (1024 - baseMark.height) ~/ 2,
  );
  File('assets/images/app_logo_icon.png').writeAsBytesSync(img.encodePng(baseCanvas));

  stdout.writeln('Wrote app_logo_adaptive_fg.png and app_logo_icon.png');
}

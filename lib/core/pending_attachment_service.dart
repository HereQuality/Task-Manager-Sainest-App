import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/tasks_provider.dart';

/// Set to a task's id the moment a recovered attachment finishes uploading
/// to it. The Task Detail screen's attachments panel watches this to
/// refresh itself -- recovery is driven from main.dart (see
/// PendingAttachmentService's own doc comment for why it can't live in the
/// widget), which has no Riverpod ref to invalidate providers with, and the
/// panel may not even be on screen at that point. Same plain-ValueNotifier
/// bridge pattern as pendingAlarmNotifier in notification_service.dart.
final attachmentRecoveredNotifier = ValueNotifier<String?>(null);

/// True only while a recovered attachment is actually being uploaded.
/// The attachments panel drives its spinner off this rather than off its
/// own local flag: the native document picker returns immediately without
/// a result (the upload happens later, from the recovery path), so a
/// locally-owned spinner would have no way to learn that the person simply
/// cancelled the picker, and would sit there spinning forever.
final attachmentUploadingNotifier = ValueNotifier<bool>(false);

/// Set the moment a torn-down pick is discovered (see recoverPendingUpload
/// below) -- before the recovery upload even starts, not after it finishes.
/// router.dart merges this into its refreshListenable exactly the way it
/// already does for pendingAlarmNotifier, redirecting straight to that task
/// instead of ever rendering Home first: without this, a recovered upload
/// looked like the app had "restarted to Home" even though nothing was
/// actually lost, because Home is simply where a fresh launch boots to.
/// TaskDetailScreen clears it once it's the one being shown, same
/// consumed-trigger pattern AlarmScreen already uses for
/// pendingAlarmNotifier.
final pendingAttachmentTaskNotifier = ValueNotifier<String?>(null);

/// Survives the task-attachment pick across an Activity teardown.
///
/// Confirmed on a real device (Vivo, Android 15) from logcat: while the
/// system document picker or camera is in the foreground, Android destroys
/// and recreates the app's Activity WITHOUT killing its process -- the
/// background watcher isolate kept ticking on the same PID straight
/// through, while a second FlutterEngine was created. Everything in the
/// Dart VM is rebuilt from scratch at that point, so the `await` sitting on
/// the picker's result simply no longer exists when the result arrives, and
/// the picked file vanishes with it. To the person this looked like "the
/// app restarts and the upload never happens".
///
/// Neither half of the fix can live in normal widget state, since that's
/// exactly what gets wiped:
///   - the FILE is captured natively (see MainActivity.kt's
///     onActivityResult, which Android still delivers to the recreated
///     Activity) for documents, and via image_picker's own
///     retrieveLostData() for camera shots -- that API exists for
///     precisely this Android behavior;
///   - the TARGET (which task the upload belongs to) is written to
///     SharedPreferences here before the picker is ever launched, because
///     after a teardown the app relaunches at Home, not on the task the
///     person started from.
class PendingAttachmentService {
  PendingAttachmentService._();
  static final instance = PendingAttachmentService._();

  static const _channel = MethodChannel('com.hqepl.qtask360/document_picker');
  static const _pendingTaskIdKey = 'pending_attachment_task_id';

  /// Records which task an about-to-be-picked file belongs to. Must be
  /// called before launching any picker -- see the class doc for why the
  /// task id can't just be held in the calling widget's state.
  Future<void> setPendingTarget(String taskId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTaskIdKey, taskId);
  }

  Future<void> clearPendingTarget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTaskIdKey);
  }

  Future<String?> _pendingTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pendingTaskIdKey);
  }

  /// Public read-only peek at the stored target -- used by main.dart to
  /// seed pendingAttachmentTaskNotifier before runApp, purely a fast local
  /// SharedPreferences read with no platform-channel/network calls, so it
  /// can win the race against the router's very first redirect decision
  /// the same way the alarm's launch-details check already does.
  Future<String?> pendingTargetTaskId() => _pendingTarget();

  /// Launches the native document picker (MainActivity.kt). Returns false
  /// if the platform channel isn't available -- i.e. iOS, where this whole
  /// mechanism doesn't apply and the caller falls back to file_selector.
  Future<bool> pickDocument() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('pickDocument') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Claims a document picked since the last call, if any. Clearing is done
  /// natively on read so the same file can never be uploaded twice.
  Future<String?> _consumePendingDocument() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('consumePendingDocument');
      return result?['path'] as String?;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Camera counterpart of the above: image_picker's documented recovery
  /// path for "the Activity was destroyed while the camera was open".
  /// Returns null when there's nothing pending or the pick was cancelled.
  Future<String?> _consumeLostCameraShot() async {
    if (!Platform.isAndroid) return null;
    try {
      final lost = await ImagePicker().retrieveLostData();
      if (lost.isEmpty || lost.file == null) return null;
      return lost.file!.path;
    } catch (_) {
      return null;
    }
  }

  /// Uploads anything that was picked but never made it through, then
  /// clears the stored target. Safe (and cheap) to call unconditionally on
  /// every startup and every resume: with nothing pending it's two quick
  /// platform calls that return null. Returns the task id it uploaded to,
  /// so the caller can refresh that task's UI, or null if there was
  /// nothing to recover.
  Future<String?> recoverPendingUpload() async {
    if (!Platform.isAndroid) return null;

    final taskId = await _pendingTarget();
    if (taskId == null) return null;

    // Fires the redirect to that task straight away -- deliberately before
    // the upload below, which can take a moment over the network. The
    // person should land on the task immediately and watch the attachment
    // appear a beat later, not wait on a network round trip staring at
    // Home first.
    pendingAttachmentTaskNotifier.value = taskId;

    final path = await _consumePendingDocument() ?? await _consumeLostCameraShot();
    // Nothing came back, so the person cancelled the picker (a still-open
    // picker means the app isn't resumed and this hasn't run yet). Drop the
    // stale target so it can't attach itself to some later, unrelated pick,
    // and release the spinner.
    if (path == null) {
      await clearPendingTarget();
      attachmentUploadingNotifier.value = false;
      return null;
    }

    await clearPendingTarget();
    attachmentUploadingNotifier.value = true;
    try {
      await uploadTaskAttachment(taskId, path);
      attachmentRecoveredNotifier.value = taskId;
      return taskId;
    } catch (_) {
      return null;
    } finally {
      attachmentUploadingNotifier.value = false;
    }
  }
}

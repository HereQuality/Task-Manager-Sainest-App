import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/pending_attachment_service.dart';
import '../core/theme.dart';
import '../providers/tasks_provider.dart';

/// Task detail's "Attach file" panel -- any file type/format (matches
/// AttachmentSchema/uploadTaskAttachment server-side), either a document
/// picked from the phone's file system or a fresh photo from the camera.
class TaskAttachmentsSection extends ConsumerStatefulWidget {
  final String taskId;
  final List<dynamic> attachments;
  const TaskAttachmentsSection({super.key, required this.taskId, required this.attachments});

  @override
  ConsumerState<TaskAttachmentsSection> createState() => _TaskAttachmentsSectionState();
}

class _TaskAttachmentsSectionState extends ConsumerState<TaskAttachmentsSection> {
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    attachmentRecoveredNotifier.addListener(_onAttachmentRecovered);
    attachmentUploadingNotifier.addListener(_onRecoveryUploadingChanged);
    // Catches a recovery that already finished (see
    // pending_attachment_service.dart) before this panel existed to hear
    // it. On phones where the Activity ISN'T torn down mid-pick (i.e. most
    // non-Vivo devices), the recovered upload can complete and flip
    // attachmentRecoveredNotifier within the same frame the router
    // redirects back to a freshly-built TaskDetailScreen -- a
    // ValueNotifier doesn't replay its value to a listener that
    // subscribes after the fact, so without this the very first attach on
    // a task silently never refreshed the panel (the file WAS uploaded,
    // the screen just never learned to show it) until a second attempt on
    // an already-mounted panel picked up a later change normally.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onAttachmentRecovered();
    });
  }

  @override
  void dispose() {
    attachmentRecoveredNotifier.removeListener(_onAttachmentRecovered);
    attachmentUploadingNotifier.removeListener(_onRecoveryUploadingChanged);
    super.dispose();
  }

  void _onRecoveryUploadingChanged() {
    if (!mounted) return;
    setState(() => _uploading = attachmentUploadingNotifier.value);
  }

  // A pick that completed via the recovery path (see
  // pending_attachment_service.dart) is uploaded from main.dart, not from
  // here -- this just refreshes the panel when that upload belonged to the
  // task currently on screen.
  void _onAttachmentRecovered() {
    final recoveredTaskId = attachmentRecoveredNotifier.value;
    if (recoveredTaskId == null || recoveredTaskId != widget.taskId) return;
    ref.invalidate(taskDetailProvider(widget.taskId));
    attachmentRecoveredNotifier.value = null;
    if (mounted) {
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attachment uploaded')),
      );
    }
  }

  Future<void> _upload(String path) async {
    setState(() => _uploading = true);
    try {
      await uploadTaskAttachment(widget.taskId, path);
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not upload this file.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // Both pickers below are wrapped in try/catch, not just the upload step
  // in _upload() -- picking itself can throw (camera app not available/
  // denied, document provider hiccup, person backing out mid-pick on some
  // OEMs) and previously had nothing catching that, so the failure
  // propagated as an uncaught async error instead of a friendly message.
  //
  // Both also record which task the pick belongs to BEFORE launching, so
  // the recovery path in main.dart can finish the upload if Android
  // destroys this Activity while the picker is in the foreground -- see
  // pending_attachment_service.dart for why that happens and why the
  // target can't just be held in this widget's state.
  // A native "handle the Activity handoff ourselves" capture (mirroring
  // _chooseDocument's native document picker below) was tried here and
  // reverted: its success/failure both had to be reported through
  // recoverPendingUpload() in pending_attachment_service.dart, which only
  // ever runs from two triggers in main.dart -- app resume
  // (didChangeAppLifecycleState) or an auth-state transition. On at least
  // one Android phone tested, neither trigger fired reliably after
  // returning from the camera, which meant NEITHER an upload NOR an error
  // message ever appeared -- the capture looked like it vanished into
  // nothing. image_picker's own pickImage() below has no such dependency
  // in the common case: the Future it returns resolves directly the
  // moment onActivityResult fires, with no app-lifecycle signal in the
  // loop at all, which is why this is the primary path on every Android
  // phone again despite the (real, but comparatively rare) Activity-
  // teardown failure mode retrieveLostData() below exists to cover.
  Future<void> _takePhoto() async {
    try {
      await PendingAttachmentService.instance.setPendingTarget(widget.taskId);
      // Set before the await and cleared right after it settles (success,
      // null, or throw) -- this is what tells recoverPendingUpload() in
      // main.dart's resume handler to leave this pick alone instead of
      // racing retrieveLostData() against it. See cameraPickInFlight's own
      // doc comment for the full failure mode this fixes.
      PendingAttachmentService.instance.cameraPickInFlight = true;
      final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85);
      PendingAttachmentService.instance.cameraPickInFlight = false;
      // Reached only when the Activity survived the trip to the camera; if
      // it didn't, pending_attachment_service.dart's own
      // retrieveLostData()-based recovery picks the shot up instead once
      // the app resumes. Either way the target is cleared so only one of
      // the two ever uploads.
      await PendingAttachmentService.instance.clearPendingTarget();
      if (picked != null) await _upload(picked.path);
    } catch (e) {
      PendingAttachmentService.instance.cameraPickInFlight = false;
      await PendingAttachmentService.instance.clearPendingTarget();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the camera.')),
        );
      }
    }
  }

  Future<void> _chooseDocument() async {
    try {
      await PendingAttachmentService.instance.setPendingTarget(widget.taskId);
      // On Android this goes through the native picker in MainActivity.kt,
      // which captures the result natively (surviving the teardown) and
      // returns here immediately without one -- the upload then always runs
      // from the recovery path on resume, so the torn-down and intact cases
      // follow the exact same code path. file_selector stays the iOS route,
      // where none of this applies.
      final launchedNatively = await PendingAttachmentService.instance.pickDocument();
      // No spinner here on purpose: the native picker returns without a
      // result, and the spinner is driven by attachmentUploadingNotifier
      // once the recovery path actually starts uploading -- see that
      // notifier's own doc comment.
      if (launchedNatively) return;
      final picked = await openFile();
      await PendingAttachmentService.instance.clearPendingTarget();
      if (picked != null) await _upload(picked.path);
    } catch (e) {
      await PendingAttachmentService.instance.clearPendingTarget();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the document picker.')),
        );
      }
    }
  }

  Future<void> _openPicker() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: AppColors.indigo),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined, color: AppColors.indigo),
              title: const Text('Choose document'),
              onTap: () => Navigator.pop(ctx, 'document'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'camera') await _takePhoto();
    if (choice == 'document') await _chooseDocument();
  }

  Future<void> _delete(String attachmentId) async {
    try {
      await deleteTaskAttachment(widget.taskId, attachmentId);
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not remove this attachment.')),
        );
      }
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No app on this phone can open this file.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this file.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Attachments', style: Theme.of(context).textTheme.titleMedium)),
            if (_uploading)
              const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton.icon(
                onPressed: _openPicker,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add'),
              ),
          ],
        ),
        if (widget.attachments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text('No attachments yet.', style: Theme.of(context).textTheme.bodyMedium),
          )
        else
          for (final raw in widget.attachments)
            _AttachmentTile(
              attachment: Map<String, dynamic>.from(raw as Map),
              onTap: () {
                final url = raw['url']?.toString();
                if (url != null) _open(url);
              },
              onDelete: () => _delete(raw['_id'].toString()),
            ),
      ],
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final Map<String, dynamic> attachment;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _AttachmentTile({required this.attachment, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final mimetype = (attachment['mimetype'] ?? '').toString();
    final isImage = mimetype.startsWith('image/');
    final name = attachment['originalName']?.toString() ?? 'File';
    final url = attachment['url']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(color: AppColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.sm),
          child: Row(
            children: [
              if (isImage && url != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    url, width: 40, height: 40, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: AppColors.inkMuted),
                  ),
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: AppColors.neutralSoft, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.insert_drive_file_outlined, color: AppColors.inkMuted),
                ),
              const SizedBox(width: Gap.md),
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.inkMuted),
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/tasks_provider.dart';

/// Task detail's comment thread -- text messages and recorded voice
/// messages, back-to-back in one conversation (Task.js's `comments`
/// array, oldest-first). A tap-to-record-then-review flow (start, see a
/// live timer, then either Cancel or Send) rather than press-and-hold --
/// easier to get right one-handed than a hold gesture, and gives a
/// chance to back out before actually sending.
class TaskCommentsSection extends ConsumerStatefulWidget {
  final String taskId;
  final List<dynamic> comments;
  const TaskCommentsSection({super.key, required this.taskId, required this.comments});

  @override
  ConsumerState<TaskCommentsSection> createState() => _TaskCommentsSectionState();
}

class _TaskCommentsSectionState extends ConsumerState<TaskCommentsSection> {
  final _textCtrl = TextEditingController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _sending = false;
  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTicker;
  String? _playingCommentId;

  @override
  void dispose() {
    _textCtrl.dispose();
    _recordTicker?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final message = _textCtrl.text.trim();
    if (message.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await addTaskTextComment(widget.taskId, message);
      _textCtrl.clear();
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send this message.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is needed to record a voice message.')),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    // aacLc/.m4a -- widely supported for playback, and the `mime`
    // package (used by MultipartFile.lookupMediaType when this gets
    // uploaded) resolves .m4a to "audio/mp4", which passes the server's
    // audio-only filter (upload.middleware.js).
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _recording = true;
      _recordElapsed = Duration.zero;
    });
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordElapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _cancelRecording() async {
    _recordTicker?.cancel();
    await _recorder.cancel();
    if (mounted) {
      setState(() {
        _recording = false;
        _recordElapsed = Duration.zero;
      });
    }
  }

  Future<void> _stopAndSendRecording() async {
    _recordTicker?.cancel();
    final path = await _recorder.stop();
    final duration = _recordElapsed;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordElapsed = Duration.zero;
      });
    }
    if (path == null || duration.inSeconds < 1) return; // accidental tap, nothing worth sending

    setState(() => _sending = true);
    try {
      await addTaskAudioComment(widget.taskId, path, durationSeconds: duration.inSeconds);
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send this voice message.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _togglePlay(String commentId, String url) async {
    if (_playingCommentId == commentId) {
      await _player.stop();
      if (mounted) setState(() => _playingCommentId = null);
      return;
    }
    try {
      await _player.setUrl(url);
      setState(() => _playingCommentId = commentId);
      await _player.play();
      _player.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed).then((_) {
        if (mounted) setState(() => _playingCommentId = null);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _playingCommentId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play this voice message.')),
        );
      }
    }
  }

  Future<void> _delete(String commentId) async {
    try {
      await deleteTaskComment(widget.taskId, commentId);
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete this message.')),
        );
      }
    }
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = ref.watch(authProvider).user?.id;
    final dateFmt = DateFormat('MMM d, h:mm a');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Messages', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        if (widget.comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text('No messages yet.', style: Theme.of(context).textTheme.bodyMedium),
          )
        else
          for (final raw in widget.comments)
            _CommentBubble(
              comment: Map<String, dynamic>.from(raw as Map),
              dateFmt: dateFmt,
              isPlaying: _playingCommentId == (raw['_id']?.toString()),
              // Only the currently-playing bubble needs a live position --
              // every other bubble gets null here and just shows its
              // static duration label instead of a scrubber.
              player: _playingCommentId == (raw['_id']?.toString()) ? _player : null,
              onPlayToggle: raw['type'] == 'audio' && raw['audioUrl'] != null
                  ? () => _togglePlay(raw['_id'].toString(), raw['audioUrl'].toString())
                  : null,
              onSeek: (pos) => _player.seek(pos),
              onDelete: (raw['authorId']?.toString()) == currentUserId ? () => _delete(raw['_id'].toString()) : null,
            ),
        const SizedBox(height: Gap.sm),
        if (_recording)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(color: AppColors.dangerSoft, borderRadius: BorderRadius.circular(AppRadius.field)),
            child: Row(
              children: [
                const Icon(Icons.fiber_manual_record_rounded, color: AppColors.danger, size: 14),
                const SizedBox(width: Gap.sm),
                Text('Recording ${_fmtDuration(_recordElapsed)}', style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close_rounded, color: AppColors.inkMuted), onPressed: _cancelRecording),
                IconButton(icon: const Icon(Icons.check_circle_rounded, color: AppColors.indigo), onPressed: _stopAndSendRecording),
              ],
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  decoration: const InputDecoration(labelText: 'Write a message...'),
                  minLines: 1,
                  maxLines: 4,
                  enabled: !_sending,
                ),
              ),
              const SizedBox(width: Gap.sm),
              IconButton(
                icon: const Icon(Icons.mic_rounded),
                onPressed: _sending ? null : _startRecording,
                color: AppColors.indigo,
              ),
              IconButton.filled(
                icon: const Icon(Icons.send_rounded, size: 18),
                onPressed: _sending ? null : _sendText,
              ),
            ],
          ),
      ],
    );
  }
}

class _CommentBubble extends StatelessWidget {
  final Map<String, dynamic> comment;
  final DateFormat dateFmt;
  final bool isPlaying;
  // Only set (non-null) for the bubble that's actually playing -- lets this
  // bubble stream live position/duration for the WhatsApp-style scrubber
  // without every other bubble subscribing to the same player pointlessly.
  final AudioPlayer? player;
  final VoidCallback? onPlayToggle;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onDelete;

  const _CommentBubble({
    required this.comment,
    required this.dateFmt,
    required this.isPlaying,
    this.player,
    this.onPlayToggle,
    this.onSeek,
    this.onDelete,
  });

  String _fmt(Duration d) {
    if (d.isNegative) return '0:00';
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final author = comment['authorName']?.toString() ?? 'Someone';
    final type = comment['type']?.toString();
    final message = comment['message']?.toString() ?? '';
    final createdAt = comment['createdAt']?.toString();
    final parsed = createdAt == null ? null : DateTime.tryParse(createdAt)?.toLocal();
    final durationSeconds = comment['audioDurationSeconds'];
    final knownDuration = durationSeconds != null
        ? Duration(seconds: (durationSeconds as num).toInt())
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(author, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink))),
              if (parsed != null) Text(dateFmt.format(parsed), style: const TextStyle(fontSize: 11, color: AppColors.inkMuted)),
              if (onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.inkMuted),
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (type == 'audio')
            Row(
              children: [
                IconButton.filled(
                  onPressed: onPlayToggle,
                  icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 18),
                  style: IconButton.styleFrom(backgroundColor: AppColors.indigo, minimumSize: const Size(32, 32)),
                ),
                const SizedBox(width: Gap.sm),
                // While this bubble is the one playing, `player` is set and
                // this streams live position/duration into a draggable
                // scrubber (WhatsApp-style). Every other bubble (player ==
                // null) just shows its static duration label -- no player
                // has run for it yet, so there's no position to show.
                if (player != null)
                  Expanded(
                    child: StreamBuilder<Duration>(
                      stream: player!.positionStream,
                      builder: (context, snapshot) {
                        final position = snapshot.data ?? Duration.zero;
                        final total = player!.duration ?? knownDuration ?? Duration.zero;
                        final maxMs = total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0;
                        final valueMs = position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();
                        return Row(
                          children: [
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                ),
                                child: Slider(
                                  value: valueMs,
                                  max: maxMs,
                                  activeColor: AppColors.indigo,
                                  onChanged: onSeek == null
                                      ? null
                                      : (v) => onSeek!(Duration(milliseconds: v.toInt())),
                                ),
                              ),
                            ),
                            Text(
                              '${_fmt(position)} / ${_fmt(total)}',
                              style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
                            ),
                          ],
                        );
                      },
                    ),
                  )
                else
                  Text(
                    knownDuration != null ? _fmt(knownDuration) : 'Voice message',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
              ],
            )
          else
            Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink)),
        ],
      ),
    );
  }
}

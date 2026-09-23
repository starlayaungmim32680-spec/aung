// Music for stories. Stories reuse the app's existing user-generated
// sounds catalog (the `sounds` collection - see sounds_library_screen.dart
// and upload_screen.dart), so every track here is another creator's own
// uploaded audio, never licensed label music.
//
// Unlike feed posts (where a borrowed sound would have to be baked into
// the uploaded video file), a story never mixes audio into the media
// itself: the story doc just stores which sound + which window of it to
// play, and the story viewer plays that sound on its own player while
// muting the story's video. That works the same for photo and video
// stories and needs no server-side processing.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'sounds_library_screen.dart';
import 'sound_sync_sheet.dart';

// How long a photo story with music stays on screen (and how long a
// window of the song it plays). Matches the 15s video story cap.
const double kStoryMusicClipSeconds = 15;

class StoryMusicSelection {
  final String soundId;
  final String title;
  final String ownerName;
  final String sourceUrl;
  // Where in the sound playback starts, in seconds.
  final double startOffset;

  const StoryMusicSelection({
    required this.soundId,
    required this.title,
    required this.ownerName,
    required this.sourceUrl,
    required this.startOffset,
  });

  // Fields written onto the story doc.
  Map<String, dynamic> toStoryFields() => {
        'soundId': soundId,
        'soundTitle': title,
        'soundOwnerName': ownerName,
        'soundSourceUrl': sourceUrl,
        'soundStartOffset': startOffset,
      };
}

// Loads just enough of [url] to read its duration, then disposes it.
Future<double?> probeSoundDurationSeconds(String url) async {
  if (url.isEmpty) return null;
  VideoPlayerController? controller;
  try {
    controller = VideoPlayerController.networkUrl(Uri.parse(url));
    await controller.initialize();
    return controller.value.duration.inMilliseconds / 1000;
  } catch (_) {
    return null;
  } finally {
    await controller?.dispose();
  }
}

// Opens the sounds library, then (if the song is longer than the clip)
// the "choose part of the song" sheet. Returns null if the user backs out
// of the library. Backing out of the sync sheet keeps the sound and just
// starts it from 0:00, same as upload_screen.dart.
Future<StoryMusicSelection?> pickStoryMusic(
  BuildContext context, {
  required double clipSeconds,
}) async {
  final Map<String, String>? result = await Navigator.push<Map<String, String>>(
    context,
    MaterialPageRoute(builder: (_) => const SoundsLibraryScreen()),
  );
  if (result == null) return null;

  final String sourceUrl = result['sourceUrl'] ?? '';
  final String soundId = result['soundId'] ?? '';
  if (sourceUrl.isEmpty || soundId.isEmpty) return null;

  double startOffset = 0;
  final double? soundDuration = await probeSoundDurationSeconds(sourceUrl);
  if (soundDuration != null && soundDuration > clipSeconds + 0.5) {
    if (!context.mounted) return null;
    final double? chosen = await showSoundSyncSheet(
      context: context,
      soundTitle: result['title'] ?? 'Original sound',
      soundSourceUrl: sourceUrl,
      soundDurationSeconds: soundDuration,
      videoDurationSeconds: clipSeconds,
    );
    if (chosen != null) startOffset = chosen;
  }

  return StoryMusicSelection(
    soundId: soundId,
    title: result['title'] ?? 'Original sound',
    ownerName: result['ownerName'] ?? '',
    sourceUrl: sourceUrl,
    startOffset: startOffset,
  );
}

// Plays one window of a sound ([startOffset] .. startOffset+clipSeconds)
// on a loop. The sound's source is a video/HLS URL, so a video controller
// plays it - its picture is simply never rendered.
class StoryMusicPlayer {
  VideoPlayerController? _controller;
  Timer? _loopTimer;
  double _start = 0;
  double _clip = kStoryMusicClipSeconds;
  bool _disposed = false;
  // Bumped on every load so a slow, superseded load never starts playing
  // after a newer one (or after dispose).
  int _loadToken = 0;

  bool get isReady => _controller?.value.isInitialized == true;

  Future<void> load(
    String url, {
    required double startOffset,
    required double clipSeconds,
    bool autoPlay = true,
  }) async {
    final int token = ++_loadToken;
    await _release();
    if (url.isEmpty) return;

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      return;
    }
    if (_disposed || token != _loadToken) {
      await controller.dispose();
      return;
    }

    _controller = controller;
    _start = startOffset;
    final double total = controller.value.duration.inMilliseconds / 1000;
    // Never loop past the end of the sound itself.
    final double remaining = total - _start;
    _clip =
        (remaining > 1 && remaining < clipSeconds) ? remaining : clipSeconds;
    // Native looping covers a window that runs to the very end of the
    // sound (it restarts at 0:00, which the loop timer then moves back to
    // the window start); the timer covers every other case.
    await controller.setLooping(true);
    await controller.seekTo(_ms(_start));
    if (autoPlay) await play();
  }

  Future<void> play() async {
    final c = _controller;
    if (c == null) return;
    await c.play();
    _startLoopTimer();
  }

  Future<void> pause() async {
    _loopTimer?.cancel();
    await _controller?.pause();
  }

  // Jumps back to the start of the window (e.g. when a video it's paired
  // with loops, or a story restarts).
  Future<void> restart() async {
    await _controller?.seekTo(_ms(_start));
  }

  // Checks position a few times a second and wraps back to the window
  // start - cheaper and more reliable than a position listener firing on
  // every frame.
  void _startLoopTimer() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final double pos = c.value.position.inMilliseconds / 1000;
      if (pos >= _start + _clip || pos < _start - 0.5) {
        c.seekTo(_ms(_start));
      }
    });
  }

  Future<void> _release() async {
    _loopTimer?.cancel();
    _loopTimer = null;
    final c = _controller;
    _controller = null;
    await c?.dispose();
  }

  // Stops and unloads the current sound, and cancels any load still in
  // flight so it can't start playing later.
  Future<void> stop() async {
    _loadToken++;
    await _release();
  }

  Future<void> dispose() async {
    _disposed = true;
    _loadToken++;
    await _release();
  }

  static Duration _ms(double seconds) =>
      Duration(milliseconds: (seconds * 1000).round());
}

// "♪ Title · Owner" pill used in the editors and the story viewer.
class StoryMusicChip extends StatelessWidget {
  final String title;
  final String ownerName;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const StoryMusicChip({
    super.key,
    required this.title,
    required this.ownerName,
    this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final String label = ownerName.isNotEmpty ? '$title · $ownerName' : title;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: EdgeInsets.fromLTRB(10, 5, onRemove != null ? 4 : 12, 5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, color: Colors.white, size: 15),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ),
            if (onRemove != null)
              GestureDetector(
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.close, color: Colors.white70, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

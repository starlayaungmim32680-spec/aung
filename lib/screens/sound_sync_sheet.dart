// Lets the user pick which video-length window of a song plays under
// their video, instead of always starting from 0:00 - matches TikTok's
// "choose part of the song" step. Only meaningful when the song is
// longer than the video; see upload_screen.dart, which only opens this
// when that's the case.
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

// Returns the chosen start offset in seconds, or null if cancelled.
Future<double?> showSoundSyncSheet({
  required BuildContext context,
  required String soundTitle,
  required String soundSourceUrl,
  required double soundDurationSeconds,
  required double videoDurationSeconds,
}) {
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    isScrollControlled: true,
    builder: (_) => _SoundSyncSheet(
      soundTitle: soundTitle,
      soundSourceUrl: soundSourceUrl,
      soundDurationSeconds: soundDurationSeconds,
      videoDurationSeconds: videoDurationSeconds,
    ),
  );
}

class _SoundSyncSheet extends StatefulWidget {
  final String soundTitle;
  final String soundSourceUrl;
  final double soundDurationSeconds;
  final double videoDurationSeconds;

  const _SoundSyncSheet({
    required this.soundTitle,
    required this.soundSourceUrl,
    required this.soundDurationSeconds,
    required this.videoDurationSeconds,
  });

  @override
  State<_SoundSyncSheet> createState() => _SoundSyncSheetState();
}

class _SoundSyncSheetState extends State<_SoundSyncSheet> {
  VideoPlayerController? _controller;
  double _startOffset = 0;
  bool _loading = true;

  double get _maxOffset =>
      (widget.soundDurationSeconds - widget.videoDurationSeconds)
          .clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final controller =
          VideoPlayerController.networkUrl(Uri.parse(widget.soundSourceUrl));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _previewFromOffset() async {
    final controller = _controller;
    if (controller == null) return;
    await controller
        .seekTo(Duration(milliseconds: (_startOffset * 1000).round()));
    await controller.play();
    // Auto-stop after roughly the video's own length, so the preview
    // matches what viewers would actually hear.
    Future.delayed(
      Duration(milliseconds: (widget.videoDurationSeconds * 1000).round()),
      () {
        if (mounted && controller.value.isPlaying) controller.pause();
      },
    );
  }

  String _fmt(double seconds) {
    final int s = seconds.round();
    final int m = s ~/ 60;
    final int r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync "${widget.soundTitle}"',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              'Your video is ${_fmt(widget.videoDurationSeconds)} - pick which '
              'part of the song plays under it.',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(color: Colors.redAccent),
                ),
              )
            else if (_maxOffset <= 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  "This song isn't longer than your video, so there's "
                  "nothing to pick - it'll just play from the start.",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              )
            else ...[
              Row(
                children: [
                  IconButton(
                    onPressed: _previewFromOffset,
                    icon: const Icon(Icons.play_arrow, color: Colors.redAccent),
                  ),
                  Expanded(
                    child: Slider(
                      value: _startOffset.clamp(0, _maxOffset),
                      min: 0,
                      max: _maxOffset,
                      activeColor: Colors.redAccent,
                      inactiveColor: Colors.white24,
                      onChanged: (v) => setState(() => _startOffset = v),
                      onChangeEnd: (_) => _previewFromOffset(),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(_startOffset),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    Text(_fmt(widget.soundDurationSeconds),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  _controller?.pause();
                  Navigator.pop(context, _startOffset);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Use this part',
                    style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

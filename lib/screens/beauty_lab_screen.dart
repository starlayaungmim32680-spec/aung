// Beauty Lab (9 Nov 2026, Fly Dev only) - tries the GPUPixel beauty
// engine (native, android/app/src/dev/kotlin/com/aungdev/fly/BeautyLab.kt)
// on Ko's phone: front camera with Smooth / White / Thin face / Big eyes /
// Lipstick / Blush, plus the frames per second, to compare with TikTok
// before it goes into the Record camera. Opened from the Upload screen's
// flask button (dev app only). 10 Nov 2026: a Record button writes the
// beautified frames + sound into an mp4 (native BeautyRecorder.kt) and
// plays it back (_LabReview) to check the beauty is really in the file.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

class BeautyLabScreen extends StatefulWidget {
  const BeautyLabScreen({super.key});

  @override
  State<BeautyLabScreen> createState() => _BeautyLabScreenState();
}

class _BeautyLabScreenState extends State<BeautyLabScreen> {
  static const MethodChannel _ch = MethodChannel('fly/beauty_lab');

  int? _textureId;
  double _aspect = 9 / 16;
  String? _error;
  double _fps = 0;
  Timer? _fpsTimer;
  bool _showPanel = true;
  bool _recording = false;
  bool _busy = false;
  final Stopwatch _recWatch = Stopwatch();

  final Map<String, double> _v = {
    'smooth': 0.7,
    'white': 0.3,
    'thin': 0.5,
    'eyes': 0.4,
    'lips': 0.0,
    'blush': 0.0,
  };

  static const Map<String, String> _labels = {
    'smooth': 'Smooth',
    'white': 'White',
    'thin': 'Thin face',
    'eyes': 'Big eyes',
    'lips': 'Lipstick',
    'blush': 'Blush',
  };

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // 10 Nov 2026: the lab opens the camera itself (native Camera2), so it
    // must ask for the camera permission itself too - without it Android
    // throws SecurityException "cannot open camera without camera
    // permission" (seen on Ko's phone).
    final PermissionStatus cam = await Permission.camera.request();
    if (!cam.isGranted) {
      if (mounted) {
        setState(() => _error = cam.isPermanentlyDenied
            ? 'Camera permission is off for Fly Dev. Turn it on in Settings.'
            : 'Beauty Lab needs the camera permission.');
      }
      if (cam.isPermanentlyDenied) await openAppSettings();
      return;
    }
    try {
      final Map<dynamic, dynamic>? r =
          await _ch.invokeMapMethod<dynamic, dynamic>('start');
      if (!mounted || r == null) return;
      final int w = (r['width'] as num).toInt();
      final int h = (r['height'] as num).toInt();
      setState(() {
        _textureId = (r['textureId'] as num).toInt();
        if (w > 0 && h > 0) _aspect = w / h;
      });
      await _send();
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          final double? f = await _ch.invokeMethod<double>('fps');
          if (mounted && f != null) setState(() => _fps = f);
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Beauty Lab could not start: $e');
    }
  }

  Future<void> _send() async {
    try {
      await _ch.invokeMethod('set', _v);
    } catch (_) {}
  }

  void _preset(double s, double w, double t, double e, double l, double b) {
    setState(() {
      _v['smooth'] = s;
      _v['white'] = w;
      _v['thin'] = t;
      _v['eyes'] = e;
      _v['lips'] = l;
      _v['blush'] = b;
    });
    _send();
  }

  Future<void> _toggleRecord() async {
    if (_busy || _textureId == null) return;
    setState(() => _busy = true);
    try {
      if (!_recording) {
        final PermissionStatus mic = await Permission.microphone.request();
        await _ch.invokeMethod('startRecording', {'audio': mic.isGranted});
        _recWatch
          ..reset()
          ..start();
        HapticFeedback.heavyImpact();
        if (mounted) setState(() => _recording = true);
      } else {
        final String? path = await _ch.invokeMethod<String>('stopRecording');
        _recWatch.stop();
        if (mounted) setState(() => _recording = false);
        if (!mounted) return;
        if (path == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Recording failed - no video file.')));
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => _LabReview(path: path)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Record error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _ch.invokeMethod('stop').catchError((_) => null);
    super.dispose();
  }

  Widget _chip(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int? id = _textureId;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (id != null)
            Center(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: 720,
                  height: 720 / _aspect,
                  // Selfie mirror.
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.rotationY(pi),
                    child: Texture(textureId: id),
                  ),
                ),
              ),
            )
          else
            Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white)),
                    ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Beauty Lab (GPUPixel)',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4)
                          ])),
                  const Spacer(),
                  Text(
                      _recording
                          ? 'REC ${_recWatch.elapsed.inSeconds}s  '
                              '${_fps.toStringAsFixed(0)} fps'
                          : '${_fps.toStringAsFixed(0)} fps',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4)
                          ])),
                  IconButton(
                    icon: Icon(
                        _showPanel ? Icons.visibility_off : Icons.tune,
                        color: Colors.white),
                    onPressed: () => setState(() => _showPanel = !_showPanel),
                  ),
                ],
              ),
            ),
          ),
          ),
          if (_showPanel)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _chip('Off', () => _preset(0, 0, 0, 0, 0, 0)),
                            _chip('Natural',
                                () => _preset(0.5, 0.2, 0.3, 0.2, 0, 0)),
                            _chip('TikTok-ish',
                                () => _preset(0.8, 0.4, 0.6, 0.5, 0.2, 0.2)),
                            _chip('Max', () => _preset(1, 0.7, 1, 1, 0.4, 0.4)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _toggleRecord,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          alignment: Alignment.center,
                          child: _busy
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 3, color: Colors.white))
                              : AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: _recording ? 24 : 48,
                                  height: _recording ? 24 : 48,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF4B6E),
                                    borderRadius: BorderRadius.circular(
                                        _recording ? 6 : 24),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final String k in _labels.keys)
                        Row(
                          children: [
                            SizedBox(
                              width: 70,
                              child: Text(_labels[k]!,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                            ),
                            Expanded(
                              child: Slider(
                                value: _v[k]!,
                                activeColor: const Color(0xFFFF4B6E),
                                onChanged: (x) {
                                  setState(() => _v[k] = x);
                                  _send();
                                },
                              ),
                            ),
                            SizedBox(
                              width: 28,
                              child: Text('${(_v[k]! * 100).round()}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Plays the recorded lab video (looping) - the beauty must be in it.
class _LabReview extends StatefulWidget {
  final String path;
  const _LabReview({required this.path});

  @override
  State<_LabReview> createState() => _LabReviewState();
}

class _LabReviewState extends State<_LabReview> {
  late final VideoPlayerController _c =
      VideoPlayerController.file(File(widget.path));
  String _info = '';

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (!mounted) return;
      final int kb = File(widget.path).lengthSync() ~/ 1024;
      setState(() => _info =
          '${_c.value.size.width.toInt()}x${_c.value.size.height.toInt()}  '
          '${_c.value.duration.inMilliseconds / 1000}s  $kb KB');
      _c
        ..setLooping(true)
        ..play();
    }).catchError((Object e) {
      if (mounted) setState(() => _info = 'Cannot play: $e');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Recorded (beauty in the file)'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _c.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: _c.value.aspectRatio,
                      child: VideoPlayer(_c),
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_info, style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

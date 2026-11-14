// Fly Camera with the GPUPixel beauty engine (11 Nov 2026) - the Record
// camera (Upload -> Record Short / Record Video). Ko tested GPUPixel in the
// Beauty Lab ("not far from TikTok"), so it becomes the real camera here.
// 14 Nov 2026: used by BOTH flavors (dev and prod); the dev read-out
// (ISO / shutter / fps) was removed for prod.
//   - Native (android/app/src/main/kotlin/com/aungdev/fly/BeautyLab.kt,
//     channel "fly/beauty_lab"): Camera2 -> face landmarks -> lipstick /
//     blush / smoothing / whiteness / thin face / big eyes -> Flutter
//     texture; BeautyRecorder.kt writes the SAME frames + the microphone
//     into an mp4, so the beauty is IN the video file (every viewer, any
//     phone, sees it).
//   - TikTok-style clean screen (12 Nov): right column Flip / Timer /
//     Beauty / Filters / Light / Grid; one panel at a time, tap the camera
//     to close it. Beauty = presets Off / Natural (default) / Glow / Doll
//     + Night, six items with ONE slider for the selected item.
//   - Filters panel: the 23 Fly Looks on top (colour, applied at playback
//     like before - saved in the look string with Night), swipe left /
//     right on the camera to change.
//   - Timer 3 / 10 s, Light (camera brightness + white Ring light), Night
//     (on / off, lifts dark videos at playback), Grid, front / back.
//   - Record ring + time, auto-stop at 60 s, then the usual Trim ->
//     Effects -> Post (returns the mp4 like FaceFilterCameraScreen did).
// FaceFilterCameraScreen stays in the code (lastLook / takeLook /
// kMaxRecording are shared from it) but is no longer opened for recording.
import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'face_filter_camera_screen.dart' show FaceFilterCameraScreen, kMaxRecording;
import 'video_filters.dart';

class GpuCameraScreen extends StatefulWidget {
  const GpuCameraScreen({super.key});

  @override
  State<GpuCameraScreen> createState() => _GpuCameraScreenState();
}

class _GpuCameraScreenState extends State<GpuCameraScreen>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _ch = MethodChannel('fly/beauty_lab');

  int? _textureId;
  double _aspect = 9 / 16;
  bool _front = true;
  String? _error;

  // Beauty (GPUPixel). Presets: 0 Off, 1 Natural, 2 Glow, 3 Doll, 4 Glam,
  // -1 Custom (a slider was moved). 12 Nov 2026: BeautyLab.kt's slim / eyes
  // ranges grew (1/12, 1/3) for Glam, so Natural / Glow / Doll use smaller
  // numbers for the same look as before.
  static const int _custom = -1;
  int _preset = 1;
  final Map<String, double> _v = {
    'smooth': 0.55,
    'white': 0.25,
    'thin': 0.26,
    'eyes': 0.19,
    'lips': 0.15,
    'blush': 0.1,
  };
  static const List<String> _presetNames = [
    'Off', 'Natural', 'Glow', 'Doll', 'Glam',
  ];
  static const List<Map<String, double>> _presets = [
    {'smooth': 0, 'white': 0, 'thin': 0, 'eyes': 0, 'lips': 0, 'blush': 0},
    {
      'smooth': 0.55, 'white': 0.25, 'thin': 0.26, 'eyes': 0.19,
      'lips': 0.15, 'blush': 0.1,
    },
    {
      'smooth': 0.75, 'white': 0.4, 'thin': 0.38, 'eyes': 0.3,
      'lips': 0.25, 'blush': 0.25,
    },
    {
      'smooth': 0.9, 'white': 0.5, 'thin': 0.56, 'eyes': 0.49,
      'lips': 0.35, 'blush': 0.35,
    },
    // Glam - everything near the top.
    {
      'smooth': 1.0, 'white': 0.6, 'thin': 1.0, 'eyes': 0.85,
      'lips': 0.45, 'blush': 0.4,
    },
  ];
  static const Map<String, String> _labels = {
    'smooth': 'Smooth',
    'white': 'White',
    'thin': 'Slim',
    'eyes': 'Eyes',
    'lips': 'Lips',
    'blush': 'Blush',
  };

  // Looks / tools. One bottom panel at a time (TikTok style - the camera
  // stays clear until Ko taps Beauty / Filters / Light on the right).
  int _lookIndex = 0;
  bool _night = false;
  int _panel = 0; // 0 none, 1 Beauty, 2 Filters, 3 Light
  String _beautyKey = 'smooth';
  bool _grid = false;
  bool _ringLight = false;
  double _exposure = 0;
  int _timerSeconds = 0;
  int? _countdown;
  Timer? _countdownTimer;
  final ValueNotifier<String?> _flashName = ValueNotifier<String?>(null);
  Timer? _flashTimer;

  bool _recording = false;
  bool _busy = false;
  late final AnimationController _rec = AnimationController(
    vsync: this,
    duration: kMaxRecording,
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed && _recording) _toggleRecording();
    });

  String get _look => makeLook(
        kFlyFilters[_lookIndex].id,
        0,
        BeautySettings(night: _night ? 0.7 : 0),
      );

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final PermissionStatus cam = await Permission.camera.request();
    if (!cam.isGranted) {
      if (mounted) {
        setState(() => _error = 'Fly needs the camera permission.');
      }
      if (cam.isPermanentlyDenied) await openAppSettings();
      return;
    }
    await Permission.microphone.request();
    try {
      final Map<dynamic, dynamic>? r =
          await _ch.invokeMapMethod<dynamic, dynamic>('start', {'front': true});
      if (!mounted || r == null) return;
      _applySize(r);
      setState(() => _textureId = (r['textureId'] as num).toInt());
      await _sendBeauty();
    } catch (e) {
      debugPrint('GpuCameraScreen start failed: $e');
      if (mounted) {
        setState(() => _error =
            "The camera couldn't start on this phone. Please close it and try again.");
      }
    }
  }

  void _applySize(Map<dynamic, dynamic> r) {
    final int w = (r['width'] as num).toInt();
    final int h = (r['height'] as num).toInt();
    _front = r['front'] == true;
    if (w > 0 && h > 0) _aspect = w / h;
  }

  // 14 Nov 2026: the Ring light works like TikTok's front flash - a thick
  // white frame AND the screen at full brightness (back to normal when off
  // or when the camera closes).
  void _setRingLight(bool on) {
    setState(() => _ringLight = on);
    _ch.invokeMethod('screenBright', {'on': on}).catchError((_) => null);
  }

  Future<void> _sendBeauty() async {
    try {
      await _ch.invokeMethod('set', _v);
    } catch (_) {}
  }

  void _setPreset(int i) {
    HapticFeedback.selectionClick();
    setState(() {
      _preset = i;
      _v.addAll(_presets[i]);
    });
    _sendBeauty();
  }

  Future<void> _switchCamera() async {
    if (_recording || _countdown != null) return;
    try {
      final Map<dynamic, dynamic>? r =
          await _ch.invokeMapMethod<dynamic, dynamic>('switchCamera');
      if (r != null && mounted) setState(() => _applySize(r));
    } catch (_) {}
  }

  void _setLook(int index) {
    final int i = index.clamp(0, kFlyFilters.length - 1);
    if (i == _lookIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _lookIndex = i);
    _flashName.value = kFlyFilters[i].name;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      _flashName.value = null;
    });
  }

  void _onSwipe(DragEndDetails d) {
    if (_recording) return;
    final double v = d.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    _setLook(_lookIndex + (v < 0 ? 1 : -1));
  }

  // ------------------------------------------------------------ record
  void _onRecordTap() {
    if (_countdown != null) {
      _countdownTimer?.cancel();
      setState(() => _countdown = null);
      return;
    }
    if (!_recording && _timerSeconds > 0) {
      setState(() => _countdown = _timerSeconds);
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        final int left = (_countdown ?? 1) - 1;
        if (left <= 0) {
          t.cancel();
          setState(() => _countdown = null);
          _toggleRecording();
        } else {
          HapticFeedback.selectionClick();
          setState(() => _countdown = left);
        }
      });
      return;
    }
    _toggleRecording();
  }

  Future<void> _toggleRecording() async {
    if (_busy || _textureId == null) return;
    setState(() => _busy = true);
    try {
      if (!_recording) {
        final bool mic = await Permission.microphone.isGranted;
        await _ch.invokeMethod('startRecording', {'audio': mic});
        HapticFeedback.heavyImpact();
        setState(() {
          _recording = true;
          _panel = 0;
        });
        _rec.forward(from: 0);
      } else {
        _rec.stop();
        HapticFeedback.mediumImpact();
        final String? path = await _ch
            .invokeMethod<String>('stopRecording')
            .timeout(const Duration(seconds: 12));
        if (!mounted) return;
        setState(() => _recording = false);
        if (path == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Could not save the video - please try again.')));
          return;
        }
        FaceFilterCameraScreen.lastLook = _look;
        Navigator.pop(context, XFile(path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recording error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    if (_ringLight) {
      _ch.invokeMethod('screenBright', {'on': false}).catchError((_) => null);
    }
    _countdownTimer?.cancel();
    _flashTimer?.cancel();
    _flashName.dispose();
    _rec.dispose();
    _ch.invokeMethod('stop').catchError((_) => null);
    super.dispose();
  }

  // ---------------------------------------------------------------- UI
  Widget _round(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration:
            const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _tool(IconData icon, String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? const Color(0xFFFF4B6E) : Colors.black38,
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 3),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          gradient: on
              ? const LinearGradient(
                  colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)])
              : null,
          color: on ? null : Colors.black45,
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

  void _togglePanel(int p) {
    setState(() => _panel = _panel == p ? 0 : p);
  }

  static const Map<String, IconData> _icons = {
    'smooth': Icons.blur_on_rounded,
    'white': Icons.light_mode_outlined,
    'thin': Icons.face_outlined,
    'eyes': Icons.remove_red_eye_outlined,
    'lips': Icons.favorite_border_rounded,
    'blush': Icons.brush_outlined,
  };

  Widget _panelBox(Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
    );
  }

  Widget _beautyItem(String key) {
    final bool on = key == _beautyKey;
    final bool used = _v[key]! > 0.01;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _beautyKey = key);
      },
      child: SizedBox(
        width: 52,
        child: Column(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? Colors.white : Colors.white12,
              border: Border.all(
                  color: used ? const Color(0xFFFF4B6E) : Colors.transparent,
                  width: 2),
            ),
            child: Icon(_icons[key],
                size: 20, color: on ? Colors.black : Colors.white),
          ),
          const SizedBox(height: 3),
          Text(_labels[key]!,
              style: TextStyle(
                  color: on ? Colors.white : Colors.white70,
                  fontSize: 10.5,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _beautyPanel() {
    final String k = _beautyKey;
    return _panelBox(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // One slider - for the selected item (like TikTok).
        Row(children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFFFF4B6E),
                thumbColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: _v[k]!,
                onChanged: (x) {
                  setState(() {
                    _v[k] = x;
                    _preset = _custom;
                  });
                  _sendBeauty();
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Text('${(_v[k]! * 100).round()}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (int i = 0; i < _presetNames.length; i++)
              _chip(_presetNames[i], _preset == i, () => _setPreset(i)),
            _chip('Night', _night,
                () => setState(() => _night = !_night)),
          ]),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [for (final String key in _labels.keys) _beautyItem(key)],
        ),
      ],
    ));
  }

  Widget _lightPanel() {
    return _panelBox(Row(
      children: [
        const Icon(Icons.wb_sunny_outlined, color: Colors.white, size: 18),
        Expanded(
          child: Slider(
            value: _exposure,
            min: -1,
            max: 1,
            activeColor: const Color(0xFFFFD27A),
            onChanged: (v) {
              setState(() => _exposure = v);
              _ch.invokeMethod('setExposure', {'value': v})
                  .catchError((_) => null);
            },
          ),
        ),
        _chip('Ring light', _ringLight, () => _setRingLight(!_ringLight)),
      ],
    ));
  }

  Widget _filterPanel() {
    return _panelBox(SizedBox(
      height: 84,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: kFlyFilters.length,
        itemBuilder: (context, i) {
          final FlyFilter f = kFlyFilters[i];
          final bool on = i == _lookIndex;
          return GestureDetector(
            onTap: () => _setLook(i),
            child: SizedBox(
              width: 68,
              child: Column(children: [
                FilterSwatch(look: f.id, size: 56, selected: on),
                const SizedBox(height: 4),
                Text(f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: on ? Colors.white : Colors.white70,
                        fontSize: 11,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w500)),
              ]),
            ),
          );
        },
      ),
    ));
  }

  Widget _recordButton() {
    return GestureDetector(
      onTap: _onRecordTap,
      child: SizedBox(
        width: 92,
        height: 92,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: _rec,
            builder: (context, _) => CustomPaint(
              size: const Size(92, 92),
              painter: _Ring(_recording ? _rec.value : 0),
            ),
          ),
          if (_busy && _recording)
            const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                    strokeWidth: 3, color: Colors.white))
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _recording ? 34 : 64,
              height: _recording ? 34 : 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_recording ? 8 : 32),
                gradient: const LinearGradient(
                    colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)]),
              ),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int? id = _textureId;
    final bool idle = !_recording && _countdown == null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (id != null)
            GestureDetector(
              onHorizontalDragEnd: _onSwipe,
              // Tap the camera to close the open panel (TikTok style).
              onTap: () {
                if (_panel != 0) setState(() => _panel = 0);
              },
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: 720,
                    height: 720 / _aspect,
                    child: FlyLook(
                      look: _look,
                      child: _front
                          ? Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.rotationY(pi),
                              child: Texture(textureId: id),
                            )
                          : Texture(textureId: id),
                    ),
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
          if (_grid)
            const IgnorePointer(child: CustomPaint(painter: _Grid())),
          if (_ringLight)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 56),
                ),
              ),
            ),
          IgnorePointer(
            child: Center(
              child: ValueListenableBuilder<String?>(
                valueListenable: _flashName,
                builder: (context, name, _) => AnimatedOpacity(
                  opacity: name == null ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Text(name ?? '',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 10)
                          ])),
                ),
              ),
            ),
          ),
          if (_countdown != null)
            IgnorePointer(
              child: Center(
                child: Text('$_countdown',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 110,
                        fontWeight: FontWeight.w900,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 16)
                        ])),
              ),
            ),
          // Top: close + recording time.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _round(Icons.close, () => Navigator.pop(context)),
                    if (_recording)
                      AnimatedBuilder(
                        animation: _rec,
                        builder: (context, _) {
                          final int s =
                              (_rec.value * kMaxRecording.inSeconds).floor();
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.circular(14)),
                            child: Text(
                                '0:${s.toString().padLeft(2, '0')} / '
                                '${kMaxRecording.inSeconds}s',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700)),
                          );
                        },
                      ),
                    const SizedBox(width: 42),
                  ],
                ),
              ),
            ),
          ),
          // Right tools (TikTok style column).
          if (idle)
            Positioned(
              right: 8,
              top: MediaQuery.paddingOf(context).top + 8,
              child: Column(children: [
                _tool(Icons.cameraswitch_outlined, 'Flip', false,
                    _switchCamera),
                _tool(
                  Icons.timer_outlined,
                  _timerSeconds == 0 ? 'Timer' : '${_timerSeconds}s',
                  _timerSeconds > 0,
                  () => setState(() => _timerSeconds =
                      _timerSeconds == 0 ? 3 : (_timerSeconds == 3 ? 10 : 0)),
                ),
                _tool(Icons.face_retouching_natural, 'Beauty', _panel == 1,
                    () => _togglePanel(1)),
                _tool(Icons.auto_awesome, 'Filters', _panel == 2,
                    () => _togglePanel(2)),
                _tool(Icons.wb_sunny_outlined, 'Light', _panel == 3,
                    () => _togglePanel(3)),
                _tool(Icons.grid_on_rounded, 'Grid', _grid,
                    () => setState(() => _grid = !_grid)),
              ]),
            ),
          // Bottom: the open panel + record button.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (idle && _panel == 1) _beautyPanel(),
                  if (idle && _panel == 2) _filterPanel(),
                  if (idle && _panel == 3) _lightPanel(),
                  if (idle && _panel == 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                          '${kFlyFilters[_lookIndex].name}'
                          '${_preset == 0 ? '' : '  ·  Beauty on'}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 4)
                              ])),
                    ),
                  _recordButton(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Ring extends CustomPainter {
  final double progress;
  _Ring(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.width / 2 - 4;
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = Colors.white.withValues(alpha: progress > 0 ? 0.35 : 1));
    if (progress > 0) {
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          -pi / 2,
          2 * pi * progress,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xFF35E1F2));
    }
  }

  @override
  bool shouldRepaint(covariant _Ring old) => old.progress != progress;
}

class _Grid extends CustomPainter {
  const _Grid();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final double x = size.width * i / 3;
      final double y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// The Record camera (Upload -> Record Short / Record Video).
//
// 9 Nov 2026 - "Fly Looks" camera (Ko: "TikTok-like, lots of effects,
// as good as you can"), part 1 of the camera plan (Filters -> record
// tools -> screen effects -> face AR -> background):
//   - FILTERS tab: 23 colour looks (video_filters.dart) as little
//     picture thumbnails; swipe left / right on the camera to change look
//     (its name flashes in the middle, like TikTok). The look + Beauty are
//     handed to the effects screen and SAVED with the video
//     (`filterType`, e.g. "golden|b40"), so the posted video looks the
//     same as the camera - before, Beauty was camera-only.
//   - Right-hand tools: Timer (off / 3 s / 10 s countdown), Beauty
//     (slider), Grid (rule-of-thirds lines).
//   - Record button with a progress ring + time (max 60 s, stops itself).
//   - FACES tab: the old emoji face filters, unchanged for now (camera
//     only, not in the posted video - the face AR part of the plan will
//     replace them). Face detection now only runs while one is picked.
//
// 9 Nov 2026 (later) - "Fly Beauty Engine": the Beauty tool is now a GPU
// shader (shaders/fly_beauty.frag via FlyLook): presets Off / Natural
// (default) / Glow / Doll + Smooth / Bright / Rosy sliders, and Night
// (auto from how dark the picture is, or on / off) that lifts the shadows
// and cleans the noise of dark videos. Saved in the look string
// ("golden|b8|s45|g25|r10|n60") so viewers see it too.
//
// Returns the recorded XFile (as before); the chosen look is in
// [FaceFilterCameraScreen.lastLook] for the caller to read once.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'video_filters.dart';

// Simple emoji-based face filters. Each is positioned relative to the
// detected face's bounding box (top/center/bottom) rather than precise
// facial landmarks, which keeps this dependency-light while still tracking
// the face reasonably well.
enum FaceFilterType { none, sunglasses, dogEars, flowerCrown, mustache }

const Map<FaceFilterType, String> kFaceFilterEmojis = {
  FaceFilterType.sunglasses: '🕶️',
  FaceFilterType.dogEars: '🐶',
  FaceFilterType.flowerCrown: '🌸',
  FaceFilterType.mustache: '👨',
};

/// Longest recording (the upload flow trims it further if needed).
const Duration kMaxRecording = Duration(seconds: 60);

class FaceFilterCameraScreen extends StatefulWidget {
  const FaceFilterCameraScreen({super.key});

  /// The look ("golden|b40") of the last video recorded here. Read it with
  /// [takeLook] right after the screen returns a file.
  static String? lastLook;

  /// Returns [lastLook] once and clears it.
  static String takeLook() {
    final String look = lastLook ?? 'none';
    lastLook = null;
    return look;
  }

  @override
  State<FaceFilterCameraScreen> createState() => _FaceFilterCameraScreenState();
}

class _FaceFilterCameraScreenState extends State<FaceFilterCameraScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  final FaceMeshDetector _faceMeshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  bool _isDetecting = false;
  FaceMesh? _lastFace;
  Size? _lastImageSize;
  FaceFilterType _filter = FaceFilterType.none;

  // Fly Looks.
  int _lookIndex = 0;
  // 0.0 = off, 1.0 = strongest brighten/soften effect.
  // Fly Beauty Engine (GPU shader, video_filters.dart) - 9 Nov 2026.
  // Presets: 0 Off, 1 Natural (default), 2 Glow, 3 Doll, 4 Custom.
  int _beautyPreset = 1;
  double _smooth = 0.45;
  double _glow = 0.25;
  double _rosy = 0.1;
  // Night: 0 = auto (from how dark the camera picture is), 1 = on, 2 = off.
  int _nightMode = 0;
  double _autoNight = 0; // 0..1, measured from the picture
  int _frameCount = 0;
  bool _showBeauty = false;
  // Brightness (exposure compensation, EV) - recording in a dark room
  // came out much darker than the preview (9 Nov 2026), so the camera can
  // be brightened, and the front "Light" turns the screen edges into a
  // white ring light for the face.
  bool _showLight = false;
  double _exposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;
  bool _ringLight = false;
  bool _grid = false;
  int _timerSeconds = 0; // 0 / 3 / 10
  int? _countdown; // seconds left before recording starts
  Timer? _countdownTimer;
  int _tab = 0; // 0 = Filters, 1 = Faces
  final ValueNotifier<String?> _flashName = ValueNotifier<String?>(null);
  Timer? _flashTimer;
  final ScrollController _lookScroll = ScrollController();

  bool _isRecording = false;
  bool _isBusy = false;

  // Recording progress (0..1 over kMaxRecording); stops itself at the end.
  late final AnimationController _rec = AnimationController(
    vsync: this,
    duration: kMaxRecording,
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed && _isRecording) _toggleRecording();
    });

  String get _lookId => kFlyFilters[_lookIndex].id;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;
    // Prefer the front camera for a filter/selfie experience.
    final int frontIndex = _cameras
        .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
    _cameraIndex = frontIndex == -1 ? 0 : frontIndex;
    await _startCamera(_cameraIndex);
  }

  Future<void> _startCamera(int index) async {
    final CameraController controller = CameraController(
      _cameras[index],
      ResolutionPreset.high, // 720p (was 480p)
      enableAudio: true,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await controller.initialize();
    if (!mounted) return;
    try {
      _minExposure = await controller.getMinExposureOffset();
      _maxExposure = await controller.getMaxExposureOffset();
      _exposure = _exposure.clamp(_minExposure, _maxExposure);
      if (_exposure != 0) await controller.setExposureOffset(_exposure);
    } catch (_) {
      _minExposure = 0;
      _maxExposure = 0;
    }
    if (!mounted) return;
    setState(() => _controller = controller);
    await controller.startImageStream(_onCameraImage);
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isRecording || _countdown != null) return;
    final CameraController? old = _controller;
    setState(() => _controller = null);
    await old?.stopImageStream();
    await old?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera(_cameraIndex);
  }

  static const List<List<double>> _kBeautyPresets = [
    [0, 0, 0], // Off
    [0.45, 0.25, 0.1], // Natural
    [0.65, 0.55, 0.2], // Glow
    [0.9, 0.6, 0.4], // Doll
  ];
  static const List<String> _kBeautyNames = ['Off', 'Natural', 'Glow', 'Doll'];

  void _setBeautyPreset(int i) {
    HapticFeedback.selectionClick();
    setState(() {
      _beautyPreset = i;
      _smooth = _kBeautyPresets[i][0];
      _glow = _kBeautyPresets[i][1];
      _rosy = _kBeautyPresets[i][2];
    });
  }

  double get _night =>
      _nightMode == 1 ? 0.8 : (_nightMode == 2 ? 0.0 : _autoNight);

  /// What the camera shows now, as a saved look ("golden|b8|s45|g25...").
  String get _currentLook => makeLook(
        _lookId,
        _glow * 0.3,
        BeautySettings(
            smooth: _smooth, glow: _glow, rosy: _rosy, night: _night),
      );

  // How bright the picture is (average of the Y plane, sampled) -> the
  // automatic Night boost. Checked about twice a second.
  void _measureLight(CameraImage image) {
    if (++_frameCount % 15 != 0) return;
    final Uint8List y = image.planes.first.bytes;
    if (y.isEmpty) return;
    int sum = 0, n = 0;
    for (int i = 0; i < y.length; i += 97) {
      sum += y[i];
      n++;
    }
    final double luma = sum / n; // 0..255
    final double night = ((90 - luma) / 60).clamp(0.0, 1.0);
    if ((night - _autoNight).abs() > 0.08 && mounted) {
      setState(() => _autoNight = night);
    }
  }

  void _onCameraImage(CameraImage image) {
    if (!_isRecording) _measureLight(image);
    // Faces only need the detector while one is picked.
    if (_filter == FaceFilterType.none) return;
    if (_isDetecting || _isRecording) return;
    _isDetecting = true;
    _detectFace(image).whenComplete(() => _isDetecting = false);
  }

  Future<void> _detectFace(CameraImage image) async {
    try {
      final CameraDescription camera = _cameras[_cameraIndex];
      final InputImageRotation rotation =
          InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;

      final InputImageFormat format =
          InputImageFormatValue.fromRawValue(image.format.raw) ??
              InputImageFormat.nv21;

      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final InputImage inputImage = InputImage.fromBytes(
        bytes: allBytes.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );

      final List<FaceMesh> faces =
          await _faceMeshDetector.processImage(inputImage);
      if (!mounted) return;
      setState(() {
        _lastFace = faces.isNotEmpty ? faces.first : null;
        _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());
      });
    } catch (_) {
      // Ignore isolated frame errors - the next frame will try again.
    }
  }

  // ---------------------------------------------------------------- looks
  void _setLook(int index, {bool scroll = true}) {
    final int i = index.clamp(0, kFlyFilters.length - 1);
    if (i == _lookIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _lookIndex = i);
    _flashName.value = kFlyFilters[i].name;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      _flashName.value = null;
    });
    if (scroll && _lookScroll.hasClients) {
      // Keep the picked thumbnail in view (each item is 68 wide).
      final double target = (i * 68.0) -
          (_lookScroll.position.viewportDimension / 2) +
          34 +
          12;
      _lookScroll.animateTo(
        target.clamp(0.0, _lookScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  // Swipe on the camera: left = next look, right = previous.
  void _onSwipe(DragEndDetails d) {
    if (_isRecording) return;
    final double v = d.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    _setLook(_lookIndex + (v < 0 ? 1 : -1));
  }

  // ------------------------------------------------------------ recording
  void _onRecordTap() {
    if (_countdown != null) {
      // Tap again during the countdown = cancel it.
      _countdownTimer?.cancel();
      setState(() => _countdown = null);
      return;
    }
    if (!_isRecording && _timerSeconds > 0) {
      HapticFeedback.mediumImpact();
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
    final CameraController? controller = _controller;
    if (controller == null || _isBusy) return;
    setState(() => _isBusy = true);

    try {
      if (_isRecording) {
        _rec.stop();
        HapticFeedback.mediumImpact();
        // 9 Nov 2026 (Ko: "the stop button does nothing"): never wait for
        // ever - after 10 s show what went wrong instead of a dead button.
        final XFile file = await controller
            .stopVideoRecording()
            .timeout(const Duration(seconds: 10));
        if (!mounted) return;
        setState(() => _isRecording = false);
        FaceFilterCameraScreen.lastLook = _currentLook;
        Navigator.pop(context, file);
      } else {
        // Recording and the live image stream can't both use the camera
        // session on most devices, so a face filter freezes at its last
        // tracked position while recording (camera-only, not in the file).
        await controller.stopImageStream();
        await controller.startVideoRecording();
        // Recording starts a new camera session on some phones - keep the
        // chosen brightness.
        if (_exposure != 0) {
          try {
            await controller.setExposureOffset(_exposure);
          } catch (_) {}
        }
        HapticFeedback.heavyImpact();
        setState(() {
          _isRecording = true;
          _showBeauty = false;
          _showLight = false;
        });
        _rec.forward(from: 0);
      }
    } catch (e) {
      // Show the reason (the button stays tappable to retry).
      debugPrint('Record camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isRecording
              ? 'Could not stop the recording: $e'
              : 'Could not start the recording: $e'),
          duration: const Duration(seconds: 6),
        ));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _flashTimer?.cancel();
    _flashName.dispose();
    _lookScroll.dispose();
    _rec.dispose();
    _controller?.dispose();
    _faceMeshDetector.close();
    super.dispose();
  }

  // ------------------------------------------------------- face mapping
  // Maps the detected face's bounding box (in image pixel space) onto the
  // widget's own coordinate space, accounting for the mirrored front
  // camera preview and the BoxFit.cover scaling of CameraPreview.
  Rect? _mappedFaceRect(Size widgetSize) {
    final FaceMesh? face = _lastFace;
    final Size? imageSize = _lastImageSize;
    if (face == null || imageSize == null) return null;

    // CameraPreview for a front camera is mirrored horizontally, and the
    // raw image is often rotated 90°, so width/height are swapped versus
    // the portrait preview widget.
    final double previewImageWidth = imageSize.height;
    final double previewImageHeight = imageSize.width;

    final double scale = widgetSize.width / previewImageWidth;
    final double scaledImageHeight = previewImageHeight * scale;
    final double verticalOffset = (scaledImageHeight - widgetSize.height) / 2;

    final Rect box = face.boundingBox;
    // Swap x/y for the 90°-rotated raw image, then mirror horizontally.
    final double left = box.top * scale;
    final double top = box.left * scale - verticalOffset;
    final double right = box.bottom * scale;
    final double bottom = box.right * scale - verticalOffset;

    final double mirroredLeft = widgetSize.width - right;
    final double mirroredRight = widgetSize.width - left;

    return Rect.fromLTRB(mirroredLeft, top, mirroredRight, bottom);
  }

  // Maps a single face-mesh point (image pixel space) into widget space,
  // using the same rotation/mirror math as _mappedFaceRect.
  Offset _mapPoint(FaceMeshPoint point, Size widgetSize, Size imageSize) {
    final double previewImageWidth = imageSize.height;
    final double previewImageHeight = imageSize.width;
    final double scale = widgetSize.width / previewImageWidth;
    final double scaledImageHeight = previewImageHeight * scale;
    final double verticalOffset = (scaledImageHeight - widgetSize.height) / 2;

    final double mappedX = point.y * scale;
    final double mappedY = point.x * scale - verticalOffset;
    return Offset(widgetSize.width - mappedX, mappedY);
  }

  Offset _averagePoint(
      List<FaceMeshPoint>? points, Size widgetSize, Size imageSize) {
    if (points == null || points.isEmpty) return Offset.zero;
    double sumX = 0, sumY = 0;
    for (final p in points) {
      final Offset mapped = _mapPoint(p, widgetSize, imageSize);
      sumX += mapped.dx;
      sumY += mapped.dy;
    }
    return Offset(sumX / points.length, sumY / points.length);
  }

  // Uses the mesh's actual left/right eye contours (rather than the coarse
  // bounding box) to place sunglasses precisely between and across the
  // eyes.
  ({Offset center, double eyeDistance})? _eyeAnchor(Size widgetSize) {
    final FaceMesh? face = _lastFace;
    final Size? imageSize = _lastImageSize;
    if (face == null || imageSize == null) return null;

    final Offset leftEye = _averagePoint(
        face.contours[FaceMeshContourType.leftEye], widgetSize, imageSize);
    final Offset rightEye = _averagePoint(
        face.contours[FaceMeshContourType.rightEye], widgetSize, imageSize);
    if (leftEye == Offset.zero || rightEye == Offset.zero) return null;

    final Offset center = Offset(
      (leftEye.dx + rightEye.dx) / 2,
      (leftEye.dy + rightEye.dy) / 2,
    );
    final double eyeDistance = (leftEye - rightEye).distance;
    return (center: center, eyeDistance: eyeDistance);
  }

  Widget _buildFilterOverlay(Size widgetSize) {
    if (_filter == FaceFilterType.none) return const SizedBox.shrink();

    final String emoji = kFaceFilterEmojis[_filter] ?? '';

    if (_filter == FaceFilterType.sunglasses) {
      final anchor = _eyeAnchor(widgetSize);
      if (anchor == null) return const SizedBox.shrink();
      final double fontSize = anchor.eyeDistance * 2.6;
      return Positioned(
        left: anchor.center.dx - fontSize / 2,
        top: anchor.center.dy - fontSize / 2.6,
        child: IgnorePointer(
          child: Text(emoji, style: TextStyle(fontSize: fontSize)),
        ),
      );
    }

    final Rect? rect = _mappedFaceRect(widgetSize);
    if (rect == null) return const SizedBox.shrink();

    final double faceWidth = rect.width;
    double top;
    double fontSize = faceWidth * 0.9;
    switch (_filter) {
      case FaceFilterType.dogEars:
      case FaceFilterType.flowerCrown:
        top = rect.top - faceWidth * 0.5;
        break;
      case FaceFilterType.mustache:
        top = rect.top + rect.height * 0.62;
        fontSize = faceWidth * 0.5;
        break;
      case FaceFilterType.sunglasses:
      case FaceFilterType.none:
        top = rect.top;
    }

    return Positioned(
      left: rect.left + rect.width / 2 - fontSize / 2,
      top: top,
      child: IgnorePointer(
        child: Text(emoji, style: TextStyle(fontSize: fontSize)),
      ),
    );
  }

  // ------------------------------------------------------------------ UI
  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: const BoxDecoration(
          color: Colors.black38,
          shape: BoxShape.circle,
        ),
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
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabLabel(String text, int index) {
    final bool on = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: on ? const Color(0xFFFF4B6E) : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: on ? Colors.white : Colors.white60,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
          ),
        ),
      ),
    );
  }

  Widget _faceChip(FaceFilterType type, String label) {
    final bool isActive = _filter == type;
    return GestureDetector(
      onTap: () => setState(() {
        _filter = type;
        if (type == FaceFilterType.none) _lastFace = null;
      }),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: isActive
              ? const LinearGradient(
                  colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)])
              : null,
          color: isActive ? null : Colors.black45,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _beautyChip(String text, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
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

  Widget _beautySlider(String label, double value, ValueChanged<double> set) {
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFFF4B6E),
              thumbColor: const Color(0xFFFF4B6E),
              inactiveTrackColor: Colors.white24,
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value,
              onChanged: (v) => setState(() {
                _beautyPreset = 4; // Custom
                set(v);
              }),
            ),
          ),
        ),
        SizedBox(
          width: 28,
          child: Text('${(value * 100).round()}',
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ),
      ],
    );
  }

  // Fly Beauty: presets + Smooth / Bright / Rosy + Night (auto / on / off).
  Widget _beautyPanel() {
    final String nightLabel = _nightMode == 1
        ? 'Night: On'
        : _nightMode == 2
            ? 'Night: Off'
            : (_autoNight > 0.05 ? 'Night: Auto (on)' : 'Night: Auto');
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < _kBeautyNames.length; i++)
                  _beautyChip(_kBeautyNames[i], _beautyPreset == i,
                      () => _setBeautyPreset(i)),
                _beautyChip(nightLabel, _night > 0.05, () {
                  HapticFeedback.selectionClick();
                  setState(() => _nightMode = (_nightMode + 1) % 3);
                }),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _beautySlider('Smooth', _smooth, (v) => _smooth = v),
          _beautySlider('Bright', _glow, (v) => _glow = v),
          _beautySlider('Rosy', _rosy, (v) => _rosy = v),
        ],
      ),
    );
  }

  Widget _lookStrip() {
    return SizedBox(
      height: 84,
      child: ListView.builder(
        controller: _lookScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: kFlyFilters.length,
        itemBuilder: (context, i) {
          final FlyFilter f = kFlyFilters[i];
          final bool on = i == _lookIndex;
          return GestureDetector(
            onTap: () => _setLook(i, scroll: false),
            child: SizedBox(
              width: 68,
              child: Column(
                children: [
                  FilterSwatch(look: f.id, size: 56, selected: on),
                  const SizedBox(height: 4),
                  Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: on ? Colors.white : Colors.white70,
                      fontSize: 11,
                      fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4)
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recordButton() {
    return GestureDetector(
      onTap: _onRecordTap,
      child: SizedBox(
        width: 92,
        height: 92,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Progress ring while recording.
            AnimatedBuilder(
              animation: _rec,
              builder: (context, _) => CustomPaint(
                size: const Size(92, 92),
                painter: _RecRingPainter(_isRecording ? _rec.value : 0),
              ),
            ),
            if (_isBusy && _isRecording)
              const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                    strokeWidth: 3, color: Colors.white),
              )
            else
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _isRecording ? 34 : 64,
              height: _isRecording ? 34 : 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_isRecording ? 8 : 32),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _controller;
    final String look = _currentLook;
    final bool idle = !_isRecording && _countdown == null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            GestureDetector(
              onHorizontalDragEnd: _onSwipe,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final Size widgetSize =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform(
                        alignment: Alignment.center,
                        // Mirror the preview so it feels like a selfie
                        // mirror, matching the face-position math above.
                        transform: Matrix4.rotationY(pi),
                        child: FlyLook(
                          look: look,
                          child: CameraPreview(controller),
                        ),
                      ),
                      _buildFilterOverlay(widgetSize),
                      if (_grid)
                        IgnorePointer(
                          child: CustomPaint(painter: _GridPainter()),
                        ),
                    ],
                  );
                },
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            ),

          // Ring light: a bright white frame lights the face in the dark.
          if (_ringLight)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 28),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.white,
                      blurRadius: 30,
                      spreadRadius: -10,
                    ),
                  ],
                ),
              ),
            ),

          // The look's name flashes in the middle when it changes.
          IgnorePointer(
            child: Center(
              child: ValueListenableBuilder<String?>(
                valueListenable: _flashName,
                builder: (context, name, _) => AnimatedOpacity(
                  opacity: name == null ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    name ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Countdown.
          if (_countdown != null)
            IgnorePointer(
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_countdown),
                  tween: Tween(begin: 1.6, end: 1.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  builder: (context, s, child) =>
                      Transform.scale(scale: s, child: child),
                  child: Text(
                    '$_countdown',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 110,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 16)],
                    ),
                  ),
                ),
              ),
            ),

          // Top bar: close, time (while recording), flip - pinned to the
          // top (it used to sit in the middle of the screen).
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
                  _roundButton(Icons.close, () => Navigator.pop(context)),
                  if (_isRecording)
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
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFF4B6E),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '0:${s.toString().padLeft(2, '0')} / '
                                '${kMaxRecording.inSeconds}s',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  _roundButton(Icons.cameraswitch_outlined, _switchCamera),
                ],
              ),
            ),
          ),
          ),

          // Right-hand tools.
          if (idle)
            Positioned(
              right: 10,
              top: MediaQuery.paddingOf(context).top + 70,
              child: Column(
                children: [
                  _tool(
                    Icons.timer_outlined,
                    _timerSeconds == 0 ? 'Timer' : '${_timerSeconds}s',
                    _timerSeconds > 0,
                    () => setState(() => _timerSeconds =
                        _timerSeconds == 0 ? 3 : (_timerSeconds == 3 ? 10 : 0)),
                  ),
                  _tool(Icons.auto_awesome, 'Beauty', _showBeauty,
                      () => setState(() {
                            _showBeauty = !_showBeauty;
                            if (_showBeauty) _showLight = false;
                          })),
                  _tool(Icons.wb_sunny_outlined, 'Light',
                      _showLight || _exposure > 0 || _ringLight,
                      () => setState(() {
                            _showLight = !_showLight;
                            if (_showLight) _showBeauty = false;
                          })),
                  _tool(Icons.grid_on_rounded, 'Grid', _grid,
                      () => setState(() => _grid = !_grid)),
                ],
              ),
            ),

          // Bottom: beauty slider, tabs, picker, record button.
          SafeArea(
            top: false,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (idle && _showLight)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.wb_sunny_outlined,
                            color: Colors.white, size: 18),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: const Color(0xFFFFD27A),
                              thumbColor: const Color(0xFFFFD27A),
                              inactiveTrackColor: Colors.white24,
                              trackHeight: 3,
                            ),
                            child: Slider(
                              value: _exposure.clamp(_minExposure, _maxExposure),
                              min: _minExposure,
                              max: _maxExposure > _minExposure
                                  ? _maxExposure
                                  : _minExposure + 1,
                              onChanged: _maxExposure > _minExposure
                                  ? (v) {
                                      setState(() => _exposure = v);
                                      _controller
                                          ?.setExposureOffset(v)
                                          .catchError((_) => 0.0);
                                    }
                                  : null,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _ringLight = !_ringLight),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: _ringLight
                                  ? Colors.white
                                  : Colors.black45,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              'Ring light',
                              style: TextStyle(
                                color:
                                    _ringLight ? Colors.black : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (idle && _showBeauty) _beautyPanel(),
                if (idle) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _tabLabel('Filters', 0),
                      const SizedBox(width: 26),
                      _tabLabel('Faces', 1),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_tab == 0)
                    _lookStrip()
                  else
                    Column(
                      children: [
                        SizedBox(
                          height: 44,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            children: [
                              _faceChip(FaceFilterType.none, 'None'),
                              _faceChip(
                                  FaceFilterType.sunglasses, '🕶️ Glasses'),
                              _faceChip(FaceFilterType.dogEars, '🐶 Dog'),
                              _faceChip(
                                  FaceFilterType.flowerCrown, '🌸 Flowers'),
                              _faceChip(
                                  FaceFilterType.mustache, '👨 Mustache'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Faces show on the camera only for now',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                ],
                const SizedBox(height: 8),
                _recordButton(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// White ring around the record button that fills up while recording.
class _RecRingPainter extends CustomPainter {
  final double progress;
  _RecRingPainter(this.progress);

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
        ..color = Colors.white.withValues(alpha: progress > 0 ? 0.35 : 1),
    );
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
          ..color = const Color(0xFF35E1F2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RecRingPainter old) =>
      old.progress != progress;
}

/// Rule-of-thirds lines.
class _GridPainter extends CustomPainter {
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

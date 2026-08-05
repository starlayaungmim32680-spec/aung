import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

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

class FaceFilterCameraScreen extends StatefulWidget {
  const FaceFilterCameraScreen({super.key});

  @override
  State<FaceFilterCameraScreen> createState() => _FaceFilterCameraScreenState();
}

class _FaceFilterCameraScreenState extends State<FaceFilterCameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  final FaceMeshDetector _faceMeshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  bool _isDetecting = false;
  FaceMesh? _lastFace;
  Size? _lastImageSize;
  FaceFilterType _filter = FaceFilterType.sunglasses;
  // 0.0 = off, 1.0 = strongest brighten/soften effect.
  double _beautyIntensity = 0.0;

  bool _isRecording = false;
  bool _isBusy = false;

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
      ResolutionPreset.medium,
      enableAudio: true,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await controller.initialize();
    if (!mounted) return;
    setState(() => _controller = controller);
    await controller.startImageStream(_onCameraImage);
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isRecording) return;
    final CameraController? old = _controller;
    setState(() => _controller = null);
    await old?.stopImageStream();
    await old?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera(_cameraIndex);
  }

  void _onCameraImage(CameraImage image) {
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

  Future<void> _toggleRecording() async {
    final CameraController? controller = _controller;
    if (controller == null || _isBusy) return;
    setState(() => _isBusy = true);

    try {
      if (_isRecording) {
        final XFile file = await controller.stopVideoRecording();
        setState(() => _isRecording = false);
        if (mounted) Navigator.pop(context, file);
      } else {
        // Recording and the live image stream can't both use the camera
        // session on most devices, so the filter overlay freezes at its
        // last tracked position for the duration of the recording. This
        // is a Phase 1 preview experience - the filter is not baked into
        // the saved video file itself.
        await controller.stopImageStream();
        await controller.startVideoRecording();
        setState(() => _isRecording = true);
      }
    } catch (_) {
      // Leave state as-is; the button remains tappable to retry.
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _faceMeshDetector.close();
    super.dispose();
  }

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
  // eyes - this is the main precision upgrade Face Mesh gives us over the
  // plain bounding-box detector from Phase 1.
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

  // A brightened, slightly desaturated look that reads as "soft skin,
  // brighter tone" - blended with the identity matrix by `intensity` (0-1)
  // so the slider can dial it from off to strongest.
  List<double> _beautyMatrix(double intensity) {
    const List<double> identity = [
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
    const List<double> beauty = [
      1.08,
      0.04,
      0.04,
      0,
      18,
      0.04,
      1.08,
      0.04,
      0,
      18,
      0.02,
      0.02,
      1.05,
      0,
      14,
      0,
      0,
      0,
      1,
      0,
    ];
    return List<double>.generate(
      20,
      (i) => identity[i] + (beauty[i] - identity[i]) * intensity,
    );
  }

  Widget _buildFilterOverlay(Size widgetSize) {
    if (_filter == FaceFilterType.none) return const SizedBox.shrink();

    final String emoji = kFaceFilterEmojis[_filter] ?? '';

    // Sunglasses get the precise, mesh-contour-anchored treatment; the
    // other filters still use the coarser bounding-box placement, which is
    // good enough for something worn above/below the face rather than
    // directly over a specific feature.
    if (_filter == FaceFilterType.sunglasses) {
      final anchor = _eyeAnchor(widgetSize);
      if (anchor == null) return const SizedBox.shrink();
      // Sized relative to the actual eye-to-eye distance, not the whole
      // face box, so the glasses line up with the eyes at any head angle.
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

  Widget _filterChip(FaceFilterType type, String label) {
    final bool isActive = _filter == type;
    return GestureDetector(
      onTap: () => setState(() => _filter = type),
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

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            LayoutBuilder(
              builder: (context, constraints) {
                final Size widgetSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform(
                      alignment: Alignment.center,
                      // Mirror the preview so it feels like a selfie mirror,
                      // matching the mirroring already applied to the
                      // filter-position math above.
                      transform: Matrix4.rotationY(3.14159),
                      child: ColorFiltered(
                        colorFilter:
                            ColorFilter.matrix(_beautyMatrix(_beautyIntensity)),
                        child: CameraPreview(controller),
                      ),
                    ),
                    _buildFilterOverlay(widgetSize),
                  ],
                );
              },
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            ),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                  GestureDetector(
                    onTap: _switchCamera,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.cameraswitch_outlined,
                          color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom controls: beauty slider + filter picker + record button
          SafeArea(
            top: false,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!_isRecording)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text('✨ Beauty',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: const Color(0xFFFF4B6E),
                              thumbColor: const Color(0xFFFF4B6E),
                              inactiveTrackColor: Colors.white24,
                              trackHeight: 3,
                            ),
                            child: Slider(
                              value: _beautyIntensity,
                              onChanged: (v) =>
                                  setState(() => _beautyIntensity = v),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!_isRecording)
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        _filterChip(FaceFilterType.none, 'None'),
                        _filterChip(FaceFilterType.sunglasses, '🕶️ Glasses'),
                        _filterChip(FaceFilterType.dogEars, '🐶 Dog'),
                        _filterChip(FaceFilterType.flowerCrown, '🌸 Flowers'),
                        _filterChip(FaceFilterType.mustache, '👨 Mustache'),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _toggleRecording,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        shape:
                            _isRecording ? BoxShape.rectangle : BoxShape.circle,
                        borderRadius:
                            _isRecording ? BorderRadius.circular(8) : null,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

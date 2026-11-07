// Fly Pass scanner (7 Nov 2026) - Ko: "the QR scanner should be inside
// Fly". Scans a friend's Fly Pass QR (https://<project>.firebaseapp.com/
// u/<uid>, AppConfig.profileLink) with the camera - or from a picture in
// the gallery (a saved / received pass) - and opens that profile. Works
// even on phones where Android's App Link check failed, because Fly reads
// the link itself.
//   - mobile_scanner (CameraX + ML Kit barcode scanning), QR codes only.
//   - Camera permission is asked only here (mobile_scanner asks when the
//     camera starts); "denied" shows a button to the app settings.
//   - A Fly link of the other flavor (dev pass in the real app or the
//     other way round) and any other QR get a clear message instead.
// Opened from the Scan button on my Fly Pass and from the share sheet
// (sky_pass.dart).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../app_config.dart';
import 'public_profile_screen.dart';

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

Future<void> openPassScanner(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PassScannerScreen()),
  );
}

class PassScannerScreen extends StatefulWidget {
  const PassScannerScreen({super.key});

  @override
  State<PassScannerScreen> createState() => _PassScannerScreenState();
}

class _PassScannerScreenState extends State<PassScannerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  late final AnimationController _plane = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  bool _handled = false;
  bool _picking = false;
  String? _message;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_controller.start());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        unawaited(_controller.stop());
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageTimer?.cancel();
    _plane.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _say(String text) {
    _messageTimer?.cancel();
    setState(() => _message = text);
    _messageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _message = null);
    });
  }

  // true = it was a Fly Pass of this app and the profile is opening.
  bool _handle(String? raw) {
    if (_handled || raw == null || raw.isEmpty) return false;
    final String? uid = AppConfig.profileUidFromLink(raw);
    if (uid != null) {
      _handled = true;
      HapticFeedback.mediumImpact();
      unawaited(_controller.stop());
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PublicProfileScreen(userId: uid)),
      );
      return true;
    }
    HapticFeedback.lightImpact();
    if (AppConfig.profileUidFromLink(raw, anyFlavor: true) != null) {
      _say(AppConfig.isDev
          ? 'This pass is from the real Fly app, not Fly Dev.'
          : 'This pass is from a test version of Fly.');
    } else {
      _say("This isn't a Fly Pass.");
    }
    return false;
  }

  void _onDetect(BarcodeCapture capture) {
    for (final Barcode b in capture.barcodes) {
      if (_handle(b.rawValue)) return;
    }
  }

  Future<void> _fromGallery() async {
    if (_picking) return;
    _picking = true;
    try {
      final XFile? file =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      final BarcodeCapture? capture = await _controller.analyzeImage(file.path);
      if (!mounted) return;
      final List<Barcode> codes = capture?.barcodes ?? const [];
      if (codes.isEmpty) {
        _say('No QR code found in that picture.');
        return;
      }
      for (final Barcode b in codes) {
        if (_handle(b.rawValue)) return;
      }
    } catch (_) {
      if (mounted) _say('No QR code found in that picture.');
    } finally {
      _picking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    final double box = (size.width * 0.68).clamp(200.0, 300.0);
    final Rect window = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.44),
      width: box,
      height: box,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      // fit: expand + every layer Positioned - so the camera fills the
      // whole screen (7 Nov 2026 fix: the Stack had taken the top bar's
      // height and the camera showed only in a strip at the top).
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: MobileScanner(
              fit: BoxFit.cover,
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => _CameraError(error: error),
            ),
          ),
          // Dark outside the window + gradient corners + the plane.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _plane,
                builder: (context, _) => CustomPaint(
                  painter: _WindowPainter(window, _plane.value),
                ),
              ),
            ),
          ),
          // Top bar
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text('Scan a Fly Pass',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w800)),
                    ),
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _controller,
                      builder: (context, state, _) {
                        if (!state.isRunning ||
                            state.torchState == TorchState.unavailable) {
                          return const SizedBox.shrink();
                        }
                        final bool on = state.torchState == TorchState.on;
                        return IconButton(
                          tooltip: on ? 'Light off' : 'Light on',
                          icon: Icon(on ? Icons.flash_on : Icons.flash_off,
                              color:
                                  on ? const Color(0xFFFFD54F) : Colors.white),
                          onPressed: () => _controller.toggleTorch(),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Hint + message under the window
          Positioned(
            left: 24,
            right: 24,
            top: window.bottom + 22,
            child: Column(
              children: [
                const Text(
                  "Point your camera at a friend's Fly Pass",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _message == null
                      ? const SizedBox(height: 36)
                      : Container(
                          key: ValueKey(_message),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFFFF9F1C).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: const Color(0xFFFF9F1C)
                                    .withValues(alpha: 0.6)),
                          ),
                          child: Text(_message!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFFFFD08A),
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                ),
              ],
            ),
          ),
          // Gallery button
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 26),
                child: GestureDetector(
                  onTap: _fromGallery,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.photo_library_outlined,
                            color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text('Choose from gallery',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowPainter extends CustomPainter {
  final Rect window;
  final double t; // 0..1, the plane goes down and back up
  _WindowPainter(this.window, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final RRect hole =
        RRect.fromRectAndRadius(window, const Radius.circular(26));

    // Dim everything outside the window.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(hole),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // Gradient corner brackets.
    final Paint corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..shader =
          const LinearGradient(colors: _flyGradient).createShader(window);
    const double len = 34;
    const double r = 26;
    final Rect w = window;
    final Path p = Path()
      // top-left
      ..moveTo(w.left, w.top + len + r)
      ..lineTo(w.left, w.top + r)
      ..arcToPoint(Offset(w.left + r, w.top), radius: const Radius.circular(r))
      ..lineTo(w.left + len + r, w.top)
      // top-right
      ..moveTo(w.right - len - r, w.top)
      ..lineTo(w.right - r, w.top)
      ..arcToPoint(Offset(w.right, w.top + r), radius: const Radius.circular(r))
      ..lineTo(w.right, w.top + len + r)
      // bottom-right
      ..moveTo(w.right, w.bottom - len - r)
      ..lineTo(w.right, w.bottom - r)
      ..arcToPoint(Offset(w.right - r, w.bottom),
          radius: const Radius.circular(r))
      ..lineTo(w.right - len - r, w.bottom)
      // bottom-left
      ..moveTo(w.left + len + r, w.bottom)
      ..lineTo(w.left + r, w.bottom)
      ..arcToPoint(Offset(w.left, w.bottom - r),
          radius: const Radius.circular(r))
      ..lineTo(w.left, w.bottom - len - r);
    canvas.drawPath(p, corner);

    // The scan line: a glowing trail with a small plane on it.
    final double eased = Curves.easeInOut.transform(t);
    final double y = w.top + 18 + (w.height - 36) * eased;
    canvas.drawLine(
      Offset(w.left + 18, y),
      Offset(w.right - 18, y),
      Paint()
        ..strokeWidth = 2
        ..shader = LinearGradient(colors: [
          Colors.white.withValues(alpha: 0),
          const Color(0xFF35E1F2).withValues(alpha: 0.9),
          Colors.white.withValues(alpha: 0),
        ]).createShader(Rect.fromLTWH(w.left, y - 1, w.width, 2)),
    );
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight.codePoint),
        style: TextStyle(
          fontSize: 20,
          fontFamily: Icons.flight.fontFamily,
          package: Icons.flight.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(w.center.dx, y);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindowPainter old) =>
      old.t != t || old.window != window;
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  const _CameraError({required this.error});

  @override
  Widget build(BuildContext context) {
    final bool denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(denied ? Icons.no_photography_outlined : Icons.error_outline,
              color: Colors.white54, size: 56),
          const SizedBox(height: 14),
          Text(
            denied
                ? 'Fly needs the camera to scan a Fly Pass.'
                : "The camera couldn't start. Please try again.",
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white, fontSize: 15.5, height: 1.4),
          ),
          if (denied) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('Open settings',
                  style: TextStyle(
                      color: Color(0xFF35E1F2),
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
          ],
          const SizedBox(height: 120),
        ],
      ),
    );
  }
}

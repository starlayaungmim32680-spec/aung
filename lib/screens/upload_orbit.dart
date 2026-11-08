// "Star Jet Orbit" - the Upload tab's first screen (8 Nov 2026, Ko picked
// idea B of 3 mockups). Replaces the two plain gradient cards ("Short
// Video" / "Video") that led to a second "Record a video / Choose from
// gallery" sheet.
//
//   - Background: the live Sky Pass sky (phone's time of day + the real
//     weather, no plane) - the same sky as Home's story bar.
//   - Middle: the Star Jet core (the bottom bar's Upload icon, big, its
//     orbit ring turning) inside two orbit rings.
//   - 4 planets slowly circle it - each one goes STRAIGHT to its start:
//       Record Short   (pink)   -> camera, 9:16
//       Record Video   (blue)   -> camera, 16:9
//       Short from Gallery (amber) -> gallery, 9:16
//       Video from Gallery (cyan)  -> gallery, 16:9
//     The planets' labels always stay upright. Tapping one makes it fly
//     into the core (shrinks + fades, the core flashes), then it starts -
//     one tap less than before (no source sheet).
//   - Under it: "Story" and "Go Live" shortcuts (hidden when Upload was
//     opened for a sound / a video reply).
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'nav_icons.dart';
import 'sky_pass.dart';

/// One planet = one way to start a post.
class UploadPlanet {
  final String type; // 'short' | 'long' (UploadScreen's _videoType)
  final ImageSource source;
  final String label;
  final String badge; // "9:16" / "16:9"
  final IconData icon;
  final Color color;
  final Color textColor;
  const UploadPlanet(this.type, this.source, this.label, this.badge, this.icon,
      this.color, this.textColor);
}

const List<UploadPlanet> kUploadPlanets = [
  UploadPlanet('short', ImageSource.camera, 'Record\nShort', '9:16',
      Icons.videocam_rounded, Color(0xFFFF4B6E), Colors.white),
  UploadPlanet('long', ImageSource.camera, 'Record\nVideo', '16:9',
      Icons.movie_creation_rounded, Color(0xFF3A8DFF), Colors.white),
  UploadPlanet('long', ImageSource.gallery, 'Video from\nGallery', '16:9',
      Icons.video_library_rounded, Color(0xFF35E1F2), Color(0xFF062A30)),
  UploadPlanet('short', ImageSource.gallery, 'Short from\nGallery', '9:16',
      Icons.photo_library_rounded, Color(0xFFFFB347), Color(0xFF3A2000)),
];

class UploadOrbit extends StatefulWidget {
  /// Called after the tapped planet has flown into the core.
  final void Function(UploadPlanet planet) onPlanet;
  final VoidCallback? onStory;
  final VoidCallback? onGoLive;
  const UploadOrbit({
    super.key,
    required this.onPlanet,
    this.onStory,
    this.onGoLive,
  });

  @override
  State<UploadOrbit> createState() => _UploadOrbitState();
}

class _UploadOrbitState extends State<UploadOrbit>
    with TickerProviderStateMixin {
  // One slow turn of the planets.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 48),
  )..repeat();

  // The Star Jet's own orbit ring + the core's breathing glow.
  late final AnimationController _core = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  // A tapped planet flying into the core.
  late final AnimationController _launch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  int? _launching;

  @override
  void initState() {
    super.initState();
    WeatherService.refresh();
  }

  @override
  void dispose() {
    _spin.dispose();
    _core.dispose();
    _launch.dispose();
    super.dispose();
  }

  Future<void> _tapPlanet(int i) async {
    if (_launching != null) return;
    HapticFeedback.mediumImpact();
    setState(() => _launching = i);
    await _launch.forward(from: 0);
    if (!mounted) return;
    widget.onPlanet(kUploadPlanets[i]);
    // Back in place for when the person comes back to the chooser.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    _launch.value = 0;
    setState(() => _launching = null);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<SkyWeatherInfo?>(
          valueListenable: WeatherService.current,
          builder: (context, geo, _) =>
              SkyBackdrop(weather: geo?.condition, showPlane: false),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: kToolbarHeight + 8),
              const Text(
                'Launch something',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Tap a planet to start',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final double side =
                        min(box.maxWidth - 24, box.maxHeight).clamp(0.0, 400.0);
                    return Center(
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: _orbit(side),
                      ),
                    );
                  },
                ),
              ),
              if (widget.onStory != null || widget.onGoLive != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Row(
                    children: [
                      if (widget.onStory != null)
                        Expanded(
                          child: _Shortcut(
                            icon: Icons.flight_takeoff_rounded,
                            label: 'Story',
                            color: const Color(0xFFFF4B6E),
                            onTap: widget.onStory!,
                          ),
                        ),
                      if (widget.onStory != null && widget.onGoLive != null)
                        const SizedBox(width: 12),
                      if (widget.onGoLive != null)
                        Expanded(
                          child: _Shortcut(
                            icon: Icons.sensors_rounded,
                            label: 'Go Live',
                            color: const Color(0xFF9C4DFF),
                            onTap: widget.onGoLive!,
                          ),
                        ),
                    ],
                  ),
                ),
              // Room for the Sky Horizon bottom bar.
              const SizedBox(height: 96),
            ],
          ),
        ),
      ],
    );
  }

  Widget _orbit(double side) {
    final double c = side / 2;
    final double planet = (side * 0.27).clamp(70.0, 96.0);
    final double coreSize = side * 0.27;
    final double radius = side * 0.36;
    return AnimatedBuilder(
      animation: Listenable.merge([_spin, _launch]),
      builder: (context, _) {
        final double turn = _spin.value * 2 * pi;
        final double fly = Curves.easeInCubic.transform(_launch.value);
        final List<Widget> planets = [];
        for (int i = 0; i < kUploadPlanets.length; i++) {
          // 4 planets at the corners (-135, -45, 45, 135 deg) + the turn.
          final double a = -3 * pi / 4 + i * pi / 2 + turn;
          Offset pos = Offset(c + cos(a) * radius, c + sin(a) * radius);
          double scale = 1;
          double alpha = 1;
          if (_launching == i) {
            pos = Offset.lerp(pos, Offset(c, c), fly)!;
            scale = 1 - 0.7 * fly;
            alpha = 1 - fly;
          } else if (_launching != null) {
            alpha = 1 - 0.6 * fly;
          }
          planets.add(Positioned(
            left: pos.dx - planet / 2,
            top: pos.dy - planet / 2,
            width: planet,
            height: planet,
            child: Opacity(
              opacity: alpha.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: scale,
                child: _Planet(
                  data: kUploadPlanets[i],
                  size: planet,
                  onTap: () => _tapPlanet(i),
                ),
              ),
            ),
          ));
        }
        // The core flashes as the planet arrives.
        final double flash =
            _launching == null ? 0 : sin(_launch.value * pi).clamp(0.0, 1.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _RingsPainter(turn, coreSize / 2),
              ),
            ),
            Positioned(
              left: c - coreSize / 2,
              top: c - coreSize / 2,
              width: coreSize,
              height: coreSize,
              child: _Core(size: coreSize, motion: _core, flash: flash),
            ),
            ...planets,
          ],
        );
      },
    );
  }
}

/// The two orbit rings (outer dashed violet, inner thin cyan) and a few
/// faint dots travelling along the outer one.
class _RingsPainter extends CustomPainter {
  final double turn;
  final double coreRadius;
  _RingsPainter(this.turn, this.coreRadius);

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double outer = size.width * 0.36;
    final double inner = coreRadius + (outer - coreRadius) * 0.45;

    final Paint dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF9C4DFF).withValues(alpha: 0.55);
    const int n = 48;
    for (int i = 0; i < n; i++) {
      final double a = i * 2 * pi / n - turn * 0.5;
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: outer), a, pi / n, false, dash);
    }
    canvas.drawCircle(
      c,
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF35E1F2).withValues(alpha: 0.35),
    );
    // Little moons on the inner ring, turning the other way.
    for (int i = 0; i < 3; i++) {
      final double a = -turn * 1.6 + i * 2 * pi / 3;
      final Offset p = c + Offset(cos(a), sin(a)) * inner;
      canvas.drawCircle(
          p,
          4,
          Paint()
            ..color = const Color(0xFF35E1F2).withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawCircle(p, 1.8, Paint()..color = const Color(0xFFBFF7FF));
    }
  }

  @override
  bool shouldRepaint(covariant _RingsPainter old) =>
      old.turn != turn || old.coreRadius != coreRadius;
}

class _Core extends StatelessWidget {
  final double size;
  final Animation<double> motion;
  final double flash; // 0..1 while a planet arrives
  const _Core({required this.size, required this.motion, required this.flash});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: motion,
      builder: (context, child) {
        final double breathe = 0.5 + 0.5 * sin(motion.value * 2 * pi);
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(
              colors: [Color(0xFF3A1F6A), Color(0xFF120D22)],
            ),
            border: Border.all(
              color: Color.lerp(const Color(0xFFB98CFF), Colors.white, flash)!,
              width: 2.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF9C4DFF)
                    .withValues(alpha: 0.45 + 0.25 * breathe + 0.3 * flash),
                blurRadius: 22 + 10 * breathe + 20 * flash,
                spreadRadius: 1 + 4 * flash,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FlyNavIcon(
            kind: FlyNavKind.upload,
            active: true,
            size: size * 0.48,
            motion: motion,
          ),
          const SizedBox(height: 2),
          Text(
            'CREATE',
            style: TextStyle(
              color: Colors.white,
              fontSize: (size * 0.11).clamp(9.0, 12.0),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Planet extends StatefulWidget {
  final UploadPlanet data;
  final double size;
  final VoidCallback onTap;
  const _Planet({required this.data, required this.size, required this.onTap});

  @override
  State<_Planet> createState() => _PlanetState();
}

class _PlanetState extends State<_Planet> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final UploadPlanet d = widget.data;
    final Color light = Color.lerp(d.color, Colors.white, 0.45)!;
    final Color dark = Color.lerp(d.color, Colors.black, 0.55)!;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.9 : 1,
        duration: const Duration(milliseconds: 110),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.4),
              radius: 0.95,
              colors: [light, d.color, dark],
              stops: const [0, 0.55, 1],
            ),
            boxShadow: [
              BoxShadow(
                color: d.color.withValues(alpha: 0.6),
                blurRadius: 20,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(d.icon, color: d.textColor, size: widget.size * 0.27),
              const SizedBox(height: 1),
              Text(
                d.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: d.textColor,
                  fontSize: (widget.size * 0.125).clamp(9.5, 12.0),
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
              Text(
                d.badge,
                style: TextStyle(
                  color: d.textColor.withValues(alpha: 0.75),
                  fontSize: (widget.size * 0.1).clamp(8.0, 10.0),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _Shortcut({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

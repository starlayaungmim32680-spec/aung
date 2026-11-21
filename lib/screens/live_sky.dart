// 21 Nov 2026 - "Your sky": the background of Home's header (tabs + stories).
//
// Ko did not like the drawn city / landscape (DayScene) - "it looks like a
// cartoon". Picked design A on the canvas "Fly Home stories bar - ideas":
// no drawings at all, only the COLOUR and LIGHT of the sky at the phone's
// local time:
//   - night:   deep navy, a soft moonlight glow top right, faint stars
//   - sunrise: violet -> pink -> warm orange, the sun's glow bottom right
//   - day:     clear blue, a white sun glow top right
//   - sunset:  dusk violet -> coral -> gold, the glow bottom left (west)
// The colours blend smoothly from one time to the next (checked every 5
// minutes), and the bottom of the sky fades into black so it melts into
// the video below instead of ending in a hard edge.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

class _SkyKey {
  final double hour; // local time, 0..24
  final List<Color> colors; // top -> bottom (4)
  final Alignment glowAt;
  final Color glow;
  final double stars; // 0..1
  const _SkyKey(this.hour, this.colors, this.glowAt, this.glow, this.stars);
}

const List<_SkyKey> _keys = [
  _SkyKey(
      0,
      [
        Color(0xFF050816),
        Color(0xFF0A1028),
        Color(0xFF0E1534),
        Color(0xFF1C2753)
      ],
      Alignment(0.72, -0.64),
      Color(0x61BED2FF),
      1),
  _SkyKey(
      5.3,
      [
        Color(0xFF070A1E),
        Color(0xFF111838),
        Color(0xFF1E2550),
        Color(0xFF2E2E62)
      ],
      Alignment(0.76, 0.84),
      Color(0x40FFC8A0),
      0.7),
  _SkyKey(
      6.6,
      [
        Color(0xFF1C2452),
        Color(0xFF4B3A7A),
        Color(0xFFB9688A),
        Color(0xFFF1A27E)
      ],
      Alignment(0.76, 0.84),
      Color(0xD9FFD6A0),
      0),
  _SkyKey(
      8.5,
      [
        Color(0xFF1E5FC8),
        Color(0xFF3778DA),
        Color(0xFF4A8CE6),
        Color(0xFF9CC6F4)
      ],
      Alignment(0.68, -0.84),
      Color(0xE6FFFFF0),
      0),
  _SkyKey(
      16.3,
      [
        Color(0xFF1E5FC8),
        Color(0xFF3778DA),
        Color(0xFF4A8CE6),
        Color(0xFF9CC6F4)
      ],
      Alignment(-0.6, -0.5),
      Color(0xCCFFFFF0),
      0),
  _SkyKey(
      18.1,
      [
        Color(0xFF22285A),
        Color(0xFF7A3F78),
        Color(0xFFE0705A),
        Color(0xFFF6B26B)
      ],
      Alignment(-0.76, 0.84),
      Color(0xD9FFC080),
      0),
  _SkyKey(
      19.6,
      [
        Color(0xFF070A1E),
        Color(0xFF111838),
        Color(0xFF1E2550),
        Color(0xFF2E2E62)
      ],
      Alignment(-0.6, 0.6),
      Color(0x30FFB080),
      0.6),
  _SkyKey(
      21,
      [
        Color(0xFF050816),
        Color(0xFF0A1028),
        Color(0xFF0E1534),
        Color(0xFF1C2753)
      ],
      Alignment(0.72, -0.64),
      Color(0x61BED2FF),
      1),
  _SkyKey(
      24,
      [
        Color(0xFF050816),
        Color(0xFF0A1028),
        Color(0xFF0E1534),
        Color(0xFF1C2753)
      ],
      Alignment(0.72, -0.64),
      Color(0x61BED2FF),
      1),
];

/// The sky right now (blended between the two nearest key times).
_SkyKey _skyAt(DateTime t) {
  final double h = t.hour + t.minute / 60;
  for (int i = 0; i < _keys.length - 1; i++) {
    final _SkyKey a = _keys[i], b = _keys[i + 1];
    if (h >= a.hour && h <= b.hour) {
      final double f = b.hour == a.hour ? 0 : (h - a.hour) / (b.hour - a.hour);
      return _SkyKey(
        h,
        [for (int c = 0; c < 4; c++) Color.lerp(a.colors[c], b.colors[c], f)!],
        Alignment.lerp(a.glowAt, b.glowAt, f)!,
        Color.lerp(a.glow, b.glow, f)!,
        a.stars + (b.stars - a.stars) * f,
      );
    }
  }
  return _keys.first;
}

class LiveSkyGlow extends StatefulWidget {
  const LiveSkyGlow({super.key});

  @override
  State<LiveSkyGlow> createState() => _LiveSkyGlowState();
}

class _LiveSkyGlowState extends State<LiveSkyGlow> {
  late _SkyKey _sky = _skyAt(DateTime.now());
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted) setState(() => _sky = _skyAt(DateTime.now()));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _SkyKey s = _sky;
    return IgnorePointer(
      child: ShaderMask(
        // Melt into the black under the header (no hard edge).
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.7, 1],
        ).createShader(r),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: s.colors,
                  stops: const [0, 0.35, 0.65, 1],
                ),
              ),
            ),
            // The sun / moon as LIGHT only - no drawn disc.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: s.glowAt,
                  radius: 0.9,
                  colors: [s.glow, s.glow.withValues(alpha: 0)],
                ),
              ),
            ),
            if (s.stars > 0.02)
              RepaintBoundary(
                child: CustomPaint(painter: _StarDust(s.stars)),
              ),
          ],
        ),
      ),
    );
  }
}

// A few faint, fixed stars (same places every night).
class _StarDust extends CustomPainter {
  final double strength;
  const _StarDust(this.strength);

  @override
  void paint(Canvas canvas, Size size) {
    final Random r = Random(7);
    final Paint p = Paint()..color = Colors.white;
    for (int i = 0; i < 34; i++) {
      final double x = r.nextDouble() * size.width;
      final double y = r.nextDouble() * size.height * 0.75;
      final double rad = 0.5 + r.nextDouble() * 0.8;
      p.color = Colors.white
          .withValues(alpha: (0.2 + r.nextDouble() * 0.5) * strength);
      canvas.drawCircle(Offset(x, y), rad, p);
    }
  }

  @override
  bool shouldRepaint(covariant _StarDust old) => old.strength != strength;
}

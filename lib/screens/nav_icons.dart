// "Neon Hologram" bottom-bar icons (8 Nov 2026, Ko picked F1 - "the
// future look" for every tab). Thin glowing lines like a sci-fi cockpit
// screen, drawn by hand (no image files, sharp on every phone):
//   home    - Hex Portal: a hexagon gate with a door and a light
//   chat    - Signal Bubble: a chat window with a sound-wave line
//   upload  - Star Jet: a 4-point star inside an open orbit ring
//   profile - Face Scan: a person inside scanner corners
//   live    - Radar: rings + a sweeping arm
// Not selected = silver lines. Selected = Fly gradient (pink -> violet ->
// blue) with a glow, and a little motion: the profile scan line runs up
// and down, the radar arm sweeps, the upload orbit turns.
import 'dart:math';
import 'package:flutter/material.dart';

enum FlyNavKind { home, chat, upload, profile, live }

const Color kNavSilver = Color(0xFF9AA3C7);
const List<Color> kNavFlyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

/// One bar icon. [motion] (0..1, repeating) drives the active animation.
class FlyNavIcon extends StatelessWidget {
  final FlyNavKind kind;
  final bool active;
  final double size;
  final Animation<double> motion;
  const FlyNavIcon({
    super.key,
    required this.kind,
    required this.active,
    required this.size,
    required this.motion,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _FlyNavPainter(kind, active, active ? motion : null),
        ),
      ),
    );
  }
}

class _FlyNavPainter extends CustomPainter {
  final FlyNavKind kind;
  final bool active;
  final Animation<double>? motion;
  _FlyNavPainter(this.kind, this.active, this.motion) : super(repaint: motion);

  @override
  void paint(Canvas canvas, Size size) {
    // Everything is drawn on a 40 x 40 grid.
    final double k = size.width / 40;
    canvas.save();
    canvas.scale(k, k);
    final double t = motion?.value ?? 0;
    final Rect box = const Rect.fromLTWH(0, 0, 40, 40);

    Paint line(double width) {
      final Paint p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (active) {
        p.shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: kNavFlyGradient,
        ).createShader(box);
      } else {
        p.color = kNavSilver;
      }
      return p;
    }

    Paint fill(Color activeColor) => Paint()
      ..style = PaintingStyle.fill
      ..color = active ? activeColor : kNavSilver;

    // Draws [path] with a soft neon glow under it when active.
    void neon(Path path, double width) {
      if (active) {
        canvas.drawPath(
          path,
          line(width + 1.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
      canvas.drawPath(path, line(width));
    }

    switch (kind) {
      case FlyNavKind.home:
        final Path hex = Path()
          ..moveTo(20, 5)
          ..lineTo(33, 12.5)
          ..lineTo(33, 27.5)
          ..lineTo(20, 35)
          ..lineTo(7, 27.5)
          ..lineTo(7, 12.5)
          ..close();
        final Path door = Path()
          ..moveTo(15, 31)
          ..lineTo(15, 21)
          ..lineTo(25, 21)
          ..lineTo(25, 31);
        neon(hex, 2.2);
        neon(door, 2.2);
        canvas.drawCircle(const Offset(20, 14.5), 2.2, fill(Colors.white));
        break;

      case FlyNavKind.chat:
        final Path bubble = Path()
          ..moveTo(8, 9)
          ..lineTo(32, 9)
          ..quadraticBezierTo(35, 9, 35, 12)
          ..lineTo(35, 24)
          ..quadraticBezierTo(35, 27, 32, 27)
          ..lineTo(18, 27)
          ..lineTo(11, 33)
          ..lineTo(11, 27)
          ..lineTo(8, 27)
          ..quadraticBezierTo(5, 27, 5, 24)
          ..lineTo(5, 12)
          ..quadraticBezierTo(5, 9, 8, 9)
          ..close();
        // The wave moves along when active.
        final Path wave = Path()..moveTo(11, 16);
        for (double x = 11; x <= 29; x += 1) {
          wave.lineTo(x, 16 + 1.8 * sin((x - 11) / 3 + t * 2 * pi));
        }
        neon(bubble, 2.2);
        neon(wave, 2);
        neon(
            Path()
              ..moveTo(11, 21.5)
              ..lineTo(22, 21.5),
            2);
        break;

      case FlyNavKind.upload:
        // Open orbit ring (turns when active) + 4-point star jet.
        neon(
          Path()
            ..addArc(Rect.fromCircle(center: const Offset(20, 20), radius: 16),
                0.35 + t * 2 * pi, 2 * pi - 0.7),
          2.2,
        );
        final Path star = Path()
          ..moveTo(20, 8.5)
          ..lineTo(23, 17)
          ..lineTo(31.5, 20)
          ..lineTo(23, 23)
          ..lineTo(20, 31.5)
          ..lineTo(17, 23)
          ..lineTo(8.5, 20)
          ..lineTo(17, 17)
          ..close();
        if (active) {
          canvas.drawPath(
            star,
            Paint()
              ..color = const Color(0xFF9C4DFF).withValues(alpha: 0.8)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
          );
        }
        canvas.drawPath(
          star,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: kNavFlyGradient,
            ).createShader(box),
        );
        break;

      case FlyNavKind.profile:
        final Path corners = Path()
          ..moveTo(6, 12)
          ..lineTo(6, 7)
          ..lineTo(11, 7)
          ..moveTo(29, 7)
          ..lineTo(34, 7)
          ..lineTo(34, 12)
          ..moveTo(34, 28)
          ..lineTo(34, 33)
          ..lineTo(29, 33)
          ..moveTo(11, 33)
          ..lineTo(6, 33)
          ..lineTo(6, 28);
        final Path person = Path()
          ..addOval(Rect.fromCircle(center: const Offset(20, 17), radius: 5))
          ..moveTo(11, 30)
          ..quadraticBezierTo(20, 20, 29, 30);
        neon(corners, 2.2);
        neon(person, 2.2);
        // Scan line: still in the middle, or running up and down.
        final double y = active ? 10 + 20 * (0.5 - 0.5 * cos(t * 2 * pi)) : 20;
        canvas.drawLine(
          Offset(8, y),
          Offset(32, y),
          Paint()
            ..strokeWidth = 1.2
            ..color = (active ? const Color(0xFF35E1F2) : kNavSilver)
                .withValues(alpha: active ? 0.9 : 0.5),
        );
        break;

      case FlyNavKind.live:
        canvas.drawCircle(
            const Offset(20, 20), 3.6, fill(const Color(0xFFFF4B6E)));
        // Dashed inner ring.
        final Path dashes = Path();
        for (int i = 0; i < 8; i++) {
          final double a = i * 2 * pi / 8;
          dashes.addArc(
              Rect.fromCircle(center: const Offset(20, 20), radius: 9), a, 0.5);
        }
        neon(dashes, 2);
        neon(
            Path()
              ..addOval(
                  Rect.fromCircle(center: const Offset(20, 20), radius: 15)),
            1.6);
        // The sweeping arm (fixed when not selected).
        final double a = active ? t * 2 * pi : -pi / 4;
        neon(
            Path()
              ..moveTo(20, 20)
              ..lineTo(20 + 13 * cos(a), 20 + 13 * sin(a)),
            2.2);
        if (active) {
          // A faint sweep wedge behind the arm.
          canvas.drawPath(
            Path()
              ..moveTo(20, 20)
              ..arcTo(Rect.fromCircle(center: const Offset(20, 20), radius: 15),
                  a - 0.9, 0.9, false)
              ..close(),
            Paint()..color = const Color(0xFF9C4DFF).withValues(alpha: 0.3),
          );
        }
        break;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlyNavPainter old) =>
      old.kind != kind || old.active != active;
}

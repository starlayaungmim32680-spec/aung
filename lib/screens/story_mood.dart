// Story mood (8 Nov 2026) - Ko: "when someone posts a sad story, sad
// emojis should show; when happy, happy ones - by the person's feeling".
// The person who posts picks the feeling themselves (idea A - always
// right, no AI cost): [pickStoryMood] is the last step before a story
// uploads ("How do you feel?", or Skip). It is saved as stories/{id}.mood
// (one of [kStoryMoods] ids; no mood = field left out - the rules already
// allow any field on create).
// Home's Flight Path bar ([StoryMoodPainter]) then lets little emojis of
// that feeling float around the person's stop, each feeling with its own
// movement: happy bounces up, love sways up, party bursts up spinning,
// sleepy drifts up slowly, cool glides sideways, sad falls slowly like
// tears, angry shakes around the circle, thinking circles around it.
// The story viewer shows the emoji next to the name.
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum MoodMotion { bounce, sway, burst, sleepy, glide, fall, shake, orbit }

class StoryMood {
  final String id;
  final String emoji;
  final String label;
  final MoodMotion motion;
  const StoryMood(this.id, this.emoji, this.label, this.motion);
}

const List<StoryMood> kStoryMoods = [
  StoryMood('happy', '😄', 'Happy', MoodMotion.bounce),
  StoryMood('love', '😍', 'In love', MoodMotion.sway),
  StoryMood('party', '🎉', 'Party', MoodMotion.burst),
  StoryMood('cool', '😎', 'Cool', MoodMotion.glide),
  StoryMood('sleepy', '😴', 'Sleepy', MoodMotion.sleepy),
  StoryMood('thinking', '🤔', 'Thinking', MoodMotion.orbit),
  StoryMood('sad', '😢', 'Sad', MoodMotion.fall),
  StoryMood('angry', '😡', 'Angry', MoodMotion.shake),
];

StoryMood? storyMoodById(Object? id) {
  if (id is! String || id.isEmpty) return null;
  for (final StoryMood m in kStoryMoods) {
    if (m.id == id) return m;
  }
  return null;
}

/// The last step before a story uploads. Returns a mood id, or null for
/// "no mood" (Skip, or the sheet was closed - the story still posts).
Future<String?> pickStoryMood(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF15121C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text('How do you feel?',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Your feeling floats around your story on Home.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 18),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95,
              children: [
                for (final StoryMood m in kStoryMoods)
                  _MoodTile(
                    mood: m,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.pop(ctx, m.id);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Skip',
                  style: TextStyle(color: Colors.white54, fontSize: 15)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MoodTile extends StatefulWidget {
  final StoryMood mood;
  final VoidCallback onTap;
  const _MoodTile({required this.mood, required this.onTap});

  @override
  State<_MoodTile> createState() => _MoodTileState();
}

class _MoodTileState extends State<_MoodTile> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
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
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(widget.mood.emoji, style: const TextStyle(fontSize: 30)),
              const SizedBox(height: 4),
              Text(widget.mood.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One stop's mood on the bar: where its circle is, and how faint.
class MoodStop {
  final Offset center;
  final StoryMood mood;
  final double opacity; // 1 = unseen, lower once seen
  const MoodStop(this.center, this.mood, this.opacity);
}

/// Floating mood emojis behind the stops of the Flight Path bar.
class StoryMoodPainter extends CustomPainter {
  final List<MoodStop> stops;
  final Animation<double> t; // 0..1, repeating (8 s)
  StoryMoodPainter({required this.stops, required this.t}) : super(repaint: t);

  static const int _perStop = 4;
  static final Map<String, TextPainter> _cache = {};

  // Laid-out emojis, cached by emoji + size + opacity step (Skia fades a
  // colour emoji by the text colour's alpha - no saveLayer per emoji).
  static TextPainter _emoji(String e, double size, double alpha) {
    final int step = (alpha * 10).round().clamp(1, 10);
    final int px = size.round();
    final String key = '$e@$px@$step';
    return _cache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: e,
          style: TextStyle(
            fontSize: px.toDouble(),
            color: Colors.black.withValues(alpha: step / 10),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double v = t.value;
    for (int s = 0; s < stops.length; s++) {
      final MoodStop st = stops[s];
      for (int k = 0; k < _perStop; k++) {
        _particle(canvas, size, st, s, k, v);
      }
    }
  }

  void _particle(
      Canvas canvas, Size size, MoodStop st, int s, int k, double v) {
    final Offset c = st.center;
    final double seed = s * 0.37 + k / _perStop;
    double p(double speed) => (v * speed + seed) % 1.0;
    // Spread the particles left/right of the circle.
    final double side = (k.isEven ? -1 : 1) * (22 + 7 * (k % 3));

    late Offset pos;
    double alpha = 1;
    double fontSize = 13;
    double angle = 0;

    switch (st.mood.motion) {
      case MoodMotion.bounce: // happy: hops up
        final double q = p(2);
        pos = Offset(
            c.dx + side,
            size.height -
                8 -
                q * (size.height - 8) -
                6 * (sin(q * pi * 6)).abs());
        alpha = sin(q * pi);
        fontSize = 13;
        break;
      case MoodMotion.sway: // love: rises swaying
        final double q = p(1.5);
        pos = Offset(c.dx + side + 8 * sin(q * pi * 4 + k),
            size.height - q * size.height);
        alpha = sin(q * pi);
        fontSize = 12 + 3 * q;
        break;
      case MoodMotion.burst: // party: shoots up spinning
        final double q = p(3);
        pos = Offset(c.dx + side * (0.6 + q), c.dy + 20 - q * 70);
        alpha = 1 - q;
        angle = q * pi * 2 * (k.isEven ? 1 : -1);
        fontSize = 12 + 4 * (1 - q);
        break;
      case MoodMotion.sleepy: // sleepy: slow drift up and right
        final double q = p(0.8);
        pos = Offset(
            c.dx + 18 + q * 22 + (k - 1.5) * 4, c.dy - 10 - q * 40 + k * 3);
        alpha = sin(q * pi) * 0.9;
        fontSize = 10 + 5 * q;
        break;
      case MoodMotion.glide: // cool: glides sideways
        final double q = p(1.2);
        pos = Offset(c.dx - 38 + q * 76, 14 + k * 26.0);
        alpha = sin(q * pi);
        break;
      case MoodMotion.fall: // sad: falls slowly like tears
        final double q = p(0.9);
        pos = Offset(c.dx + side + 2 * sin(q * pi * 2), q * size.height);
        alpha = sin(q * pi) * 0.9;
        fontSize = 12;
        break;
      case MoodMotion.shake: // angry: shakes around the circle
        final double a = k * pi / 2 + pi / 4;
        final double jitter = 2.2 * sin(v * 2 * pi * 40 + k * 3);
        pos = Offset(
            c.dx + cos(a) * 36 + jitter, c.dy + sin(a) * 30 + jitter * 0.6);
        alpha = 0.55 + 0.45 * sin(v * 2 * pi * 4 + k).abs();
        fontSize = 12;
        break;
      case MoodMotion.orbit: // thinking: circles slowly around it
        final double a = 2 * pi * (v + k / _perStop);
        pos = Offset(c.dx + cos(a) * 38, c.dy + sin(a) * 26);
        alpha = 0.5 + 0.5 * (sin(a) + 1) / 2;
        fontSize = 11 + 2 * (sin(a) + 1) / 2;
        break;
    }

    alpha = (alpha * st.opacity).clamp(0.0, 1.0);
    if (alpha <= 0.02) return;
    final TextPainter tp = _emoji(st.mood.emoji, fontSize, alpha);
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    if (angle != 0) canvas.rotate(angle);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant StoryMoodPainter old) => true;
}

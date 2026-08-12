// CapCut-style text overlay presets - shared by the effects editor, the
// upload preview, and the video feed, so a caption/sticker's style looks
// identical everywhere it's shown. Previously each of those three screens
// had its own copy of a single "outlined text" renderer; this replaces
// all three with one renderer that also supports multiple visual styles.
import 'package:flutter/material.dart';

const List<String> kTextOverlayStyles = [
  'classic',
  'background',
  'shadow',
  'neon',
  'impact',
  'gradient',
];

String textOverlayStyleLabel(String styleId) {
  switch (styleId) {
    case 'background':
      return 'Box';
    case 'shadow':
      return 'Shadow';
    case 'neon':
      return 'Neon';
    case 'impact':
      return 'Impact';
    case 'gradient':
      return 'Gradient';
    case 'classic':
    default:
      return 'Classic';
  }
}

// Renders [text] in one of the styles above. [color] is the user's chosen
// accent color - what it controls (fill, outline glow, background) varies
// by style, matching how CapCut's own text presets work.
Widget styledOverlayText(
  String text,
  double fontSize,
  Color color,
  String styleId,
) {
  switch (styleId) {
    case 'background':
      // Solid rounded chip in the chosen color, with the text color
      // auto-picked for contrast (white on a dark chip, black on a light
      // one) so it's always readable regardless of which color the user
      // picked.
      final bool darkChip = color.computeLuminance() < 0.5;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.4,
          vertical: fontSize * 0.15,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(fontSize * 0.25),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: darkChip ? Colors.white : Colors.black,
          ),
        ),
      );

    case 'shadow':
      // Soft drop shadow instead of a hard outline - reads as more
      // "cinematic caption" than "meme text".
      return Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: color,
          shadows: [
            Shadow(
              color: Colors.black.withOpacity(0.85),
              blurRadius: fontSize * 0.25,
              offset: Offset(fontSize * 0.05, fontSize * 0.1),
            ),
          ],
        ),
      );

    case 'neon':
      // Layered colored glow behind white text.
      return Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          shadows: [
            Shadow(color: color, blurRadius: fontSize * 0.25),
            Shadow(color: color, blurRadius: fontSize * 0.55),
            Shadow(
              color: color.withOpacity(0.85),
              blurRadius: fontSize * 0.9,
            ),
          ],
        ),
      );

    case 'impact':
      // Bigger, all-caps, wide letter-spacing, thick outline - the
      // meme/headline look.
      final String upper = text.toUpperCase();
      return Stack(
        children: [
          Text(
            upper,
            style: TextStyle(
              fontSize: fontSize * 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = fontSize * 0.18
                ..color = Colors.black,
            ),
          ),
          Text(
            upper,
            style: TextStyle(
              fontSize: fontSize * 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
              color: color,
            ),
          ),
        ],
      );

    case 'gradient':
      // Two-tone gradient fill (chosen color fading to white).
      return ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          colors: [color, Colors.white],
        ).createShader(bounds),
        child: Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: Colors.white, // overwritten by the shader mask above
            shadows: const [
              Shadow(color: Colors.black38, blurRadius: 4),
            ],
          ),
        ),
      );

    case 'classic':
    default:
      // The original look: solid color fill with a black stroke outline,
      // no background chip needed to stay readable.
      return Stack(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = fontSize * 0.12
                ..color = Colors.black,
            ),
          ),
          Text(
            text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      );
  }
}

// ---- Animated entrance/loop presets ----
// A separate axis from the visual styles above: these animate the text
// continuously (appearing, disappearing, typing out) rather than just
// changing how it looks. Only meant for text overlays, not stickers.

const List<String> kTextOverlayAnimations = [
  'none',
  'fadeInOut',
  'blink',
  'typewriter',
  'bounceIn',
  'slideUp',
];

String textOverlayAnimationLabel(String id) {
  switch (id) {
    case 'fadeInOut':
      return 'Fade';
    case 'blink':
      return 'Blink';
    case 'typewriter':
      return 'Typewriter';
    case 'bounceIn':
      return 'Bounce';
    case 'slideUp':
      return 'Slide';
    case 'none':
    default:
      return 'None';
  }
}

// Wraps [styledOverlayText] in a continuously-looping animation. Runs on
// its own timer (not tied to the video's playback position), so it loops
// the same way in the effects editor, the upload preview, and the feed.
class AnimatedOverlayText extends StatefulWidget {
  final String text;
  final double fontSize;
  final Color color;
  final String styleId;
  final String animationId;

  const AnimatedOverlayText({
    super.key,
    required this.text,
    required this.fontSize,
    required this.color,
    required this.styleId,
    required this.animationId,
  });

  @override
  State<AnimatedOverlayText> createState() => _AnimatedOverlayTextState();
}

class _AnimatedOverlayTextState extends State<AnimatedOverlayText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  Duration get _loopDuration {
    switch (widget.animationId) {
      case 'typewriter':
        return const Duration(milliseconds: 3200);
      case 'blink':
        return const Duration(milliseconds: 1600);
      case 'bounceIn':
        return const Duration(milliseconds: 2400);
      case 'slideUp':
        return const Duration(milliseconds: 2400);
      case 'fadeInOut':
      default:
        return const Duration(milliseconds: 2800);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _loopDuration);
    if (widget.animationId != 'none') _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant AnimatedOverlayText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationId != widget.animationId ||
        oldWidget.text != widget.text) {
      _controller.duration = _loopDuration;
      _controller.reset();
      if (widget.animationId != 'none') {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.animationId == 'none') {
      return styledOverlayText(
          widget.text, widget.fontSize, widget.color, widget.styleId);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final double t = _controller.value;

        switch (widget.animationId) {
          case 'typewriter':
            String shown = widget.text;
            if (t < 0.6) {
              final double rt = (t / 0.6).clamp(0.0, 1.0);
              final int chars = (widget.text.length * rt).round();
              shown = widget.text.substring(0, chars);
            }
            // Zero-width space keeps the widget's height stable even when
            // no characters have been revealed yet.
            return styledOverlayText(shown.isEmpty ? '\u200b' : shown,
                widget.fontSize, widget.color, widget.styleId);

          case 'blink':
            final double phase = (t * 4) % 1.0;
            final bool visible = phase < 0.6;
            return Opacity(
              opacity: visible ? 1.0 : 0.0,
              child: styledOverlayText(
                  widget.text, widget.fontSize, widget.color, widget.styleId),
            );

          case 'bounceIn':
            double scale;
            if (t < 0.3) {
              scale = Curves.elasticOut.transform(t / 0.3);
            } else if (t < 0.85) {
              scale = 1.0;
            } else {
              scale = 1.0 - ((t - 0.85) / 0.15) * 0.3;
            }
            return Transform.scale(
              scale: scale.clamp(0.0, 1.3),
              child: styledOverlayText(
                  widget.text, widget.fontSize, widget.color, widget.styleId),
            );

          case 'slideUp':
            double dy;
            double opacity;
            if (t < 0.25) {
              final double st = Curves.easeOut.transform(t / 0.25);
              dy = (1 - st) * 22;
              opacity = st;
            } else if (t < 0.8) {
              dy = 0;
              opacity = 1.0;
            } else {
              final double ft = (t - 0.8) / 0.2;
              dy = -ft * 14;
              opacity = 1.0 - ft;
            }
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, dy),
                child: styledOverlayText(
                    widget.text, widget.fontSize, widget.color, widget.styleId),
              ),
            );

          case 'fadeInOut':
          default:
            double opacity;
            if (t < 0.2) {
              opacity = t / 0.2;
            } else if (t < 0.8) {
              opacity = 1.0;
            } else {
              opacity = 1.0 - (t - 0.8) / 0.2;
            }
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: styledOverlayText(
                  widget.text, widget.fontSize, widget.color, widget.styleId),
            );
        }
      },
    );
  }
}

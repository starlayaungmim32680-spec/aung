// Part of home_screen.dart - split out 7 Oct 2026 (step 1 of breaking up
// the ~7,000-line file, a piece at a time). Small, self-contained visual
// pieces of the video feed: the Orbit Ring painter, the notification bell,
// the first-frame cover, the action-button glow, Fly's custom comment /
// share icons, flying + pop-in emoji, and the comment spotlight.
//
// It's a `part` file: it shares home_screen.dart's imports and its private
// (_) names, so moving the code here changed nothing else. Add new imports
// to home_screen.dart, not here.
part of '../home_screen.dart';

// Paints the "Orbit Ring" - a partial gradient arc around a video's
// avatar, filled proportionally to that video's reaction count. Fly's
// own take on the standard static gradient story-ring border every
// other short-video app uses, since this one actually changes based on
// engagement instead of just being decorative.
class _OrbitRingPainter extends CustomPainter {
  final double progress; // 0.0 - 1.0
  final double strokeWidth;

  _OrbitRingPainter({required this.progress, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.width - strokeWidth) / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Color(0xFF2E6BFF), Color(0xFF35E1F2), Color(0xFF2E6BFF)],
      ).createShader(rect);

    canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, arc);
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.strokeWidth != strokeWidth;
}

// Notification bell with a red badge showing the unseen notification count
class _NotificationBell extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('notifications')
          .where('seen', isEqualTo: false)
          .snapshots(),
      builder: (context, snapshot) {
        final int unseenCount =
            snapshot.hasData ? snapshot.data!.docs.length : 0;

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => NotificationsScreen(),
              ),
            );
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(
                Icons.notifications,
                color: Colors.white,
                size: 36,
                shadows: [Shadow(color: Colors.black, blurRadius: 6)],
              ),
              if (unseenCount > 0)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF4B6E),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$unseenCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// Covers a video until its first frame is really showing: the thumbnail
// plus a small spinner, and just the spinner if the stream later stops to
// rebuffer. Listens to the controller itself, so only this small widget
// rebuilds as playback moves - never the whole video item.
class _FirstFrameCover extends StatelessWidget {
  final VideoPlayerController controller;
  final String thumbUrl;

  const _FirstFrameCover({required this.controller, required this.thumbUrl});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final bool started = v.position > Duration.zero;
        // No spinner for a video sitting paused at 0:00 on purpose (e.g.
        // the screen was left before it started) - just the thumbnail.
        final bool showSpinner = (!started && v.isPlaying) || v.isBuffering;
        if (started && !showSpinner) return const SizedBox.shrink();

        return Stack(
          fit: StackFit.expand,
          children: [
            if (!started && thumbUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: thumbUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => const ColoredBox(color: Colors.black),
                errorWidget: (_, __, ___) =>
                    const ColoredBox(color: Colors.black),
              ),
            if (showSpinner)
              const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: Colors.white70,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// Shared "glow chip" used behind each icon in Fly's action dock: a soft
// cyan radial glow fades in behind the icon when that action is active
// (liked / saved), giving each button its own subtle focus state instead
// of the plain flat icons most short-video apps use.
class _FlyActionGlow extends StatelessWidget {
  final bool active;
  final Widget child;

  const _FlyActionGlow({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: active
            ? RadialGradient(
                colors: [
                  const Color(0xFF35E1E8).withOpacity(0.35),
                  const Color(0xFF35E1E8).withOpacity(0.0),
                ],
              )
            : null,
      ),
      child: child,
    );
  }
}

// Comment icon for the main action dock, drawn Facebook-Reels style: a
// plain white outline speech bubble (rounded, almost oval, with a small
// tail at the bottom-left) and a soft dark shadow so it stays readable
// over bright video frames. Ko's one addition to the Facebook look: three
// small white dots inside the bubble.
class _FlyCommentIcon extends StatelessWidget {
  final double size;
  const _FlyCommentIcon({this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FlyCommentPainter()),
    );
  }
}

class _FlyCommentPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double stroke = w * 0.085;

    // Bubble body + tail merged into one outline, so the stroke has no
    // seam where the tail meets the bubble.
    final Path body = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.08, h * 0.08, w * 0.84, h * 0.70),
        Radius.circular(h * 0.35),
      ));
    final Path tail = Path()
      ..moveTo(w * 0.22, h * 0.66)
      ..lineTo(w * 0.14, h * 0.94)
      ..lineTo(w * 0.44, h * 0.76)
      ..close();
    final Path bubble = Path.combine(PathOperation.union, body, tail);

    // Soft shadow first, then the white outline on top.
    canvas.drawPath(
      bubble,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawPath(
      bubble,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );

    // Three dots inside the bubble.
    final Paint dotShadow = Paint()
      ..color = Colors.black.withOpacity(0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    final Paint dotPaint = Paint()..color = Colors.white;
    final double dotY = h * 0.43;
    final double dotRadius = w * 0.055;
    for (final double dotX in [0.31, 0.50, 0.69]) {
      final Offset c = Offset(w * dotX, dotY);
      canvas.drawCircle(c, dotRadius + 0.5, dotShadow);
      canvas.drawCircle(c, dotRadius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FlyCommentPainter oldDelegate) => false;
}

// Share icon for the main action dock, drawn Facebook-Reels style: a white
// outline "forward" arrow (arrow head pointing right, tail curving down to
// the bottom-left) with a soft dark shadow, matching the comment icon above.
class _FlySwooshShareIcon extends StatelessWidget {
  final double size;
  const _FlySwooshShareIcon({this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FlySwooshSharePainter()),
    );
  }
}

class _FlySwooshSharePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double stroke = w * 0.085;

    final Path arrow = Path()
      ..moveTo(w * 0.92, h * 0.44) // arrow tip
      ..lineTo(w * 0.57, h * 0.12) // head, top corner
      ..lineTo(w * 0.57, h * 0.30) // where the shaft leaves the head (top)
      ..quadraticBezierTo(w * 0.16, h * 0.32, w * 0.08, h * 0.88) // tail top
      ..quadraticBezierTo(w * 0.24, h * 0.58, w * 0.57, h * 0.58) // tail bottom
      ..lineTo(w * 0.57, h * 0.76) // head, bottom corner
      ..close();

    canvas.drawPath(
      arrow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawPath(
      arrow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _FlySwooshSharePainter oldDelegate) => false;
}

// A round speech-bubble icon: a circular outline with a small pointed tail,
// matching the reference design (rather than Material's rectangular
// chat_bubble_outline icon).
// A TikTok-style comment icon: a rounded-rectangle (pill-ish) speech bubble
// outline with a small pointed tail at the bottom-left, matching Ko's
// reference image more closely than a plain circular bubble.
// A Facebook-style comment icon: a flattened oval speech-bubble outline
// with a small filled pointed tail at the bottom-left.
class _CommentBubbleIcon extends StatelessWidget {
  final double size;
  final Color color;
  final double strokeWidth;

  const _CommentBubbleIcon({
    this.size = 28,
    this.color = Colors.white,
    this.strokeWidth = 3.2,
  });

  @override
  Widget build(BuildContext context) {
    // The painter works in an 80x80 reference space; scale the box to match.
    final double boxSize = size * (80 / 60);
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: CustomPaint(
        painter:
            _FacebookCommentPainter(color: color, strokeWidth: strokeWidth),
      ),
    );
  }
}

class _FacebookCommentPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _FacebookCommentPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / 80;
    canvas.save();
    canvas.scale(scale);

    // Flattened oval bubble body (Facebook-style, not a perfect circle).
    final Rect ellipseRect =
        Rect.fromCenter(center: const Offset(40, 34), width: 60, height: 48);

    // Small filled pointed tail at the bottom-left of the bubble.
    final Path tail = Path()
      ..moveTo(28, 54)
      ..lineTo(22, 68)
      ..lineTo(38, 60)
      ..close();

    // Soft drop shadow so the icon still reads over bright video frames.
    final Paint shadowStroke = Paint()
      ..color = Colors.black38
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final Paint shadowFill = Paint()
      ..color = Colors.black38
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawOval(ellipseRect, shadowStroke);
    canvas.drawPath(tail, shadowFill);

    final Paint bodyStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawOval(ellipseRect, bodyStroke);
    canvas.drawPath(tail, Paint()..color = color);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FacebookCommentPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

// Data describing a single flying emoji's path
class _FlyingEmoji {
  final int id;
  final String emoji;
  final double startX;
  final double horizontalDrift;
  final double size;
  final int delayMs;

  _FlyingEmoji({
    required this.id,
    required this.emoji,
    required this.startX,
    required this.horizontalDrift,
    required this.size,
    required this.delayMs,
  });
}

// Animates one emoji floating upward while drifting sideways and fading out
class _FlyingEmojiWidget extends StatefulWidget {
  final _FlyingEmoji data;
  final VoidCallback onComplete;

  const _FlyingEmojiWidget({
    super.key,
    required this.data,
    required this.onComplete,
  });

  @override
  State<_FlyingEmojiWidget> createState() => _FlyingEmojiWidgetState();
}

class _FlyingEmojiWidgetState extends State<_FlyingEmojiWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onComplete();
      }
    });

    Future.delayed(Duration(milliseconds: widget.data.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value;
        final double offsetY = -320 * t;
        final double offsetX =
            widget.data.startX + widget.data.horizontalDrift * sin(t * pi);
        final double opacity = t < 0.7 ? 1.0 : (1.0 - (t - 0.7) / 0.3);
        final double scale = 0.6 + 0.6 * t;

        return Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        );
      },
      child: Text(
        widget.data.emoji,
        style: TextStyle(fontSize: widget.data.size),
      ),
    );
  }
}

class _AnimatedEmoji extends StatefulWidget {
  final String emoji;
  final int delayMs;
  final VoidCallback onTap;

  const _AnimatedEmoji({
    required this.emoji,
    required this.delayMs,
    required this.onTap,
  });

  @override
  State<_AnimatedEmoji> createState() => _AnimatedEmojiState();
}

class _AnimatedEmojiState extends State<_AnimatedEmoji>
    with TickerProviderStateMixin {
  late final AnimationController _bounceController;
  late final AnimationController _entranceController;
  late final Animation<double> _entranceScale;

  @override
  void initState() {
    super.initState();

    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _entranceScale = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.elasticOut,
    );

    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _entranceController.forward();
    });
  }

  @override
  void dispose() {
    _bounceController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _entranceScale,
        child: AnimatedBuilder(
          animation: _bounceController,
          builder: (context, child) {
            final double offsetY = -6 * _bounceController.value;
            return Transform.translate(
              offset: Offset(0, offsetY),
              child: child,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              widget.emoji,
              style: const TextStyle(fontSize: 32),
            ),
          ),
        ),
      ),
    );
  }
}

class _PopInEmoji extends StatefulWidget {
  final String emoji;

  const _PopInEmoji({super.key, required this.emoji});

  @override
  State<_PopInEmoji> createState() => _PopInEmojiState();
}

class _PopInEmojiState extends State<_PopInEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Text(
        widget.emoji,
        style: const TextStyle(fontSize: 32),
      ),
    );
  }
}

// Same pop-in animation as _PopInEmoji, but renders the "liked" state as a
// round blue-gradient badge with a white thumb-up icon inside (Facebook
// Reels style), instead of a bare emoji or icon.
class _PopInLikeBadge extends StatefulWidget {
  final double diameter;

  const _PopInLikeBadge({super.key, this.diameter = 40});

  @override
  State<_PopInLikeBadge> createState() => _PopInLikeBadgeState();
}

class _PopInLikeBadgeState extends State<_PopInLikeBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: widget.diameter,
        height: widget.diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1565C0).withOpacity(0.5),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.thumb_up_alt,
          color: Colors.white,
          size: widget.diameter * 0.5,
        ),
      ),
    );
  }
}

// A soft Fly-gradient glow that sweeps around a comment for a few seconds
// and then fades away - used when a comment notification opens the sheet,
// so your eye lands on the right comment. Also scrolls it into view.
class _CommentSpotlight extends StatefulWidget {
  final Widget child;

  const _CommentSpotlight({super.key, required this.child});

  @override
  State<_CommentSpotlight> createState() => _CommentSpotlightState();
}

class _CommentSpotlightState extends State<_CommentSpotlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        alignment: 0.25,
      );
    });
    Future.delayed(const Duration(milliseconds: 3600), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Stack(
        children: [
          // The glow layer fades out on its own; the comment stays put.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 700),
                onEnd: () {
                  if (!_visible) _sweep.stop();
                },
                child: AnimatedBuilder(
                  animation: _sweep,
                  builder: (context, _) => Container(
                    padding: const EdgeInsets.all(1.6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: SweepGradient(
                        transform: GradientRotation(_sweep.value * 2 * pi),
                        colors: const [
                          Color(0xFFFF4B6E),
                          Color(0xFF9C4DFF),
                          Color(0xFF3A8DFF),
                          Color(0xFFFF4B6E),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF9C4DFF).withValues(alpha: 0.35),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1626),
                        borderRadius: BorderRadius.circular(14.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

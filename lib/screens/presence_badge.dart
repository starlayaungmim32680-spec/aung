// A small custom "online" indicator - a gold star that gently rotates and
// pulses (rather than the plain green dot most chat apps use). Meant to sit
// as a Positioned child in a Stack over the corner of an avatar.
//
// Online is determined by the caller (see isUserOnline below) from a
// user doc's `isOnline`/`lastActive` fields, which
// main_navigation_screen.dart keeps fresh via a heartbeat while the app is
// foregrounded.
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// A user counts as online only if they were last active recently - not
// just because `isOnline` was once set true. main_navigation_screen.dart
// deliberately never writes isOnline:false on backgrounding (so briefly
// switching apps doesn't instantly show offline), so `lastActive` recency
// is what actually decides this. 60s comfortably covers a couple of
// missed 20s heartbeats without leaving a stuck "online" badge for a
// closed/crashed app.
bool isUserOnline(Map<String, dynamic>? userData) {
  if (userData == null) return false;
  final bool everOnline = userData['isOnline'] as bool? ?? false;
  final lastActive = userData['lastActive'];
  if (!everOnline || lastActive is! Timestamp) return false;
  return DateTime.now().difference(lastActive.toDate()).inSeconds < 60;
}

class SparkleStarBadge extends StatefulWidget {
  // Overall diameter of the badge circle.
  final double size;

  const SparkleStarBadge({super.key, this.size = 18});

  @override
  State<SparkleStarBadge> createState() => _SparkleStarBadgeState();
}

class _SparkleStarBadgeState extends State<SparkleStarBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2, milliseconds: 400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: const BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Gentle continuous spin, plus a slow twinkle (brightness/scale
          // pulse) layered on top so it doesn't look like a static icon.
          final double t = _controller.value;
          final double twinkle = 0.55 + 0.45 * (0.5 - (t - 0.5).abs()) * 2;
          return Transform.rotate(
            angle: t * 2 * 3.14159265,
            child: Opacity(
              opacity: twinkle.clamp(0.55, 1.0),
              child: Transform.scale(
                scale: 0.85 + 0.15 * twinkle,
                child: child,
              ),
            ),
          );
        },
        child: Icon(
          Icons.star_rounded,
          color: const Color(0xFFFFD700),
          size: widget.size * 0.78,
        ),
      ),
    );
  }
}

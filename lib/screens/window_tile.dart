// 20 Nov 2026 - "Window seats": profile / public profile / search video
// tiles drawn as airplane windows (Ko picked design A on the canvas "Fly
// profile video grid - ideas") instead of TikTok's square grid.
//
//   - a rounded "window" frame (navy) around the thumbnail, a soft glare
//     at the top of the glass, the view count in a pill at the BOTTOM
//     CENTRE (TikTok puts it bottom-left);
//   - "Passport stamp" (Fly's own idea): on someone else's profile and in
//     search, a video I have already watched gets a GOLD frame and a
//     round stamp with a plane, tilted like a real passport stamp - "I
//     have been here". (Other apps use a thin progress line.)
//
// Watched = my posts/{postId}/views/{me} doc exists (written by the feed
// when I first watch a video). [WatchedVideos] keeps the answers for the
// app run, and the feed marks a video the moment it is watched, so going
// back to a profile shows the stamp at once.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_utils.dart';

class WatchedVideos {
  WatchedVideos._();

  /// Post ids I have watched (known so far this app run).
  static final ValueNotifier<Set<String>> watched =
      ValueNotifier<Set<String>>(<String>{});
  static final Set<String> _checked = <String>{};
  static String? _uid;

  // 21 Nov 2026 (Fly Mix): the watched ids are also kept ON THE PHONE
  // (SharedPreferences, per account, newest 800), so after a restart the
  // Home feed already knows what I have seen - no reads needed.
  static const int _keep = 800;
  static Timer? _saveTimer;

  static String? _me() {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != _uid) {
      // Another account signed in - forget the old one's answers.
      _uid = uid;
      _checked.clear();
      watched.value = <String>{};
      _load(uid);
    }
    return uid;
  }

  /// Called once at app start (main), never waits for anything.
  static void warmUp() => _me();

  static void _load(String? uid) {
    if (uid == null) return;
    SharedPreferences.getInstance().then((p) {
      if (_uid != uid) return; // account changed meanwhile
      final List<String> ids = p.getStringList('watched_$uid') ?? const [];
      if (ids.isEmpty) return;
      watched.value = <String>{...ids, ...watched.value};
      _checked.addAll(ids);
    }).catchError((Object _) {});
  }

  static void _save() {
    final String? uid = _uid;
    if (uid == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      final List<String> all = watched.value.toList();
      final List<String> keep =
          all.length > _keep ? all.sublist(all.length - _keep) : all;
      SharedPreferences.getInstance()
          .then((p) => p.setStringList('watched_$uid', keep))
          .catchError((Object _) => false);
    });
  }

  /// The feed calls this when I watch a video.
  static void mark(String postId) {
    if (postId.isEmpty || _me() == null) return;
    _checked.add(postId);
    if (watched.value.contains(postId)) return;
    watched.value = <String>{...watched.value, postId};
    _save();
  }

  /// Looks it up once per app run (one small read: my own view doc).
  static void check(String postId) {
    final String? me = _me();
    if (postId.isEmpty || me == null || _checked.contains(postId)) return;
    _checked.add(postId);
    FirebaseFirestore.instance
        .collection('posts')
        .doc(postId)
        .collection('views')
        .doc(me)
        .get()
        .then((d) {
      if (d.exists) mark(postId);
    }).catchError((Object _) {
      _checked.remove(postId); // try again next time
    });
  }
}

class FlyWindowTile extends StatefulWidget {
  final String videoUrl;
  final String postId;
  final bool isRepost;

  /// Show the gold frame + passport stamp when I watched it (other
  /// people's videos only).
  final bool showWatched;

  const FlyWindowTile({
    super.key,
    required this.videoUrl,
    required this.postId,
    this.isRepost = false,
    this.showWatched = false,
  });

  @override
  State<FlyWindowTile> createState() => _FlyWindowTileState();
}

class _FlyWindowTileState extends State<FlyWindowTile> {
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _post;

  static const List<Color> _navy = [Color(0xFF33406A), Color(0xFF1B2340)];
  static const List<Color> _gold = [Color(0xFFF2C46D), Color(0xFFA87E33)];
  static const Color _goldInk = Color(0xFFF2C46D);

  @override
  void initState() {
    super.initState();
    _post = _postStream();
    if (widget.showWatched) WatchedVideos.check(widget.postId);
  }

  @override
  void didUpdateWidget(covariant FlyWindowTile old) {
    super.didUpdateWidget(old);
    if (old.postId != widget.postId) {
      _post = _postStream();
      if (widget.showWatched) WatchedVideos.check(widget.postId);
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _postStream() =>
      FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .snapshots();

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  Widget _thumb() {
    final String thumbUrl = cloudinaryThumbUrl(widget.videoUrl);
    const Widget fallback = Center(
      child: Icon(Icons.play_circle_outline, color: Colors.white30, size: 30),
    );
    if (thumbUrl.isEmpty) return fallback;
    return CachedNetworkImage(
      imageUrl: thumbUrl,
      fit: BoxFit.cover,
      placeholder: (context, url) => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
        ),
      ),
      errorWidget: (context, url, error) => fallback,
    );
  }

  Widget _viewsPill() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _post,
      builder: (context, snap) {
        final int views =
            (snap.data?.data()?['viewCount'] as num?)?.toInt() ?? 0;
        return Container(
          padding: const EdgeInsets.fromLTRB(5, 2, 8, 2),
          decoration: BoxDecoration(
            color: const Color(0xA0080C1E),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 14),
              const SizedBox(width: 1),
              Text(
                _fmt(views),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stamp() {
    return Transform.rotate(
      angle: -14 * math.pi / 180,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xEB17203F),
          border: Border.all(color: _goldInk, width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x40F2C46D), spreadRadius: 2),
          ],
        ),
        child: Transform.rotate(
          angle: math.pi / 4,
          child: const Icon(Icons.flight_rounded, color: _goldInk, size: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: WatchedVideos.watched,
      builder: (context, watched, _) {
        final bool seen = widget.showWatched && watched.contains(widget.postId);
        return LayoutBuilder(builder: (context, box) {
          // An oval-ish window: corners about a third of the width.
          final double r = box.maxWidth * 0.34;
          return Semantics(
            label: seen ? 'Video, watched' : 'Video',
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(r),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: seen ? _gold : _navy,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x59000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(r - 4),
                      child: ColoredBox(
                        color: const Color(0xFF151B33),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _thumb(),
                            // Glare on the top of the glass.
                            const Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                height: 18,
                                width: double.infinity,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x38FFFFFF),
                                        Color(0x00FFFFFF),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.isRepost)
                              Positioned(
                                top: 10,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                      color: Color(0x8C000000),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.repeat_rounded,
                                        color: Colors.white, size: 13),
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 8,
                              child: Center(child: _viewsPill()),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (seen) Positioned(right: -4, top: -4, child: _stamp()),
              ],
            ),
          );
        });
      },
    );
  }
}

// "Saved" - the signed-in user's own bookmarked videos, newest save first.
//
// Tapping the bookmark on a video (home_screen.dart's _toggleSave) writes
// two docs in one batch: posts/{postId}/saves/{uid} (used for the count on
// the video) and users/{uid}/saved/{postId} (this screen's list). This list
// is private - Firestore rules let only its owner read it.
//
// The list only stores post ids; the real post docs are fetched fresh, so
// a saved video shows its current caption/effects, and a video its owner
// has since deleted simply drops out of the grid instead of showing a
// broken tile.
//
// Opened from the bookmark icon in profile_screen.dart's AppBar.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'home_screen.dart' show SavedVideosFeedScreen;
import 'media_utils.dart';

class SavedVideosScreen extends StatefulWidget {
  const SavedVideosScreen({super.key});

  @override
  State<SavedVideosScreen> createState() => _SavedVideosScreenState();
}

class _SavedVideosScreenState extends State<SavedVideosScreen> {
  StreamSubscription<QuerySnapshot>? _savedSub;

  // Post docs to show, in saved order (newest first). null = still loading.
  List<DocumentSnapshot>? _posts;

  // Bumped on every new snapshot, so an older, slower post fetch can't
  // overwrite the result of a newer one.
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) {
      _posts = const [];
      return;
    }
    // Subscribed once here, not in build() (Fly's stream rule).
    _savedSub = FirebaseFirestore.instance
        .collection('users')
        .doc(myId)
        .collection('saved')
        .orderBy('savedAt', descending: true)
        .snapshots()
        .listen(_onSavedChanged, onError: (_) {
      if (mounted) setState(() => _posts = const []);
    });
  }

  @override
  void dispose() {
    _savedSub?.cancel();
    super.dispose();
  }

  Future<void> _onSavedChanged(QuerySnapshot snap) async {
    final int token = ++_loadToken;
    final List<String> ids = snap.docs.map((d) => d.id).toList();

    // whereIn accepts at most 10 values per query, so fetch in chunks.
    final Map<String, DocumentSnapshot> byId = {};
    try {
      for (int i = 0; i < ids.length; i += 10) {
        final List<String> chunk =
            ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
        final QuerySnapshot result = await FirebaseFirestore.instance
            .collection('posts')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in result.docs) {
          byId[doc.id] = doc;
        }
      }
    } catch (_) {
      // Keep whatever loaded; a network blip shouldn't blank the screen.
    }

    if (!mounted || token != _loadToken) return;
    setState(() {
      // Back in saved order; deleted posts are simply missing from byId.
      _posts = [
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ];
    });
  }

  Future<void> _confirmUnsave(DocumentSnapshot post) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Remove from Saved?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This video will be removed from your saved list.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Same two docs _toggleSave writes, removed together.
    final batch = FirebaseFirestore.instance.batch();
    batch.delete(FirebaseFirestore.instance
        .collection('posts')
        .doc(post.id)
        .collection('saves')
        .doc(myId));
    batch.delete(FirebaseFirestore.instance
        .collection('users')
        .doc(myId)
        .collection('saved')
        .doc(post.id));
    try {
      await batch.commit();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Couldn't remove it right now. Please try again.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<DocumentSnapshot>? posts = _posts;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Saved', style: TextStyle(color: Colors.white)),
      ),
      body: posts == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            )
          : posts.isEmpty
              ? const _SavedEmptyState()
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                    childAspectRatio: 0.7,
                  ),
                  itemCount: posts.length,
                  itemBuilder: (context, index) {
                    final DocumentSnapshot post = posts[index];
                    final String videoUrl =
                        ((post.data() as Map<String, dynamic>?)?['videoUrl']
                                as String?) ??
                            '';
                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SavedVideosFeedScreen(
                            posts: posts,
                            initialIndex: index,
                          ),
                        ),
                      ),
                      onLongPress: () => _confirmUnsave(post),
                      child: _SavedThumbnail(videoUrl: videoUrl),
                    );
                  },
                ),
    );
  }
}

class _SavedThumbnail extends StatelessWidget {
  final String videoUrl;
  const _SavedThumbnail({required this.videoUrl});

  @override
  Widget build(BuildContext context) {
    final String thumbUrl = cloudinaryThumbUrl(videoUrl);
    const Widget fallback = Center(
      child: Icon(Icons.play_circle_outline, color: Colors.white30, size: 30),
    );

    return Container(
      color: Colors.grey[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumbUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: thumbUrl,
              fit: BoxFit.cover,
              placeholder: (context, url) => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white24),
                ),
              ),
              errorWidget: (context, url, error) => fallback,
            )
          else
            fallback,
          // Small bookmark badge, so the grid reads as "saved" at a glance.
          const Positioned(
            top: 6,
            right: 6,
            child: Icon(
              Icons.bookmark,
              color: Colors.white,
              size: 18,
              shadows: [Shadow(color: Colors.black, blurRadius: 4)],
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedEmptyState extends StatelessWidget {
  const _SavedEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, color: Colors.white38, size: 64),
            SizedBox(height: 16),
            Text(
              'No saved videos yet',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the bookmark on any video to keep it here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

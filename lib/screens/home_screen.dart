import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';

// Available reaction types and their emojis
const Map<String, String> kReactions = {
  'like': '👍',
  'love': '❤️',
  'haha': '😂',
  'wow': '😮',
  'sad': '😢',
  'angry': '😡',
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToNextVideo(int totalCount) {
    final int? currentPage = _pageController.page?.round();
    if (currentPage != null && currentPage < totalCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text(
                'No posts yet. Be the first to upload!',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }

          final posts = snapshot.data!.docs;

          return Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final postDoc = posts[index];
                  final post = postDoc.data() as Map<String, dynamic>;
                  final Map<String, dynamic> reactions =
                      (post['reactions'] as Map<String, dynamic>?) ?? {};

                  return _VideoPostItem(
                    postId: postDoc.id,
                    userId: post['userId'] ?? '',
                    videoUrl: post['videoUrl'] ?? '',
                    caption: post['caption'] ?? '',
                    userEmail: post['userEmail'] ?? 'Unknown user',
                    reactions: reactions,
                    onVideoEnd: () => _goToNextVideo(posts.length),
                  );
                },
              ),
              const SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Center(
                    child: Text(
                      'Fly',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VideoPostItem extends StatefulWidget {
  final String postId;
  final String userId;
  final String videoUrl;
  final String caption;
  final String userEmail;
  final Map<String, dynamic> reactions;
  final VoidCallback onVideoEnd;

  const _VideoPostItem({
    required this.postId,
    required this.userId,
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
    required this.reactions,
    required this.onVideoEnd,
  });

  @override
  State<_VideoPostItem> createState() => _VideoPostItemState();
}

class _VideoPostItemState extends State<_VideoPostItem> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _showPauseIcon = false;
  bool _hasEnded = false;
  bool _showReactionPicker = false;

  // Holds the currently flying emojis
  final List<_FlyingEmoji> _flyingEmojis = [];

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    if (widget.videoUrl.isEmpty) return;

    final controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    await controller.initialize();
    controller.play();
    controller.addListener(_onVideoProgress);

    if (mounted) {
      setState(() {
        _controller = controller;
        _isInitialized = true;
      });
    }
  }

  void _onVideoProgress() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final position = controller.value.position;
    final duration = controller.value.duration;

    if (!_hasEnded &&
        duration.inMilliseconds > 0 &&
        position.inMilliseconds >= duration.inMilliseconds - 200) {
      _hasEnded = true;
      widget.onVideoEnd();
    }
  }

  void _handleScreenTap() {
    if (_showReactionPicker) {
      setState(() => _showReactionPicker = false);
      return;
    }
    _togglePlayPause();
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _showPauseIcon = true;
      } else {
        _controller!.play();
        _showPauseIcon = false;
      }
    });
  }

  // Spawns a single flying emoji that floats up and fades out
  void _spawnFlyingEmojis(String emoji) {
    final flyingEmoji = _FlyingEmoji(
      id: DateTime.now().microsecondsSinceEpoch,
      emoji: emoji,
      startX: 0,
      horizontalDrift: 20,
      size: 40,
      delayMs: 0,
    );
    _flyingEmojis.add(flyingEmoji);
    setState(() {});
  }

  void _removeFlyingEmoji(int id) {
    _flyingEmojis.removeWhere((e) => e.id == id);
    if (mounted) setState(() {});
  }

  Future<void> _setReaction(String type) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);
    final String? currentReaction = widget.reactions[user.uid] as String?;

    setState(() => _showReactionPicker = false);

    if (currentReaction == type) {
      await postRef.update({'reactions.${user.uid}': FieldValue.delete()});
    } else {
      await postRef.update({'reactions.${user.uid}': type});
      _spawnFlyingEmojis(kReactions[type]!);
    }
  }

  void _quickToggleLike() {
    _setReaction('like');
  }

  // Opens the comments bottom sheet for this post
  void _openComments() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _CommentsSheet(postId: widget.postId),
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoProgress);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final String? myReaction =
        user != null ? widget.reactions[user.uid] as String? : null;
    final int reactionCount = widget.reactions.length;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleScreenTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_isInitialized && _controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            ),
          if (_showPauseIcon)
            const Center(
              child: Icon(
                Icons.play_arrow,
                color: Colors.white70,
                size: 80,
              ),
            ),
          if (_isInitialized && _controller != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                _controller!,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.redAccent,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white10,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
            ),
          Positioned(
            left: 16,
            bottom: 100,
            right: 90,
            child: _OwnerInfo(
              userId: widget.userId,
              fallbackEmail: widget.userEmail,
              caption: widget.caption,
            ),
          ),
          ..._flyingEmojis.map((e) {
            return Positioned(
              right: 30,
              bottom: 300,
              child: _FlyingEmojiWidget(
                key: ValueKey(e.id),
                data: e,
                onComplete: () => _removeFlyingEmoji(e.id),
              ),
            );
          }),
          if (_showReactionPicker)
            Positioned(
              right: 12,
              bottom: 340,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: kReactions.entries.map((entry) {
                    final int i = kReactions.keys.toList().indexOf(entry.key);
                    return _AnimatedEmoji(
                      emoji: entry.value,
                      delayMs: i * 90,
                      onTap: () => _setReaction(entry.key),
                    );
                  }).toList(),
                ),
              ),
            ),
          Positioned(
            right: 12,
            bottom: 280,
            child: Column(
              children: [
                // Reaction button (icon only)
                GestureDetector(
                  onTap: _quickToggleLike,
                  onLongPress: () => setState(() => _showReactionPicker = true),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: myReaction != null
                              ? _PopInEmoji(
                                  key: ValueKey(myReaction),
                                  emoji: kReactions[myReaction]!,
                                )
                              : const Icon(
                                  Icons.favorite_border,
                                  color: Colors.white,
                                  size: 36,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 6)
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$reactionCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                // Comment button - circular shape, shows live comment count
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('posts')
                      .doc(widget.postId)
                      .collection('comments')
                      .snapshots(),
                  builder: (context, snapshot) {
                    final int commentCount =
                        snapshot.hasData ? snapshot.data!.docs.length : 0;
                    return GestureDetector(
                      onTap: _openComments,
                      child: Column(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
                              ),
                              border:
                                  Border.all(color: Colors.white24, width: 1),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.mode_comment_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$commentCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 6)
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 22),
                // Share button (icon only)
                _buildIconButton(
                  icon: Icons.send,
                  label: 'Share',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Builds an icon-only action button with a label below (no background)
  Widget _buildIconButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(
            icon,
            color: Colors.white,
            size: 36,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black, blurRadius: 6)],
            ),
          ),
        ],
      ),
    );
  }
}

// Bottom sheet that shows comments and lets the user add one
class _CommentsSheet extends StatefulWidget {
  final String postId;

  const _CommentsSheet({required this.postId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _sendComment() async {
    final user = FirebaseAuth.instance.currentUser;
    final String text = _commentController.text.trim();
    if (user == null || text.isEmpty) return;

    setState(() => _isSending = true);

    // Look up the sender's profile name/photo
    final profileDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final profile = profileDoc.data();
    final String displayName =
        (profile?['displayName'] as String?)?.trim().isNotEmpty == true
            ? profile!['displayName']
            : (user.email?.split('@').first ?? 'User');
    final String photoUrl = (profile?['photoUrl'] as String?) ?? '';

    await FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('comments')
        .add({
      'userId': user.uid,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });

    _commentController.clear();
    if (mounted) setState(() => _isSending = false);
  }

  @override
  Widget build(BuildContext context) {
    // Push the sheet above the keyboard
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          // Grab handle + title
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Comments',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: Colors.white12, height: 1),

          // Comments list
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(widget.postId)
                  .collection('comments')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                final comments = snapshot.data?.docs ?? [];

                if (comments.isEmpty) {
                  return Center(
                    child: Text(
                      'No comments yet. Say something!',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: comments.length,
                  itemBuilder: (context, index) {
                    final c = comments[index].data() as Map<String, dynamic>;
                    final String name = c['displayName'] ?? 'User';
                    final String text = c['text'] ?? '';
                    final String photoUrl = c['photoUrl'] ?? '';

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.grey[800],
                            backgroundImage: photoUrl.isNotEmpty
                                ? NetworkImage(photoUrl)
                                : null,
                            child: photoUrl.isEmpty
                                ? Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  text,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          // Comment input row - padded above the phone's bottom navigation bar
          Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 8 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentController,
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Add a comment...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey[900],
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _isSending ? null : _sendComment,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
                      ),
                    ),
                    child: _isSending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Shows the post owner's profile photo and display name (from the users collection)
class _OwnerInfo extends StatelessWidget {
  final String userId;
  final String fallbackEmail;
  final String caption;

  const _OwnerInfo({
    required this.userId,
    required this.fallbackEmail,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: userId.isEmpty
          ? null
          : FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .snapshots(),
      builder: (context, snapshot) {
        final Map<String, dynamic>? profile =
            snapshot.data?.data() as Map<String, dynamic>?;

        final String displayName =
            (profile?['displayName'] as String?)?.trim().isNotEmpty == true
                ? profile!['displayName']
                : (fallbackEmail.contains('@')
                    ? fallbackEmail.split('@').first
                    : fallbackEmail);
        final String? photoUrl = profile?['photoUrl'] as String?;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.grey[850],
                    backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                        ? NetworkImage(photoUrl)
                        : null,
                    child: (photoUrl == null || photoUrl.isEmpty)
                        ? Text(
                            displayName.isNotEmpty
                                ? displayName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                ),
              ],
            ),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                caption,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
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

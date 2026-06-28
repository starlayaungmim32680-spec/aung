import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'notifications_screen.dart';

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
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Center(
                        child: Text(
                          'Fly',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 0,
                        child: _NotificationBell(),
                      ),
                    ],
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

  Future<void> _createNotification({
    required String type,
    required String text,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (widget.userId.isEmpty || widget.userId == user.uid) return;

    final myProfile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = myProfile.data();
    final String myName =
        (data?['displayName'] as String?)?.trim().isNotEmpty == true
            ? data!['displayName']
            : (user.email?.split('@').first ?? 'Someone');
    final String myPhoto = (data?['photoUrl'] as String?) ?? '';

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .collection('notifications')
        .add({
      'type': type,
      'text': text,
      'fromId': user.uid,
      'fromName': myName,
      'fromPhoto': myPhoto,
      'postId': widget.postId,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
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
      _createNotification(type: 'reaction', text: kReactions[type]!);
    }
  }

  void _quickToggleLike() {
    _setReaction('like');
  }

  Future<void> _shareVideo() async {
    final String shareText = widget.caption.isNotEmpty
        ? '${widget.caption}\n\nWatch on Fly: ${widget.videoUrl}'
        : 'Watch this video on Fly: ${widget.videoUrl}';
    await Share.share(shareText);
  }

  void _openComments() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _CommentsSheet(
        postId: widget.postId,
        ownerId: widget.userId,
      ),
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
                _buildIconButton(
                  icon: Icons.send,
                  label: 'Share',
                  onTap: _shareVideo,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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

// Bottom sheet that shows comments, replies, and emoji reactions
class _CommentsSheet extends StatefulWidget {
  final String postId;
  final String ownerId;

  const _CommentsSheet({required this.postId, required this.ownerId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isSending = false;

  String? _replyToCommentId;
  String? _replyToName;

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _getMyProfile(String uid, String? email) async {
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = doc.data();
    final String name =
        (data?['displayName'] as String?)?.trim().isNotEmpty == true
            ? data!['displayName']
            : (email?.split('@').first ?? 'User');
    final String photo = (data?['photoUrl'] as String?) ?? '';
    return {'name': name, 'photo': photo};
  }

  void _startReply(String commentId, String name) {
    setState(() {
      _replyToCommentId = commentId;
      _replyToName = name;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToCommentId = null;
      _replyToName = null;
    });
  }

  Future<void> _sendComment() async {
    final user = FirebaseAuth.instance.currentUser;
    final String text = _commentController.text.trim();
    if (user == null || text.isEmpty) return;

    setState(() => _isSending = true);

    final profile = await _getMyProfile(user.uid, user.email);
    final String displayName = profile['name']!;
    final String photoUrl = profile['photo']!;

    final commentsRef = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('comments');

    if (_replyToCommentId == null) {
      await commentsRef.add({
        'userId': user.uid,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'text': text,
        'reactions': <String, dynamic>{},
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (widget.ownerId.isNotEmpty && widget.ownerId != user.uid) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.ownerId)
            .collection('notifications')
            .add({
          'type': 'comment',
          'text': text,
          'fromId': user.uid,
          'fromName': displayName,
          'fromPhoto': photoUrl,
          'postId': widget.postId,
          'seen': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } else {
      await commentsRef.doc(_replyToCommentId).collection('replies').add({
        'userId': user.uid,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'text': text,
        'reactions': <String, dynamic>{},
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    _commentController.clear();
    _cancelReply();
    if (mounted) setState(() => _isSending = false);
  }

  // Sets or removes the current user's emoji reaction on a comment/reply
  Future<void> _setReaction(DocumentReference ref,
      Map<String, dynamic> reactions, String type) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final String? current = reactions[user.uid] as String?;
    if (current == type) {
      await ref.update({'reactions.${user.uid}': FieldValue.delete()});
    } else {
      await ref.update({'reactions.${user.uid}': type});
    }
  }

  // Opens the emoji picker for a comment/reply reaction
  void _openReactionPicker(
      DocumentReference ref, Map<String, dynamic> reactions) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF222222),
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: kReactions.entries.map((entry) {
              final int i = kReactions.keys.toList().indexOf(entry.key);
              return _AnimatedEmoji(
                emoji: entry.value,
                delayMs: i * 60,
                onTap: () {
                  Navigator.pop(ctx);
                  _setReaction(ref, reactions, entry.key);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
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
                    final doc = comments[index];
                    return _CommentTile(
                      commentRef: doc.reference,
                      data: doc.data() as Map<String, dynamic>,
                      onReply: _startReply,
                      onReact: _openReactionPicker,
                    );
                  },
                );
              },
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          if (_replyToName != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.white.withOpacity(0.05),
              child: Row(
                children: [
                  Text(
                    'Replying to $_replyToName',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _cancelReply,
                    child:
                        const Icon(Icons.close, color: Colors.grey, size: 18),
                  ),
                ],
              ),
            ),
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
                    focusNode: _focusNode,
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: _replyToName != null
                          ? 'Write a reply...'
                          : 'Add a comment...',
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

// Shows the distinct emoji reactions present plus the total count
class _ReactionSummary extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final VoidCallback onTap;
  final double emojiSize;

  const _ReactionSummary({
    required this.reactions,
    required this.onTap,
    this.emojiSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    // Get the distinct reaction types present (e.g. like, haha, angry)
    final List<String> distinctTypes =
        reactions.values.map((e) => e.toString()).toSet().toList();
    final int count = reactions.length;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          if (distinctTypes.isEmpty)
            Icon(Icons.add_reaction_outlined,
                color: Colors.grey[500], size: emojiSize + 2)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: distinctTypes
                  .take(3)
                  .map((type) => Text(
                        kReactions[type] ?? '',
                        style: TextStyle(fontSize: emojiSize),
                      ))
                  .toList(),
            ),
          if (count > 0)
            Text(
              '$count',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// A single comment with emoji reactions, a reply button, and its replies
class _CommentTile extends StatefulWidget {
  final DocumentReference commentRef;
  final Map<String, dynamic> data;
  final void Function(String commentId, String name) onReply;
  final void Function(DocumentReference ref, Map<String, dynamic> reactions)
      onReact;

  const _CommentTile({
    required this.commentRef,
    required this.data,
    required this.onReply,
    required this.onReact,
  });

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  bool _showReplies = false;

  @override
  Widget build(BuildContext context) {
    final String name = widget.data['displayName'] ?? 'User';
    final String text = widget.data['text'] ?? '';
    final String photoUrl = widget.data['photoUrl'] ?? '';
    final Map<String, dynamic> reactions =
        (widget.data['reactions'] as Map<String, dynamic>?) ?? {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: Colors.grey[800],
                backgroundImage:
                    photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                child: photoUrl.isEmpty
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
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
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () =>
                              widget.onReply(widget.commentRef.id, name),
                          child: Text(
                            'Reply',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        StreamBuilder<QuerySnapshot>(
                          stream: widget.commentRef
                              .collection('replies')
                              .snapshots(),
                          builder: (context, snapshot) {
                            final int replyCount = snapshot.hasData
                                ? snapshot.data!.docs.length
                                : 0;
                            if (replyCount == 0) return const SizedBox.shrink();
                            return GestureDetector(
                              onTap: () =>
                                  setState(() => _showReplies = !_showReplies),
                              child: Text(
                                _showReplies
                                    ? 'Hide replies'
                                    : 'View $replyCount ${replyCount == 1 ? "reply" : "replies"}',
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Emoji reaction button for this comment
              _ReactionSummary(
                reactions: reactions,
                onTap: () => widget.onReact(widget.commentRef, reactions),
              ),
            ],
          ),
        ),
        if (_showReplies)
          StreamBuilder<QuerySnapshot>(
            stream: widget.commentRef
                .collection('replies')
                .orderBy('createdAt', descending: false)
                .snapshots(),
            builder: (context, snapshot) {
              final replies = snapshot.data?.docs ?? [];
              return Column(
                children: replies.map((replyDoc) {
                  return _ReplyTile(
                    replyRef: replyDoc.reference,
                    data: replyDoc.data() as Map<String, dynamic>,
                    onReact: widget.onReact,
                  );
                }).toList(),
              );
            },
          ),
      ],
    );
  }
}

// A single reply (indented) with emoji reactions
class _ReplyTile extends StatelessWidget {
  final DocumentReference replyRef;
  final Map<String, dynamic> data;
  final void Function(DocumentReference ref, Map<String, dynamic> reactions)
      onReact;

  const _ReplyTile({
    required this.replyRef,
    required this.data,
    required this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    final String name = data['displayName'] ?? 'User';
    final String text = data['text'] ?? '';
    final String photoUrl = data['photoUrl'] ?? '';
    final Map<String, dynamic> reactions =
        (data['reactions'] as Map<String, dynamic>?) ?? {};

    return Padding(
      padding: const EdgeInsets.only(left: 56, right: 16, top: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.grey[800],
            backgroundImage:
                photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
            child: photoUrl.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          // Emoji reaction button for this reply
          _ReactionSummary(
            reactions: reactions,
            onTap: () => onReact(replyRef, reactions),
            emojiSize: 14,
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
                builder: (context) => const NotificationsScreen(),
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

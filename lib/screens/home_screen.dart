import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';

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
                  final List<dynamic> likedBy = post['likedBy'] ?? [];

                  return _VideoPostItem(
                    postId: postDoc.id,
                    videoUrl: post['videoUrl'] ?? '',
                    caption: post['caption'] ?? '',
                    userEmail: post['userEmail'] ?? 'Unknown user',
                    likedBy: likedBy.cast<String>(),
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
  final String videoUrl;
  final String caption;
  final String userEmail;
  final List<String> likedBy;
  final VoidCallback onVideoEnd;

  const _VideoPostItem({
    required this.postId,
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
    required this.likedBy,
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

  Future<void> _toggleLike() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);

    if (widget.likedBy.contains(user.uid)) {
      await postRef.update({
        'likedBy': FieldValue.arrayRemove([user.uid]),
      });
    } else {
      await postRef.update({
        'likedBy': FieldValue.arrayUnion([user.uid]),
      });
    }
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
    final bool isLiked = user != null && widget.likedBy.contains(user.uid);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlayPause,
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
            right: 80,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.userEmail,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.caption,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            bottom: 280,
            child: Column(
              children: [
                GestureDetector(
                  onTap: _toggleLike,
                  child: Column(
                    children: [
                      Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? Colors.redAccent : Colors.white,
                        size: 32,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.likedBy.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Icon(Icons.comment_outlined,
                    color: Colors.white, size: 32),
                const SizedBox(height: 20),
                const Icon(Icons.share_outlined, color: Colors.white, size: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

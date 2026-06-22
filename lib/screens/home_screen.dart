import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
                  final post = posts[index].data() as Map<String, dynamic>;
                  return _VideoPostItem(
                    videoUrl: post['videoUrl'] ?? '',
                    caption: post['caption'] ?? '',
                    userEmail: post['userEmail'] ?? 'Unknown user',
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
  final String videoUrl;
  final String caption;
  final String userEmail;
  final VoidCallback onVideoEnd;

  const _VideoPostItem({
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
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
    // No looping - video ends naturally so we can detect completion and move to next
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

    // Detect when the video has finished playing
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

  @override
  void dispose() {
    _controller?.removeListener(_onVideoProgress);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

          // Pause icon overlay - shows when video is paused after a tap
          if (_showPauseIcon)
            const Center(
              child: Icon(
                Icons.play_arrow,
                color: Colors.white70,
                size: 80,
              ),
            ),

          // Seek/skip bar - lets users scrub or tap to skip through the video
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
            bottom: 100,
            child: Column(
              children: const [
                Icon(Icons.favorite_border, color: Colors.white, size: 32),
                SizedBox(height: 20),
                Icon(Icons.comment_outlined, color: Colors.white, size: 32),
                SizedBox(height: 20),
                Icon(Icons.share_outlined, color: Colors.white, size: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';
import 'chat_screen.dart';

// Shows another user's profile: their photo, name, video grid, and a message button
class PublicProfileScreen extends StatelessWidget {
  final String userId;

  const PublicProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .snapshots(),
        builder: (context, profileSnapshot) {
          final Map<String, dynamic>? profile =
              profileSnapshot.data?.data() as Map<String, dynamic>?;

          final String displayName =
              (profile?['displayName'] as String?)?.trim().isNotEmpty == true
                  ? profile!['displayName']
                  : 'User';
          final String photoUrl = (profile?['photoUrl'] as String?) ?? '';

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .where('userId', isEqualTo: userId)
                .snapshots(),
            builder: (context, snapshot) {
              final int postCount =
                  snapshot.hasData ? snapshot.data!.docs.length : 0;

              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 44,
                              backgroundColor: Colors.grey[850],
                              backgroundImage: photoUrl.isNotEmpty
                                  ? NetworkImage(photoUrl)
                                  : null,
                              child: photoUrl.isEmpty
                                  ? Text(
                                      displayName.isNotEmpty
                                          ? displayName[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 36,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            displayName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Message button
                          SizedBox(
                            width: 200,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ChatThreadScreen(
                                      otherUserId: userId,
                                      otherUserName: displayName,
                                      otherUserPhoto: photoUrl,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.send, size: 18),
                              label: const Text('Message'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF3A8DFF),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Column(
                            children: [
                              Text(
                                '$postCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Posts',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 13),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const Divider(color: Colors.white12, height: 1),
                        ],
                      ),
                    ),
                  ),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child:
                            CircularProgressIndicator(color: Colors.redAccent),
                      ),
                    )
                  else if (postCount == 0)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.videocam_off_outlined,
                                color: Colors.grey[700], size: 56),
                            const SizedBox(height: 12),
                            Text(
                              'No posts yet',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(2),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                          childAspectRatio: 0.7,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final post = snapshot.data!.docs[index].data()
                                as Map<String, dynamic>;
                            return _VideoThumbnail(
                              videoUrl: post['videoUrl'] ?? '',
                              caption: post['caption'] ?? '',
                            );
                          },
                          childCount: postCount,
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// A single video thumbnail tile that shows the first frame of the video
class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String caption;

  const _VideoThumbnail({required this.videoUrl, required this.caption});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (widget.videoUrl.isEmpty) return;
    final controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    await controller.initialize();
    await controller.seekTo(Duration.zero);
    if (mounted) {
      setState(() {
        _controller = controller;
        _isInitialized = true;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
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
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white30, size: 30),
            ),
          const Positioned(
            top: 6,
            right: 6,
            child: Icon(Icons.play_arrow, color: Colors.white, size: 18),
          ),
          if (widget.caption.isNotEmpty)
            Positioned(
              left: 4,
              right: 4,
              bottom: 4,
              child: Text(
                widget.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

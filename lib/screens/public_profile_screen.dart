import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';
import 'chat_screen.dart';
import 'home_screen.dart';

// Shows another user's profile: photo, name, follow button, video grid, message
class PublicProfileScreen extends StatelessWidget {
  final String userId;

  const PublicProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    final bool isMe = myId == userId;

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

                          // Stats row: posts / followers / following
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _StatColumn(label: 'Posts', value: postCount),
                              _CountStat(
                                label: 'Followers',
                                collectionRef: FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(userId)
                                    .collection('followers'),
                              ),
                              _CountStat(
                                label: 'Following',
                                collectionRef: FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(userId)
                                    .collection('following'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),

                          // Follow + Message buttons (Facebook style, hidden on your own profile)
                          if (!isMe && myId != null)
                            Row(
                              children: [
                                Expanded(
                                  child: _FollowButton(
                                    myId: myId,
                                    otherUserId: userId,
                                    otherUserName: displayName,
                                    otherUserPhoto: photoUrl,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              ChatThreadScreen(
                                            otherUserId: userId,
                                            otherUserName: displayName,
                                            otherUserPhoto: photoUrl,
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.message,
                                        size: 18, color: Colors.white),
                                    label: const Text('Message',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF3A3B3C),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
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
                            return GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => UserVideoFeedScreen(
                                      userId: userId,
                                      initialIndex: index,
                                    ),
                                  ),
                                );
                              },
                              child: _VideoThumbnail(
                                videoUrl: post['videoUrl'] ?? '',
                                caption: post['caption'] ?? '',
                                postId: snapshot.data!.docs[index].id,
                              ),
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

// A plain stat column (e.g. Posts) with a fixed number
class _StatColumn extends StatelessWidget {
  final String label;
  final int value;

  const _StatColumn({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Text(
            '$value',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// A stat column whose number comes live from a Firestore subcollection count
class _CountStat extends StatelessWidget {
  final String label;
  final CollectionReference collectionRef;

  const _CountStat({required this.label, required this.collectionRef});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: collectionRef.snapshots(),
      builder: (context, snapshot) {
        final int count = snapshot.hasData ? snapshot.data!.docs.length : 0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Facebook-style Follow / Following toggle button
class _FollowButton extends StatelessWidget {
  final String myId;
  final String otherUserId;
  final String otherUserName;
  final String otherUserPhoto;

  const _FollowButton({
    required this.myId,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserPhoto,
  });

  DocumentReference get _myFollowDoc => FirebaseFirestore.instance
      .collection('users')
      .doc(otherUserId)
      .collection('followers')
      .doc(myId);

  Future<void> _toggleFollow(bool isFollowing) async {
    final firestore = FirebaseFirestore.instance;
    final followersDoc = firestore
        .collection('users')
        .doc(otherUserId)
        .collection('followers')
        .doc(myId);
    final followingDoc = firestore
        .collection('users')
        .doc(myId)
        .collection('following')
        .doc(otherUserId);

    if (isFollowing) {
      final batch = firestore.batch();
      batch.delete(followersDoc);
      batch.delete(followingDoc);
      await batch.commit();
    } else {
      final batch = firestore.batch();
      batch.set(followersDoc, {'createdAt': FieldValue.serverTimestamp()});
      batch.set(followingDoc, {'createdAt': FieldValue.serverTimestamp()});
      await batch.commit();

      final myProfile = await firestore.collection('users').doc(myId).get();
      final myData = myProfile.data();
      final String myName =
          (myData?['displayName'] as String?)?.trim().isNotEmpty == true
              ? myData!['displayName']
              : 'Someone';
      final String myPhoto = (myData?['photoUrl'] as String?) ?? '';

      await firestore
          .collection('users')
          .doc(otherUserId)
          .collection('notifications')
          .add({
        'type': 'follow',
        'text': '',
        'fromId': myId,
        'fromName': myName,
        'fromPhoto': myPhoto,
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _myFollowDoc.snapshots(),
      builder: (context, snapshot) {
        final bool isFollowing = snapshot.data?.exists ?? false;

        return ElevatedButton.icon(
          onPressed: () => _toggleFollow(isFollowing),
          icon: Icon(
            isFollowing ? Icons.check : Icons.person_add_alt_1,
            size: 18,
            color: Colors.white,
          ),
          label: Text(
            isFollowing ? 'Following' : 'Follow',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: ElevatedButton.styleFrom(
            // Facebook blue when not following, grey when following
            backgroundColor:
                isFollowing ? const Color(0xFF3A3B3C) : const Color(0xFF1877F2),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      },
    );
  }
}

// A single video thumbnail tile that shows the first frame of the video
class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String caption;
  final String postId;

  const _VideoThumbnail({
    required this.videoUrl,
    required this.caption,
    required this.postId,
  });

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
              clipBehavior: Clip.hardEdge,
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
          // TikTok-style view count (bottom-left)
          Positioned(
            left: 6,
            bottom: 6,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(widget.postId)
                  .collection('views')
                  .snapshots(),
              builder: (context, snap) {
                final int views = snap.hasData ? snap.data!.docs.length : 0;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                    const SizedBox(width: 2),
                    Text(
                      _fmtCount(views),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Formats view counts like 1200 -> "1.2K"
String _fmtCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

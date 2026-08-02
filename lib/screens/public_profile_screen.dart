import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'media_utils.dart';

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
        actions: [
          if (!isMe)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: const Color(0xFF1E1E1E),
              onSelected: (value) {
                if (value == 'block') {
                  _confirmBlockUser(context, userId);
                } else if (value == 'report') {
                  _showReportUserSheet(context, userId);
                }
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(
                  value: 'report',
                  child: Text('Report user',
                      style: TextStyle(color: Colors.white)),
                ),
                PopupMenuItem(
                  value: 'block',
                  child: Text('Block user',
                      style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
        ],
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
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('reposts')
                    .where('sharedBy', isEqualTo: userId)
                    .snapshots(),
                builder: (context, repostSnapshot) {
                  final ownDocs = snapshot.data?.docs ?? [];
                  final repostDocs = repostSnapshot.data?.docs ?? [];
                  final int postCount = ownDocs.length;

                  // Combined grid: this user's own uploads + videos they
                  // shared (reposts), newest first.
                  final List<_PublicProfileGridItem> gridItems = [
                    for (int i = 0; i < ownDocs.length; i++)
                      _PublicProfileGridItem.own(ownDocs[i], i),
                    for (final d in repostDocs)
                      _PublicProfileGridItem.repost(d),
                  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                  final bool isLoading = snapshot.connectionState ==
                          ConnectionState.waiting ||
                      repostSnapshot.connectionState == ConnectionState.waiting;

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
                                    colors: [
                                      Color(0xFFFF4B6E),
                                      Color(0xFF9C4DFF)
                                    ],
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
                                          backgroundColor:
                                              const Color(0xFF3A3B3C),
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
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
                      if (isLoading)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: CircularProgressIndicator(
                                color: Colors.redAccent),
                          ),
                        )
                      else if (gridItems.isEmpty)
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
                                final item = gridItems[index];
                                return GestureDetector(
                                  onTap: () {
                                    if (item.isRepost) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => SingleVideoScreen(
                                            postId: item.postId,
                                            userId: item.originalUserId,
                                            videoUrl: item.videoUrl,
                                            caption: item.caption,
                                            userEmail: item.userEmail,
                                            videoType: item.videoType,
                                            repostNote: item.note,
                                            repostByName: item.sharedByName,
                                            repostByUserId: item.sharedByUserId,
                                            repostByPhoto: item.sharedByPhoto,
                                          ),
                                        ),
                                      );
                                    } else {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => UserVideoFeedScreen(
                                            userId: userId,
                                            initialIndex: item.ownIndex,
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  child: _VideoThumbnail(
                                    videoUrl: item.videoUrl,
                                    caption: item.caption,
                                    postId: item.postId,
                                    isRepost: item.isRepost,
                                  ),
                                );
                              },
                              childCount: gridItems.length,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// One tile in the public profile grid: either this user's own upload, or
// a video they shared (repost). originalUserId/postId always point at the
// actual video/post so likes, comments, and views stay attributed to the
// original.
class _PublicProfileGridItem {
  final String postId;
  final String videoUrl;
  final String caption;
  final String videoType;
  final String userEmail;
  final String originalUserId;
  final bool isRepost;
  final DateTime createdAt;
  final int ownIndex;
  final String? note;
  final String? sharedByName;
  final String? sharedByUserId;
  final String? sharedByPhoto;

  _PublicProfileGridItem.own(QueryDocumentSnapshot doc, int index)
      : postId = doc.id,
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        userEmail = (doc.data() as Map<String, dynamic>)['userEmail'] ?? '',
        originalUserId = (doc.data() as Map<String, dynamic>)['userId'] ?? '',
        isRepost = false,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        ownIndex = index,
        note = null,
        sharedByName = null,
        sharedByUserId = null,
        sharedByPhoto = null;

  _PublicProfileGridItem.repost(QueryDocumentSnapshot doc)
      : postId = (doc.data() as Map<String, dynamic>)['originalPostId'] ?? '',
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        userEmail = (doc.data() as Map<String, dynamic>)['userEmail'] ?? '',
        originalUserId =
            (doc.data() as Map<String, dynamic>)['originalUserId'] ?? '',
        isRepost = true,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        ownIndex = -1,
        note = (doc.data() as Map<String, dynamic>)['note'] as String?,
        sharedByName =
            (doc.data() as Map<String, dynamic>)['sharedByName'] as String?,
        sharedByUserId =
            (doc.data() as Map<String, dynamic>)['sharedBy'] as String?,
        sharedByPhoto =
            (doc.data() as Map<String, dynamic>)['sharedByPhoto'] as String?;
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

// Confirms and then writes a block record under the current user's
// 'blocked' subcollection.
Future<void> _confirmBlockUser(
    BuildContext context, String userIdToBlock) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title:
          const Text('Block this user?', style: TextStyle(color: Colors.white)),
      content: const Text(
        "You won't see their posts or comments anymore, and they won't be "
        'able to message you.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Block', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final String? myId = FirebaseAuth.instance.currentUser?.uid;
  if (myId == null) return;

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(myId)
        .collection('blocked')
        .doc(userIdToBlock)
        .set({'createdAt': FieldValue.serverTimestamp()});
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('User blocked.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not block user. Try again.')));
    }
  }
}

// Shows a reason picker and writes a 'reports' document for this user.
void _showReportUserSheet(BuildContext context, String userIdToReport) {
  const List<String> reasons = [
    'Nudity or sexual content',
    'Hate speech or harassment',
    'Violence or dangerous content',
    'Spam or scam',
    'Something else',
  ];

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Report this user',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            ...reasons.map((reason) => ListTile(
                  title: Text(reason,
                      style: const TextStyle(color: Colors.white70)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final String? myId = FirebaseAuth.instance.currentUser?.uid;
                    if (myId == null) return;
                    try {
                      await FirebaseFirestore.instance
                          .collection('reports')
                          .add({
                        'targetType': 'user',
                        'targetId': userIdToReport,
                        'parentPostId': null,
                        'targetOwnerId': userIdToReport,
                        'reporterId': myId,
                        'reason': reason,
                        'status': 'pending',
                        'createdAt': FieldValue.serverTimestamp(),
                      });
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Report submitted. Thank you.')),
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content:
                                  Text('Could not submit report. Try again.')),
                        );
                      }
                    }
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
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
  final bool isRepost;

  const _VideoThumbnail({
    required this.videoUrl,
    required this.caption,
    required this.postId,
    this.isRepost = false,
  });

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  @override
  Widget build(BuildContext context) {
    final String thumbUrl = cloudinaryThumbUrl(widget.videoUrl);

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
              errorWidget: (context, url, error) => const Center(
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white30, size: 30),
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
          // Small badge marking this as a shared video (repost)
          if (widget.isRepost)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.repeat_rounded,
                  color: Colors.white,
                  size: 14,
                ),
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

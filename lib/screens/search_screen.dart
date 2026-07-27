import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'home_screen.dart';
import 'media_utils.dart';
import 'public_profile_screen.dart';

// Search / Discover screen: shows a browsable grid of recent videos by
// default, and filters to matching accounts + videos once the user types.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.search, color: Colors.grey[500], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search videos or accounts',
                    hintStyle: TextStyle(color: Colors.grey[500]),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
              if (_query.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                  child: Icon(Icons.close, color: Colors.grey[500], size: 18),
                ),
            ],
          ),
        ),
      ),
      body: _query.isEmpty
          ? const _DiscoverGrid()
          : _SearchResults(query: _query),
    );
  }
}

// Default view before typing anything: a grid of recent videos to browse
class _DiscoverGrid extends StatelessWidget {
  const _DiscoverGrid();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(60)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.redAccent),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Text('No videos yet', style: TextStyle(color: Colors.grey)),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
            childAspectRatio: 0.7,
          ),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final post = doc.data() as Map<String, dynamic>;
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SingleVideoScreen(
                    postId: doc.id,
                    userId: post['userId'] ?? '',
                    videoUrl: post['videoUrl'] ?? '',
                    caption: post['caption'] ?? '',
                    userEmail: post['userEmail'] ?? 'Unknown user',
                    videoType: (post['videoType'] as String?) ?? 'short',
                  ),
                ),
              ),
              child: _SearchVideoThumbnail(
                videoUrl: post['videoUrl'] ?? '',
                postId: doc.id,
              ),
            );
          },
        );
      },
    );
  }
}

// Filtered results once the user has typed a search query. Firestore has
// no built-in text search, so this pulls a capped batch of users/posts and
// filters by "contains" on the client - fine at this app's scale.
class _SearchResults extends StatelessWidget {
  final String query;

  const _SearchResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instance.collection('users').limit(200).snapshots(),
      builder: (context, userSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('posts')
              .orderBy('createdAt', descending: true)
              .limit(300)
              .snapshots(),
          builder: (context, postSnap) {
            final bool isLoading =
                userSnap.connectionState == ConnectionState.waiting ||
                    postSnap.connectionState == ConnectionState.waiting;
            if (isLoading) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.redAccent),
              );
            }

            final matchedUsers = (userSnap.data?.docs ?? []).where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final String name =
                  (data['displayName'] as String? ?? '').toLowerCase();
              final String email =
                  (data['email'] as String? ?? '').toLowerCase();
              return name.contains(query) || email.contains(query);
            }).toList();

            final matchedPosts = (postSnap.data?.docs ?? []).where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final String caption =
                  (data['caption'] as String? ?? '').toLowerCase();
              return caption.contains(query);
            }).toList();

            if (matchedUsers.isEmpty && matchedPosts.isEmpty) {
              return const Center(
                child: Text('No results found',
                    style: TextStyle(color: Colors.grey)),
              );
            }

            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (matchedUsers.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 14, 14, 6),
                    child: Text(
                      'Accounts',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...matchedUsers.take(15).map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final String name =
                        (data['displayName'] as String?)?.trim().isNotEmpty ==
                                true
                            ? data['displayName']
                            : (data['email'] as String? ?? 'User');
                    final String photo = (data['photoUrl'] as String?) ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.grey[850],
                        backgroundImage:
                            photo.isNotEmpty ? NetworkImage(photo) : null,
                        child: photo.isEmpty
                            ? Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white),
                              )
                            : null,
                      ),
                      title: Text(name,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PublicProfileScreen(userId: doc.id),
                        ),
                      ),
                    );
                  }),
                ],
                if (matchedPosts.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 14, 14, 6),
                    child: Text(
                      'Videos',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(2),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                      childAspectRatio: 0.7,
                    ),
                    itemCount: matchedPosts.length,
                    itemBuilder: (context, index) {
                      final doc = matchedPosts[index];
                      final post = doc.data() as Map<String, dynamic>;
                      return GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SingleVideoScreen(
                              postId: doc.id,
                              userId: post['userId'] ?? '',
                              videoUrl: post['videoUrl'] ?? '',
                              caption: post['caption'] ?? '',
                              userEmail: post['userEmail'] ?? 'Unknown user',
                              videoType:
                                  (post['videoType'] as String?) ?? 'short',
                            ),
                          ),
                        ),
                        child: _SearchVideoThumbnail(
                          videoUrl: post['videoUrl'] ?? '',
                          postId: doc.id,
                        ),
                      );
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

// Thumbnail tile showing the first frame of a video + its view count
class _SearchVideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String postId;

  const _SearchVideoThumbnail({
    required this.videoUrl,
    required this.postId,
  });

  @override
  State<_SearchVideoThumbnail> createState() => _SearchVideoThumbnailState();
}

class _SearchVideoThumbnailState extends State<_SearchVideoThumbnail> {
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
                      _fmtViews(views),
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
String _fmtViews(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

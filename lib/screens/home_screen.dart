import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'notifications_screen.dart';
import 'public_profile_screen.dart';
import 'story_screen.dart';
import 'search_screen.dart';
import 'live_screen.dart';
import 'sound_screen.dart';

// Watches full-screen route pushes so a playing video can pause itself
// when the user navigates somewhere else. Registered in main.dart.
// Typed to PageRoute (not ModalRoute) so bottom sheets like the comments
// sheet don't pause playback - only real screen changes do.
final RouteObserver<PageRoute<dynamic>> flyRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

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

  // Created ONCE here, not inside build(). Building a new
  // .snapshots() stream on every rebuild makes StreamBuilder drop its
  // subscription and start over in the "waiting" state, which tore the
  // video player down and flashed a black screen every time something
  // rebuilt this widget (e.g. tapping like).
  late final Stream<QuerySnapshot> _postsStream;
  late final Stream<QuerySnapshot> _repostsStream;

  // "For You" (everything) vs "Following" (only people you follow)
  bool _followingOnly = false;
  Set<String> _followingIds = {};
  StreamSubscription<QuerySnapshot>? _followingSub;

  @override
  void initState() {
    super.initState();
    // Stop the phone from dimming/locking while videos are playing.
    WakelockPlus.enable();
    _postsStream = FirebaseFirestore.instance
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots();
    _repostsStream = FirebaseFirestore.instance
        .collection('reposts')
        .orderBy('createdAt', descending: true)
        .snapshots();

    // Keep the set of followed accounts up to date so the Following
    // tab reacts immediately when you follow or unfollow someone.
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      _followingSub = FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('following')
          .snapshots()
          .listen((snap) {
        if (mounted) {
          setState(() {
            _followingIds = snap.docs.map((d) => d.id).toSet();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _followingSub?.cancel();
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

  // One of the two feed tabs at the top of the home screen
  Widget _feedTab(String label, bool followingTab) {
    final bool isActive = _followingOnly == followingTab;
    return GestureDetector(
      onTap: () {
        if (_followingOnly == followingTab) return;
        setState(() => _followingOnly = followingTab);
        // Start the newly selected feed from the top.
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white54,
              fontSize: 17,
              fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
              shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
            ),
          ),
          const SizedBox(height: 3),
          Container(
            height: 2,
            width: isActive ? 22 : 0,
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StreamBuilder<QuerySnapshot>(
        stream: _postsStream,
        builder: (context, snapshot) {
          return StreamBuilder<QuerySnapshot>(
            stream: _repostsStream,
            builder: (context, repostSnapshot) {
              // Only show the loader when we genuinely have nothing yet.
              // Checking connectionState alone would also fire on a
              // transient re-subscribe and destroy the playing video.
              if (!snapshot.hasData && !repostSnapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.redAccent),
                );
              }

              final ownDocs = snapshot.data?.docs ?? [];
              final repostDocs = repostSnapshot.data?.docs ?? [];

              // Combine original posts with shared videos (reposts) into
              // one newest-first feed, so a video someone shares shows up
              // at home for their followers/friends to see too.
              final List<_FeedItem> feedItems = [
                ...ownDocs.map((d) => _FeedItem.post(d)),
                ...repostDocs.map((d) => _FeedItem.repost(d)),
              ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

              // On the Following tab, keep only videos from accounts you
              // follow - either the original poster, or whoever shared it.
              final List<_FeedItem> visibleItems = _followingOnly
                  ? feedItems.where((item) {
                      if (item.isRepost) {
                        return _followingIds.contains(item.sharedByUserId);
                      }
                      return _followingIds.contains(item.originalUserId);
                    }).toList()
                  : feedItems;

              if (feedItems.isEmpty) {
                return const Center(
                  child: Text(
                    'No posts yet. Be the first to upload!',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              return Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _feedTab('Following', true),
                                    const SizedBox(width: 10),
                                    Container(
                                      width: 1,
                                      height: 14,
                                      color: Colors.white24,
                                    ),
                                    const SizedBox(width: 10),
                                    _feedTab('For You', false),
                                  ],
                                ),
                              ),
                              Positioned(
                                left: 12,
                                top: 0,
                                child: GestureDetector(
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const SearchScreen(),
                                    ),
                                  ),
                                  child: const Icon(Icons.search,
                                      color: Colors.white, size: 26),
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
                        const StoriesBar(),
                        const LiveBadgeBar(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SafeArea(
                      top: false,
                      child: visibleItems.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: Text(
                                  'Nothing here yet.\n'
                                  'Follow some accounts and their videos '
                                  'will show up here.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            )
                          : PageView.builder(
                              controller: _pageController,
                              scrollDirection: Axis.vertical,
                              itemCount: visibleItems.length,
                              itemBuilder: (context, index) {
                                final item = visibleItems[index];

                                // key includes the doc id (post id for own
                                // posts, repost id for reposts) so Flutter
                                // doesn't reuse a _VideoPostItem's State for
                                // a different feed entry, even when the same
                                // video appears twice (once as someone's
                                // original post, once as a repost).
                                return _VideoPostItem(
                                  key: ValueKey(item.feedKey),
                                  postId: item.postId,
                                  userId: item.originalUserId,
                                  videoUrl: item.videoUrl,
                                  caption: item.caption,
                                  userEmail: item.userEmail,
                                  reactions: item.reactions,
                                  videoType: item.videoType,
                                  onVideoEnd: () =>
                                      _goToNextVideo(visibleItems.length),
                                  repostNote: item.isRepost ? item.note : null,
                                  repostByName:
                                      item.isRepost ? item.sharedByName : null,
                                  repostByUserId: item.isRepost
                                      ? item.sharedByUserId
                                      : null,
                                  repostByPhoto:
                                      item.isRepost ? item.sharedByPhoto : null,
                                );
                              },
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

// Facebook Reels-style screen: same vertical full-screen video feed as
// Home, but filtered to short videos only (videoType == 'short') - no
// landscape videos, no stories/search/live bar clutter.
class ShortsScreen extends StatefulWidget {
  const ShortsScreen({super.key});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen> {
  final PageController _pageController = PageController();

  // Same reasoning as _HomeScreenState: build these once, not on every
  // rebuild, or StreamBuilder resubscribes and kills the playing video.
  late final Stream<QuerySnapshot> _shortPostsStream;
  late final Stream<QuerySnapshot> _shortRepostsStream;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _shortPostsStream = FirebaseFirestore.instance
        .collection('posts')
        .where('videoType', isEqualTo: 'short')
        .orderBy('createdAt', descending: true)
        .snapshots();
    _shortRepostsStream = FirebaseFirestore.instance
        .collection('reposts')
        .where('videoType', isEqualTo: 'short')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
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
        stream: _shortPostsStream,
        builder: (context, snapshot) {
          return StreamBuilder<QuerySnapshot>(
            stream: _shortRepostsStream,
            builder: (context, repostSnapshot) {
              // Show the actual error (e.g. "missing composite index")
              // instead of silently falling through to "no reels yet",
              // which was hiding the real problem.
              if (snapshot.hasError || repostSnapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Could not load reels:\n'
                      '${snapshot.error ?? repostSnapshot.error}',
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              // Only show the loader when we genuinely have nothing yet.
              if (!snapshot.hasData && !repostSnapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.redAccent),
                );
              }

              final ownDocs = snapshot.data?.docs ?? [];
              final repostDocs = repostSnapshot.data?.docs ?? [];

              final List<_FeedItem> feedItems = [
                ...ownDocs.map((d) => _FeedItem.post(d)),
                ...repostDocs.map((d) => _FeedItem.repost(d)),
              ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

              if (feedItems.isEmpty) {
                return const Center(
                  child: Text(
                    'No reels yet. Upload a short video!',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              return Stack(
                children: [
                  SafeArea(
                    top: false,
                    child: PageView.builder(
                      controller: _pageController,
                      scrollDirection: Axis.vertical,
                      itemCount: feedItems.length,
                      itemBuilder: (context, index) {
                        final item = feedItems[index];
                        return _VideoPostItem(
                          key: ValueKey(item.feedKey),
                          postId: item.postId,
                          userId: item.originalUserId,
                          videoUrl: item.videoUrl,
                          caption: item.caption,
                          userEmail: item.userEmail,
                          reactions: item.reactions,
                          videoType: item.videoType,
                          onVideoEnd: () => _goToNextVideo(feedItems.length),
                          repostNote: item.isRepost ? item.note : null,
                          repostByName:
                              item.isRepost ? item.sharedByName : null,
                          repostByUserId:
                              item.isRepost ? item.sharedByUserId : null,
                          repostByPhoto:
                              item.isRepost ? item.sharedByPhoto : null,
                        );
                      },
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Center(
                        child: Text(
                          'Reels',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: Colors.black.withOpacity(0.6),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
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

// One entry in the home feed: either an original post, or a video someone
// shared (repost). postId/originalUserId always point at the actual
// video/post so likes, comments, and views stay attributed to the
// original - only the note/sharedByName differ for a repost.
class _FeedItem {
  final String feedKey;
  final String postId;
  final String videoUrl;
  final String caption;
  final String userEmail;
  final String videoType;
  final String originalUserId;
  final Map<String, dynamic> reactions;
  final bool isRepost;
  final DateTime createdAt;
  final String? note;
  final String? sharedByName;
  final String? sharedByUserId;
  final String? sharedByPhoto;

  _FeedItem.post(QueryDocumentSnapshot doc)
      : feedKey = 'post_${doc.id}',
        postId = doc.id,
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        userEmail =
            (doc.data() as Map<String, dynamic>)['userEmail'] ?? 'Unknown user',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        originalUserId = (doc.data() as Map<String, dynamic>)['userId'] ?? '',
        reactions = ((doc.data() as Map<String, dynamic>)['reactions']
                as Map<String, dynamic>?) ??
            {},
        isRepost = false,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        note = null,
        sharedByName = null,
        sharedByUserId = null,
        sharedByPhoto = null;

  _FeedItem.repost(QueryDocumentSnapshot doc)
      : feedKey = 'repost_${doc.id}',
        postId = (doc.data() as Map<String, dynamic>)['originalPostId'] ?? '',
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        userEmail = (doc.data() as Map<String, dynamic>)['userEmail'] ?? '',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        originalUserId =
            (doc.data() as Map<String, dynamic>)['originalUserId'] ?? '',
        reactions = const {},
        isRepost = true,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        note = (doc.data() as Map<String, dynamic>)['note'] as String?,
        sharedByName =
            (doc.data() as Map<String, dynamic>)['sharedByName'] as String?,
        sharedByUserId =
            (doc.data() as Map<String, dynamic>)['sharedBy'] as String?,
        sharedByPhoto =
            (doc.data() as Map<String, dynamic>)['sharedByPhoto'] as String?;
}

// Full-screen, swipeable viewer of a single user's videos (opened from a
// profile grid). Reuses _VideoPostItem so like/comment/share/save all work.
class UserVideoFeedScreen extends StatefulWidget {
  final String userId;
  final int initialIndex;

  const UserVideoFeedScreen({
    super.key,
    required this.userId,
    this.initialIndex = 0,
  });

  @override
  State<UserVideoFeedScreen> createState() => _UserVideoFeedScreenState();
}

class _UserVideoFeedScreenState extends State<UserVideoFeedScreen> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);

  // Built once - see _HomeScreenState for why.
  late final Stream<QuerySnapshot> _userPostsStream;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _userPostsStream = FirebaseFirestore.instance
        .collection('posts')
        .where('userId', isEqualTo: widget.userId)
        .snapshots();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
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
        // Same query as the profile grid (no orderBy) so indexes line up
        stream: _userPostsStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            );
          }

          final posts = snapshot.data?.docs ?? [];
          if (posts.isEmpty) {
            return const Center(
              child: Text('No videos', style: TextStyle(color: Colors.grey)),
            );
          }

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
                    key: ValueKey(postDoc.id),
                    postId: postDoc.id,
                    userId: post['userId'] ?? '',
                    videoUrl: post['videoUrl'] ?? '',
                    caption: post['caption'] ?? '',
                    userEmail: post['userEmail'] ?? 'Unknown user',
                    reactions: reactions,
                    videoType: (post['videoType'] as String?) ?? 'short',
                    onVideoEnd: () => _goToNextVideo(posts.length),
                  );
                },
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_back, color: Colors.white),
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

// Plays a single video full-screen. Used for reposts on a profile grid,
// where we want to open just the one shared video rather than paging
// through a whole user's feed.
class SingleVideoScreen extends StatefulWidget {
  final String postId;
  final String userId;
  final String videoUrl;
  final String caption;
  final String userEmail;
  final String videoType;
  final String? repostNote;
  final String? repostByName;
  final String? repostByUserId;
  final String? repostByPhoto;

  const SingleVideoScreen({
    super.key,
    required this.postId,
    required this.userId,
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
    this.videoType = 'short',
    this.repostNote,
    this.repostByName,
    this.repostByUserId,
    this.repostByPhoto,
  });

  @override
  State<SingleVideoScreen> createState() => _SingleVideoScreenState();
}

class _SingleVideoScreenState extends State<SingleVideoScreen> {
  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            top: false,
            child: _VideoPostItem(
              key: ValueKey(widget.postId),
              postId: widget.postId,
              userId: widget.userId,
              videoUrl: widget.videoUrl,
              caption: widget.caption,
              userEmail: widget.userEmail,
              reactions: const {},
              videoType: widget.videoType,
              repostNote: widget.repostNote,
              repostByName: widget.repostByName,
              repostByUserId: widget.repostByUserId,
              repostByPhoto: widget.repostByPhoto,
              // Nothing to auto-advance to - this is a single video screen.
              onVideoEnd: () {},
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_back, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
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
  final String videoType;
  final VoidCallback onVideoEnd;
  // When this video is being shown as a repost, these carry the sharer's
  // own note and name so it can be displayed on top of the video.
  final String? repostNote;
  final String? repostByName;
  final String? repostByUserId;
  final String? repostByPhoto;

  const _VideoPostItem({
    super.key,
    required this.postId,
    required this.userId,
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
    required this.reactions,
    required this.videoType,
    required this.onVideoEnd,
    this.repostNote,
    this.repostByName,
    this.repostByUserId,
    this.repostByPhoto,
  });

  @override
  State<_VideoPostItem> createState() => _VideoPostItemState();
}

class _VideoPostItemState extends State<_VideoPostItem>
    with RouteAware, WidgetsBindingObserver {
  // How many times a video replays on its own before we auto-advance to
  // the next one. The user can still swipe away manually at any time.
  static const int _maxLoopsBeforeAutoSkip = 3;

  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _endTriggered = false;
  int _loopCount = 0;
  bool _showReactionPicker = false;

  // Controls visibility is a notifier so toggling it rebuilds ONLY the overlay,
  // not the whole video item (avoids flicker on every tap).
  final ValueNotifier<bool> _controlsVisible = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _muted = ValueNotifier<bool>(false);

  final List<_FlyingEmoji> _flyingEmojis = [];

  // Built once, for the same reason as the feed streams: creating it
  // inside build() would resubscribe on every rebuild.
  Stream<DocumentSnapshot>? _postDocStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.postId.isNotEmpty) {
      _postDocStream = FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .snapshots();
    }
    _initializeVideo();
    _recordView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      flyRouteObserver.subscribe(this, route);
    }
  }

  // Remembers whether playback was running, so returning to the screen
  // resumes only videos that were actually playing.
  bool _wasPlayingBeforeLeaving = false;

  void _pauseForNavigation() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _wasPlayingBeforeLeaving = c.value.isPlaying;
    if (c.value.isPlaying) c.pause();
  }

  void _resumeAfterNavigation() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_wasPlayingBeforeLeaving) c.play();
  }

  // Another full screen was pushed on top of this one - stop the sound.
  @override
  void didPushNext() => _pauseForNavigation();

  // That screen was closed and this one is visible again.
  @override
  void didPopNext() => _resumeAfterNavigation();

  // App sent to the background / a call came in, etc.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeAfterNavigation();
    } else {
      _pauseForNavigation();
    }
  }

  // Records that the current user viewed this post (counted once per user).
  Future<void> _recordView() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || widget.postId.isEmpty) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);
    final viewRef = postRef.collection('views').doc(user.uid);
    try {
      final snap = await viewRef.get();
      if (!snap.exists) {
        await viewRef.set({'createdAt': FieldValue.serverTimestamp()});
      }
    } catch (_) {
      // Ignore view-tracking errors so playback is never affected.
    }
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

    if (!_endTriggered &&
        duration.inMilliseconds > 0 &&
        position.inMilliseconds >= duration.inMilliseconds - 200) {
      _endTriggered = true;
      _loopCount++;

      if (_loopCount >= _maxLoopsBeforeAutoSkip) {
        // Watched the same video 3 times in a row without the user
        // swiping away themselves — move on to the next one.
        widget.onVideoEnd();
      } else {
        // Replay it for another loop.
        controller.seekTo(Duration.zero);
        controller.play();
        // Give the seek a moment to land before watching for the end
        // again, so the same loop isn't counted twice.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _endTriggered = false;
        });
      }
    }
  }

  void _handleScreenTap() {
    if (_showReactionPicker) {
      setState(() => _showReactionPicker = false);
      return;
    }
    _togglePlayPause();
  }

  // Skips forward/backward by [seconds]; keeps the controls visible
  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    Duration target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
    _controlsVisible.value = true;
  }

  // Playing -> pause and show the 3 controls; Paused -> play and hide them
  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _controlsVisible.value = true;
    } else {
      c.play();
      _controlsVisible.value = false;
    }
  }

  void _toggleMute() {
    _muted.value = !_muted.value;
    _controller?.setVolume(_muted.value ? 0.0 : 1.0);
  }

  // Formats a duration as m:ss (e.g. 0:08, 1:23)
  String _fmtDuration(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // A single circular media-control button
  Widget _circleControl({
    required IconData icon,
    required double diameter,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.45),
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
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

  // Toggles a reaction. [currentReactions] must be the FRESHEST reactions map
  // available (from the live post-document stream, not a value cached from
  // when this widget was first built) so the like/unlike decision below is
  // always correct, even if several taps happen quickly.
  Future<void> _setReaction(
      String type, Map<String, dynamic> currentReactions) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);
    final String? currentReaction = currentReactions[user.uid] as String?;

    setState(() => _showReactionPicker = false);

    if (currentReaction == type) {
      await postRef.update({'reactions.${user.uid}': FieldValue.delete()});
    } else {
      await postRef.update({'reactions.${user.uid}': type});
      _spawnFlyingEmojis(kReactions[type]!);
      _createNotification(type: 'reaction', text: kReactions[type]!);
    }
  }

  void _quickToggleLike(Map<String, dynamic> currentReactions) {
    _setReaction('like', currentReactions);
  }

  // Shows a small dialog so the sharer can add their own words on top of
  // the video before sharing. Returns null if they cancelled, or the note
  // text (possibly empty) if they tapped Share.
  Future<String?> _showShareNoteDialog() async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Share video', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 150,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Add your own words... (optional)',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.redAccent),
            ),
            counterStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child:
                const Text('Share', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _shareVideo() async {
    final String? note = await _showShareNoteDialog();
    if (note == null) return; // User cancelled the dialog

    // Record the share so it can be counted (one per user, idempotent)
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && widget.postId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('posts')
            .doc(widget.postId)
            .collection('shares')
            .doc(user.uid)
            .set({'createdAt': FieldValue.serverTimestamp()});
      } catch (_) {
        // Ignore share-tracking errors
      }

      // Look up the sharer's own display name + photo so their account is
      // clearly visible ("<name> shared this") wherever the repost appears.
      String sharedByName = widget.userEmail;
      String sharedByPhoto = '';
      try {
        final myProfile = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final data = myProfile.data();
        sharedByName =
            (data?['displayName'] as String?)?.trim().isNotEmpty == true
                ? data!['displayName']
                : (user.email?.split('@').first ?? 'Someone');
        sharedByPhoto = (data?['photoUrl'] as String?) ?? '';
      } catch (_) {
        // Keep the fallback name above
      }

      // Also save this as a "repost" on the sharer's own profile, so
      // anyone visiting their profile can see the video they shared -
      // along with the note they wrote on top of it.
      // Doc id is uid_postId so re-sharing the same video is idempotent
      // (just refreshes the timestamp) instead of creating duplicates.
      try {
        await FirebaseFirestore.instance
            .collection('reposts')
            .doc('${user.uid}_${widget.postId}')
            .set({
          'sharedBy': user.uid,
          'sharedByName': sharedByName,
          'sharedByPhoto': sharedByPhoto,
          'originalPostId': widget.postId,
          'originalUserId': widget.userId,
          'videoUrl': widget.videoUrl,
          'caption': widget.caption,
          'videoType': widget.videoType,
          'userEmail': widget.userEmail,
          'note': note,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {
        // Ignore repost-tracking errors
      }
    }

    final String shareText = note.isNotEmpty
        ? '$note\n\nWatch on Fly: ${widget.videoUrl}'
        : widget.caption.isNotEmpty
            ? '${widget.caption}\n\nWatch on Fly: ${widget.videoUrl}'
            : 'Watch this video on Fly: ${widget.videoUrl}';
    await Share.share(shareText);
  }

  // Live count of a post subcollection (comments / shares / saves)
  Stream<QuerySnapshot> _postSubStream(String sub) {
    return FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection(sub)
        .snapshots();
  }

  // Saves or unsaves this post (stored per-post so the total can be counted)
  Future<void> _toggleSave(bool isSaved) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || widget.postId.isEmpty) return;

    final ref = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('saves')
        .doc(user.uid);
    try {
      if (isSaved) {
        await ref.delete();
      } else {
        await ref.set({
          'uid': user.uid,
          'ownerId': widget.userId,
          'videoUrl': widget.videoUrl,
          'caption': widget.caption,
          'videoType': widget.videoType,
          'savedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (_) {
      // Ignore save errors so the UI is never blocked.
    }
  }

  // Formats counts like 17300 -> "17.3K", 2400000 -> "2.4M"
  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  // Small count text shown under each action icon
  Widget _countLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
        ),
      ),
    );
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
    flyRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onVideoProgress);
    _controller?.dispose();
    _controlsVisible.dispose();
    _muted.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // The whole post item listens directly to its own Firestore document.
    // This is what keeps the like count and my-reaction state ALWAYS in
    // sync with the database, instead of depending on the parent post-list
    // snapshot (which could be a tick behind and made counts look wrong or
    // jump around, and made double-tapping like feel unreliable).
    return StreamBuilder<DocumentSnapshot>(
      stream: _postDocStream,
      builder: (context, postSnap) {
        final Map<String, dynamic>? livePostData =
            (postSnap.data?.data()) as Map<String, dynamic>?;
        // Fall back to the reactions passed in from the list while the
        // document stream is still loading its first snapshot.
        final Map<String, dynamic> liveReactions =
            (livePostData?['reactions'] as Map<String, dynamic>?) ??
                widget.reactions;
        final String? myReaction =
            user != null ? liveReactions[user.uid] as String? : null;

        // Which sound this video uses, so it can be credited and opened.
        final String? soundId = livePostData?['soundId'] as String?;
        final String soundLabel = [
          (livePostData?['soundTitle'] as String?) ?? 'Original sound',
          (livePostData?['soundOwnerName'] as String?) ?? '',
        ].where((s) => s.isNotEmpty).join(' - ');

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleScreenTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_isInitialized && _controller != null) ...[
                // Backdrop: the same video, zoomed to fill and heavily
                // blurred, so the empty letterbox/pillarbox area picks up
                // the video's own colours instead of showing flat black.
                ClipRect(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _controller!.value.size.width,
                        height: _controller!.value.size.height,
                        child: VideoPlayer(_controller!),
                      ),
                    ),
                  ),
                ),
                // Darken the backdrop a little so the real video and the
                // overlaid text/buttons stay easy to read.
                Container(color: Colors.black.withOpacity(0.4)),
                // Show the video at its real aspect ratio, centered -
                // never cropped, so it always looks like what was
                // originally uploaded.
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              ] else
                const Center(
                  child: CircularProgressIndicator(color: Colors.redAccent),
                ),

              // Tap-to-reveal media controls: rewind 10s / play-pause / forward 10s.
              // No full-screen dim (each button has its own dark circle) so toggling
              // the controls never flickers the like button / profile behind them.
              ValueListenableBuilder<bool>(
                valueListenable: _controlsVisible,
                builder: (context, visible, _) {
                  final c = _controller;
                  if (!visible || !_isInitialized || c == null) {
                    return const SizedBox.shrink();
                  }
                  final double bottomInset =
                      MediaQuery.of(context).padding.bottom;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _circleControl(
                              icon: Icons.replay_10,
                              diameter: 58,
                              iconSize: 30,
                              onTap: () => _seekBy(-10),
                            ),
                            _circleControl(
                              icon: c.value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              diameter: 74,
                              iconSize: 44,
                              onTap: _togglePlayPause,
                            ),
                            _circleControl(
                              icon: Icons.forward_10,
                              diameter: 58,
                              iconSize: 30,
                              onTap: () => _seekBy(10),
                            ),
                          ],
                        ),
                      ),
                      // Bottom control bar: time / duration, scrub slider, mute
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 4 + bottomInset,
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: c,
                          builder: (context, value, __) {
                            final Duration pos = value.position;
                            final Duration dur = value.duration;
                            final double maxMs = dur.inMilliseconds <= 0
                                ? 1.0
                                : dur.inMilliseconds.toDouble();
                            double curMs = pos.inMilliseconds.toDouble();
                            if (curMs < 0) curMs = 0;
                            if (curMs > maxMs) curMs = maxMs;

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    children: [
                                      Text(
                                        _fmtDuration(pos),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 6)
                                          ],
                                        ),
                                      ),
                                      Text(
                                        ' / ${_fmtDuration(dur)}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 6)
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: _muted,
                                        builder: (context, muted, ___) {
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: _toggleMute,
                                            child: Padding(
                                              padding: const EdgeInsets.all(4),
                                              child: Icon(
                                                muted
                                                    ? Icons.volume_off_rounded
                                                    : Icons.volume_up_rounded,
                                                color: Colors.white,
                                                size: 24,
                                                shadows: const [
                                                  Shadow(
                                                      color: Colors.black,
                                                      blurRadius: 6)
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 3,
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                    overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 14),
                                    thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 7),
                                  ),
                                  child: Slider(
                                    value: curMs,
                                    min: 0,
                                    max: maxMs,
                                    onChanged: (v) {
                                      c.seekTo(
                                          Duration(milliseconds: v.toInt()));
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),

              Positioned(
                left: 16,
                bottom: 100,
                right: 90,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // When this video is a repost, show who shared it
                    // right above the original owner's own info/caption.
                    if (widget.repostByName != null &&
                        widget.repostByName!.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          if (widget.repostByUserId == null ||
                              widget.repostByUserId!.isEmpty) {
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PublicProfileScreen(
                                userId: widget.repostByUserId!,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.grey[850],
                                backgroundImage:
                                    (widget.repostByPhoto != null &&
                                            widget.repostByPhoto!.isNotEmpty)
                                        ? NetworkImage(widget.repostByPhoto!)
                                        : null,
                                child: (widget.repostByPhoto == null ||
                                        widget.repostByPhoto!.isEmpty)
                                    ? Text(
                                        widget.repostByName!.isNotEmpty
                                            ? widget.repostByName![0]
                                                .toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.repeat_rounded,
                                            color: Colors.white70, size: 13),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            '${widget.repostByName} shared this',
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (widget.repostNote != null &&
                                        widget.repostNote!.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        widget.repostNote!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    _OwnerInfo(
                      userId: widget.userId,
                      fallbackEmail: widget.userEmail,
                      caption: widget.caption,
                      postId: widget.postId,
                      soundId: soundId,
                      soundLabel: soundLabel,
                    ),
                  ],
                ),
              ),

              ..._flyingEmojis.map((e) {
                return Positioned(
                  right: 30,
                  bottom: 140,
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
                  bottom: 180,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: kReactions.entries.map((entry) {
                            final int i =
                                kReactions.keys.toList().indexOf(entry.key);
                            return _AnimatedEmoji(
                              emoji: entry.value,
                              delayMs: i * 90,
                              onTap: () =>
                                  _setReaction(entry.key, liveReactions),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),

              Positioned(
                right: 12,
                bottom: 120,
                child: Column(
                  children: [
                    // Like (long-press for reactions)
                    GestureDetector(
                      onTap: () => _quickToggleLike(liveReactions),
                      onLongPress: () =>
                          setState(() => _showReactionPicker = true),
                      child: Column(
                        children: [
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: myReaction == 'like'
                                  ? const _PopInLikeBadge(
                                      key: ValueKey('like'),
                                      diameter: 40,
                                    )
                                  : myReaction != null
                                      ? _PopInEmoji(
                                          key: ValueKey(myReaction),
                                          emoji: kReactions[myReaction]!,
                                        )
                                      : const Icon(
                                          Icons.favorite,
                                          color: Colors.white,
                                          size: 34,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 8)
                                          ],
                                        ),
                            ),
                          ),
                          _countLabel(_formatCount(liveReactions.length)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Comment
                    StreamBuilder<QuerySnapshot>(
                      stream: _postSubStream('comments'),
                      builder: (context, snap) {
                        final int count =
                            snap.hasData ? snap.data!.docs.length : 0;
                        return GestureDetector(
                          onTap: _openComments,
                          child: Column(
                            children: [
                              const _CommentBubbleIcon(size: 28),
                              _countLabel(_formatCount(count)),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    // Share
                    StreamBuilder<QuerySnapshot>(
                      stream: _postSubStream('shares'),
                      builder: (context, snap) {
                        final int count =
                            snap.hasData ? snap.data!.docs.length : 0;
                        return GestureDetector(
                          onTap: _shareVideo,
                          child: Column(
                            children: [
                              Transform.flip(
                                flipX: true,
                                child: const Icon(
                                  Icons.reply,
                                  color: Colors.white,
                                  size: 34,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 8)
                                  ],
                                ),
                              ),
                              _countLabel(_formatCount(count)),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    // Save / bookmark
                    StreamBuilder<QuerySnapshot>(
                      stream: _postSubStream('saves'),
                      builder: (context, snap) {
                        final myId = FirebaseAuth.instance.currentUser?.uid;
                        final docs = snap.hasData ? snap.data!.docs : const [];
                        final int count = docs.length;
                        final bool isSaved =
                            myId != null && docs.any((d) => d.id == myId);
                        return GestureDetector(
                          onTap: () => _toggleSave(isSaved),
                          child: Column(
                            children: [
                              Icon(
                                isSaved
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: Colors.white,
                                size: 32,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 8)
                                ],
                              ),
                              _countLabel(_formatCount(count)),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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

// Shows the post owner's profile photo, display name, follow button, and caption
class _OwnerInfo extends StatelessWidget {
  final String userId;
  final String fallbackEmail;
  final String caption;
  final String postId;
  final String? soundId;
  final String soundLabel;

  const _OwnerInfo({
    required this.userId,
    required this.fallbackEmail,
    required this.caption,
    required this.postId,
    this.soundId,
    this.soundLabel = '',
  });

  // Follows or unfollows the video owner (and notifies them when following)
  Future<void> _toggleFollow(String myId, bool isFollowing) async {
    final firestore = FirebaseFirestore.instance;
    final followersDoc = firestore
        .collection('users')
        .doc(userId)
        .collection('followers')
        .doc(myId);
    final followingDoc = firestore
        .collection('users')
        .doc(myId)
        .collection('following')
        .doc(userId);

    if (isFollowing) {
      // Unfollow - remove both records and stop here
      final batch = firestore.batch();
      batch.delete(followersDoc);
      batch.delete(followingDoc);
      await batch.commit();
      return;
    }

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
        .doc(userId)
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

  // Opens the tapped user's public profile
  void _openProfile(BuildContext context) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PublicProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;

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
                GestureDetector(
                  onTap: () => _openProfile(context),
                  child: Container(
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
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
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
                ),
                const SizedBox(width: 10),
                // Follow / Following toggle next to the name (hidden on my own videos)
                if (myId != null && myId != userId && userId.isNotEmpty)
                  StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(userId)
                        .collection('followers')
                        .doc(myId)
                        .snapshots(),
                    builder: (context, followSnap) {
                      final bool isFollowing = followSnap.data?.exists ?? false;
                      return GestureDetector(
                        onTap: () => _toggleFollow(myId, isFollowing),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            // Red when not following, grey once following
                            color: isFollowing
                                ? const Color(0xFF3A3B3C)
                                : const Color(0xFFFF4B6E),
                            borderRadius: BorderRadius.circular(6),
                            border: isFollowing
                                ? Border.all(color: Colors.white38, width: 1)
                                : null,
                          ),
                          child: Text(
                            isFollowing ? 'Following' : 'Follow',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    },
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
            // Sound credit - tapping it opens every video using this sound
            if (soundId != null && soundId!.isNotEmpty) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SoundScreen(soundId: soundId!),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_note,
                        color: Colors.white,
                        size: 15,
                        shadows: [Shadow(color: Colors.black, blurRadius: 6)]),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        soundLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // View count below the video (unique viewers)
            if (postId.isNotEmpty) ...[
              const SizedBox(height: 8),
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('posts')
                    .doc(postId)
                    .collection('views')
                    .snapshots(),
                builder: (context, viewSnap) {
                  final int viewCount =
                      viewSnap.hasData ? viewSnap.data!.docs.length : 0;
                  return Row(
                    children: [
                      const Icon(
                        Icons.remove_red_eye,
                        color: Colors.white,
                        size: 16,
                        shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        viewCount == 1 ? '1 view' : '$viewCount views',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  );
                },
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

// A round speech-bubble icon: a circular outline with a small pointed tail,
// matching the reference design (rather than Material's rectangular
// chat_bubble_outline icon).
class _CommentBubbleIcon extends StatelessWidget {
  final double size;
  final Color color;
  final double strokeWidth;

  const _CommentBubbleIcon({
    this.size = 28,
    this.color = Colors.white,
    this.strokeWidth = 2.4,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 6,
      height: size + 8,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 3,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: strokeWidth),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 6),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: CustomPaint(
              size: const Size(10, 9),
              painter: _CommentTailPainter(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// The small pointed tail attached at the bottom-left of _CommentBubbleIcon
class _CommentTailPainter extends CustomPainter {
  final Color color;

  _CommentTailPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    final Path path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width * 0.8, size.height * 0.4)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CommentTailPainter oldDelegate) =>
      oldDelegate.color != color;
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

// Same pop-in animation as _PopInEmoji, but renders the "liked" state as a
// round blue-gradient badge with a white thumb-up icon inside (Facebook
// Reels style), instead of a bare emoji or icon.
class _PopInLikeBadge extends StatefulWidget {
  final double diameter;

  const _PopInLikeBadge({super.key, this.diameter = 40});

  @override
  State<_PopInLikeBadge> createState() => _PopInLikeBadgeState();
}

class _PopInLikeBadgeState extends State<_PopInLikeBadge>
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
      child: Container(
        width: widget.diameter,
        height: widget.diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1565C0).withOpacity(0.5),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.thumb_up_alt,
          color: Colors.white,
          size: widget.diameter * 0.5,
        ),
      ),
    );
  }
}

// Part of home_screen.dart - split out 13 Oct 2026 (step 5 of breaking up
// the big file, a piece at a time). The full-screen video feeds that
// sit on top of _VideoPostItem: FullScreenVideoScreen (tap from Home),
// ShortsScreen (+ the shorts shelf: _FeedSlots, _ShortsShelfPage,
// _ShortsShelfCard, _FeedItem), UserVideoFeedScreen (a profile's
// videos), SavedVideosFeedScreen and SingleVideoScreen. Public screens
// are still reached through `import 'home_screen.dart'` as before.
// Moved unchanged.
part of '../home_screen.dart';

// Opened by tapping a video on the (slightly shorter) Home feed - the same
// videos, but truly edge-to-edge: no search bar/tabs/stories row above it
// eating into the available height. Swiping up/down still moves between
// videos, starting from whichever one was tapped.
class FullScreenVideoScreen extends StatefulWidget {
  final List<_FeedItem> items;
  final int initialIndex;

  const FullScreenVideoScreen({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  @override
  State<FullScreenVideoScreen> createState() => _FullScreenVideoScreenState();
}

class _FullScreenVideoScreenState extends State<FullScreenVideoScreen> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToNextVideo() {
    final int? currentPage = _pageController.page?.round();
    if (currentPage != null && currentPage < widget.items.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // Round ← back button in the top-left corner (14 Oct 2026) - this
  // screen had none, so the only way out was the phone's back gesture.
  // Same look as the one on the profile / saved / single-video feeds.
  Widget _backButton(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.arrow_back, color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: widget.items.length,
              onPageChanged: (index) {
                final Set<String> keep = {widget.items[index].videoUrl};
                if (index + 1 < widget.items.length) {
                  keep.add(widget.items[index + 1].videoUrl);
                  VideoPreloadCache.preload(widget.items[index + 1].videoUrl);
                }
                // Also start the one after that - keeps fast, repeated swipes
                // from ever catching up to an unstarted download.
                if (index + 2 < widget.items.length) {
                  keep.add(widget.items[index + 2].videoUrl);
                  VideoPreloadCache.preload(widget.items[index + 2].videoUrl);
                }
                if (index - 1 >= 0) {
                  keep.add(widget.items[index - 1].videoUrl);
                  VideoPreloadCache.preload(widget.items[index - 1].videoUrl);
                }
                VideoPreloadCache.evictExcept(keep);
              },
              itemBuilder: (context, index) {
                final item = widget.items[index];
                return _VideoPostItem(
                  key: ValueKey('fullscreen_${item.feedKey}'),
                  postId: item.postId,
                  userId: item.originalUserId,
                  videoUrl: item.videoUrl,
                  caption: item.caption,
                  userEmail: item.userEmail,
                  reactions: item.reactions,
                  videoType: item.videoType,
                  onVideoEnd: _goToNextVideo,
                  repostNote: item.isRepost ? item.note : null,
                  repostByName: item.isRepost ? item.sharedByName : null,
                  repostByUserId: item.isRepost ? item.sharedByUserId : null,
                  repostByPhoto: item.isRepost ? item.sharedByPhoto : null,
                  videoSpeed: item.videoSpeed,
                  filterType: item.filterType,
                  blurBackground: item.blurBackground,
                  textOverlays: item.textOverlays,
                  effectsBaked: item.effectsBaked,
                  // No onTapToExpand here - already fullscreen, so a tap does
                  // the normal play/pause toggle instead.
                );
              },
            ),
          ),
          _backButton(context),
        ],
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

  // Accounts to hide (blocked either way - see block_service.dart).
  Set<String> _blockedIds = BlockService.instance.hidden.value;
  void _onBlockedChanged() {
    if (mounted) {
      setState(() => _blockedIds = BlockService.instance.hidden.value);
    }
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    // 25 Oct 2026 ("Who can watch" step B2): Shorts is a discovery feed -
    // Everyone posts only, newest kHomeFeedLimit. Needs the composite index
    // posts: videoType Asc + audience Asc + createdAt Desc.
    _shortPostsStream = FirebaseFirestore.instance
        .collection('posts')
        .where('videoType', isEqualTo: 'short')
        .where('audience', isEqualTo: 'everyone')
        .orderBy('createdAt', descending: true)
        .limit(kHomeFeedLimit)
        .snapshots();
    _shortRepostsStream = FirebaseFirestore.instance
        .collection('reposts')
        .where('videoType', isEqualTo: 'short')
        .orderBy('createdAt', descending: true)
        .limit(kHomeFeedLimit)
        .snapshots();
    BlockService.instance.hidden.addListener(_onBlockedChanged);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
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
                // Posts still being encoded by Bunny are only shown to
                // their uploader (who plays them from the local file).
                ...ownDocs
                    .where((d) => isVideoVisibleTo(
                        d.data() as Map<String, dynamic>,
                        FirebaseAuth.instance.currentUser?.uid))
                    .map((d) => _FeedItem.post(d)),
                ...repostDocs.map((d) => _FeedItem.repost(d)),
              ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

              // Never show reels from accounts you've blocked.
              final List<_FeedItem> visibleItems = _blockedIds.isEmpty
                  ? feedItems
                  : feedItems.where((item) {
                      final String posterId = (item.isRepost
                              ? item.sharedByUserId
                              : item.originalUserId) ??
                          '';
                      if (_blockedIds.contains(posterId)) return false;
                      if (item.isRepost &&
                          _blockedIds.contains(item.originalUserId)) {
                        return false;
                      }
                      return true;
                    }).toList();

              // Get a head start on the next two videos so even several
              // fast swipes in a row (before onPageChanged has caught up)
              // stay smooth, matching TikTok/Facebook's feel, instead of
              // just the very first swipe.
              if (visibleItems.length > 1) {
                VideoPreloadCache.preload(visibleItems[1].videoUrl);
              }
              if (visibleItems.length > 2) {
                VideoPreloadCache.preload(visibleItems[2].videoUrl);
              }

              if (visibleItems.isEmpty) {
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
                      itemCount: visibleItems.length,
                      onPageChanged: (index) {
                        final String currentUrl = visibleItems[index].videoUrl;
                        final Set<String> keep = {currentUrl};
                        if (index + 1 < visibleItems.length) {
                          final String nextUrl =
                              visibleItems[index + 1].videoUrl;
                          keep.add(nextUrl);
                          VideoPreloadCache.preload(nextUrl);
                        }
                        // Also start the one after that - keeps fast,
                        // repeated swipes from ever catching up to an
                        // unstarted download.
                        if (index + 2 < visibleItems.length) {
                          final String nextNextUrl =
                              visibleItems[index + 2].videoUrl;
                          keep.add(nextNextUrl);
                          VideoPreloadCache.preload(nextNextUrl);
                        }
                        if (index - 1 >= 0) {
                          final String prevUrl =
                              visibleItems[index - 1].videoUrl;
                          keep.add(prevUrl);
                          VideoPreloadCache.preload(prevUrl);
                        }
                        VideoPreloadCache.evictExcept(keep);
                      },
                      itemBuilder: (context, index) {
                        final item = visibleItems[index];
                        return _VideoPostItem(
                          key: ValueKey(item.feedKey),
                          postId: item.postId,
                          userId: item.originalUserId,
                          videoUrl: item.videoUrl,
                          caption: item.caption,
                          userEmail: item.userEmail,
                          reactions: item.reactions,
                          videoType: item.videoType,
                          onVideoEnd: () => _goToNextVideo(visibleItems.length),
                          repostNote: item.isRepost ? item.note : null,
                          repostByName:
                              item.isRepost ? item.sharedByName : null,
                          repostByUserId:
                              item.isRepost ? item.sharedByUserId : null,
                          repostByPhoto:
                              item.isRepost ? item.sharedByPhoto : null,
                          videoSpeed: item.videoSpeed,
                          filterType: item.filterType,
                          blurBackground: item.blurBackground,
                          textOverlays: item.textOverlays,
                          effectsBaked: item.effectsBaked,
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
// Maps the vertical PageView's flat "slot" index space onto the underlying
// real feed items, inserting one Shorts-shelf slot after every 5 real
// videos (only when there are more videos left to preview in the shelf).
// Pattern per block of 6 slots: 5 real items, then 1 shelf.
class _FeedSlots {
  static const int _realPerShelf = 5;
  final List<_FeedItem> items;
  final int shelfCount;

  _FeedSlots(this.items)
      : shelfCount = items.isEmpty ? 0 : (items.length - 1) ~/ _realPerShelf;

  int get length => items.length + shelfCount;

  // Null when [index] lands on a shelf slot.
  _FeedItem? itemAt(int index) {
    if (index < 0 || index >= length) return null;
    final int block = index ~/ (_realPerShelf + 1);
    final int offset = index % (_realPerShelf + 1);
    if (offset == _realPerShelf) return null; // shelf slot
    final int realIndex = block * _realPerShelf + offset;
    return realIndex < items.length ? items[realIndex] : null;
  }

  // The index into [items] that slot [index] shows, or null on a shelf
  // slot - lets a tap on a real video know where it sits in the plain,
  // shelf-free item list (used to open FullScreenVideoScreen at the same
  // video).
  int? realIndexAt(int index) {
    if (index < 0 || index >= length) return null;
    final int block = index ~/ (_realPerShelf + 1);
    final int offset = index % (_realPerShelf + 1);
    if (offset == _realPerShelf) return null; // shelf slot
    final int realIndex = block * _realPerShelf + offset;
    return realIndex < items.length ? realIndex : null;
  }

  // Up to 4 upcoming short-video indices (into [items]) to preview in the
  // shelf at this slot, or null if [index] isn't a shelf slot.
  List<int>? shelfAt(int index) {
    if (index < 0 || index >= length) return null;
    final int block = index ~/ (_realPerShelf + 1);
    final int offset = index % (_realPerShelf + 1);
    if (offset != _realPerShelf) return null;
    final int start = (block + 1) * _realPerShelf;
    final List<int> shorts = [];
    for (int i = start; i < items.length && shorts.length < 4; i++) {
      if (items[i].videoType == 'short') shorts.add(i);
    }
    if (shorts.isEmpty) {
      for (int i = start; i < items.length && shorts.length < 4; i++) {
        shorts.add(i);
      }
    }
    return shorts;
  }

  // Reverse of the real-item mapping above - which slot index a given
  // real item (by its index into [items]) ends up at, so tapping a shelf
  // thumbnail can jump the PageView straight to it.
  int displayIndexForReal(int realIndex) {
    final int block = realIndex ~/ _realPerShelf;
    final int offset = realIndex % _realPerShelf;
    return block * (_realPerShelf + 1) + offset;
  }
}

// YouTube-style "Shorts shelf": a full feed page showing a horizontal strip
// of upcoming short videos, so the user can jump ahead to one instead of
// swiping past everything in between.
class _ShortsShelfPage extends StatelessWidget {
  final List<MapEntry<int, _FeedItem>> entries;
  final void Function(int realIndex) onTapItem;

  const _ShortsShelfPage({required this.entries, required this.onTapItem});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bolt, color: Colors.redAccent, size: 22),
              SizedBox(width: 6),
              Text(
                'Shorts you might like',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 260,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => _ShortsShelfCard(
                item: entries[i].value,
                realIndex: entries[i].key,
                onTap: onTapItem,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Swipe up to keep watching, or tap one to jump ahead',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ShortsShelfCard extends StatelessWidget {
  final _FeedItem item;
  final int realIndex;
  final void Function(int realIndex) onTap;

  const _ShortsShelfCard({
    required this.item,
    required this.realIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onTap(realIndex),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 140,
          height: 260,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: cloudinaryThumbUrl(item.videoUrl),
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey.shade900),
                errorWidget: (_, __, ___) =>
                    Container(color: Colors.grey.shade900),
              ),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.0),
                      Colors.black.withOpacity(0.65),
                    ],
                    stops: const [0.6, 1.0],
                  ),
                ),
              ),
              const Center(
                child: Icon(Icons.play_arrow, color: Colors.white70, size: 36),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Text(
                  item.caption.isNotEmpty ? item.caption : item.userEmail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
  final double videoSpeed;
  final String filterType;
  // Whether empty space around this video (for aspect ratios that don't
  // exactly fill the screen) should get a blurred backdrop of the
  // video's own colors, or stay plain black - chosen by the uploader at
  // post time. Defaults to true (matches the app's original behavior)
  // for posts uploaded before this setting existed.
  final bool blurBackground;
  final List<TextOverlayData> textOverlays;
  // True once a post's speed/filter/text/sticker effects have been baked
  // directly into the delivered video file itself (via Cloudinary
  // transformations applied at upload time), so playback here should show
  // the raw file as-is instead of re-applying videoSpeed/filterType/
  // textOverlays on top of it - otherwise effects would be applied twice.
  // False for older posts uploaded before this existed, which still need
  // the client-side overlay below.
  final bool effectsBaked;

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
        sharedByPhoto = null,
        videoSpeed =
            ((doc.data() as Map<String, dynamic>)['videoSpeed'] as num?)
                    ?.toDouble() ??
                1.0,
        filterType =
            (doc.data() as Map<String, dynamic>)['filterType'] as String? ??
                'none',
        blurBackground =
            (doc.data() as Map<String, dynamic>)['blurBackground'] as bool? ??
                true,
        textOverlays = ((doc.data() as Map<String, dynamic>)['textOverlays']
                    as List<dynamic>?)
                ?.map((m) => TextOverlayData.fromMap(m as Map<String, dynamic>))
                .toList() ??
            const [],
        effectsBaked =
            (doc.data() as Map<String, dynamic>)['effectsBaked'] as bool? ??
                false;

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
            (doc.data() as Map<String, dynamic>)['sharedByPhoto'] as String?,
        videoSpeed =
            ((doc.data() as Map<String, dynamic>)['videoSpeed'] as num?)
                    ?.toDouble() ??
                1.0,
        filterType =
            (doc.data() as Map<String, dynamic>)['filterType'] as String? ??
                'none',
        blurBackground =
            (doc.data() as Map<String, dynamic>)['blurBackground'] as bool? ??
                true,
        textOverlays = ((doc.data() as Map<String, dynamic>)['textOverlays']
                    as List<dynamic>?)
                ?.map((m) => TextOverlayData.fromMap(m as Map<String, dynamic>))
                .toList() ??
            const [],
        effectsBaked =
            (doc.data() as Map<String, dynamic>)['effectsBaked'] as bool? ??
                false;
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
    // 25 Oct 2026 (step C): same query as the profile grid
    // (postsOfUserQuery) so the tapped index matches and the rules accept
    // it.
    _userPostsStream = postsOfUserQuery(widget.userId).snapshots();
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

          // Same filter as the profile grid, so the tapped index matches
          // (audience "Who can watch" + failed encoding).
          final String? myId = FirebaseAuth.instance.currentUser?.uid;
          final posts = (snapshot.data?.docs ?? [])
              .where((d) =>
                  isVideoVisibleTo(d.data() as Map<String, dynamic>, myId))
              .toList();
          if (posts.isEmpty) {
            return const Center(
              child: Text('No videos', style: TextStyle(color: Colors.grey)),
            );
          }
          if (posts.length > 1) {
            final String nextUrl =
                (posts[1].data() as Map<String, dynamic>)['videoUrl'] ?? '';
            VideoPreloadCache.preload(nextUrl);
          }
          if (posts.length > 2) {
            final String nextNextUrl =
                (posts[2].data() as Map<String, dynamic>)['videoUrl'] ?? '';
            VideoPreloadCache.preload(nextNextUrl);
          }

          return Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: posts.length,
                onPageChanged: (index) {
                  String urlOf(int i) =>
                      (posts[i].data() as Map<String, dynamic>)['videoUrl'] ??
                      '';
                  final String currentUrl = urlOf(index);
                  final Set<String> keep = {currentUrl};
                  if (index + 1 < posts.length) {
                    final String nextUrl = urlOf(index + 1);
                    keep.add(nextUrl);
                    VideoPreloadCache.preload(nextUrl);
                  }
                  // Also start the one after that - keeps fast, repeated
                  // swipes from ever catching up to an unstarted download.
                  if (index + 2 < posts.length) {
                    final String nextNextUrl = urlOf(index + 2);
                    keep.add(nextNextUrl);
                    VideoPreloadCache.preload(nextNextUrl);
                  }
                  if (index - 1 >= 0) {
                    final String prevUrl = urlOf(index - 1);
                    keep.add(prevUrl);
                    VideoPreloadCache.preload(prevUrl);
                  }
                  VideoPreloadCache.evictExcept(keep);
                },
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
                    videoSpeed:
                        ((post['videoSpeed']) as num?)?.toDouble() ?? 1.0,
                    filterType: (post['filterType'] as String?) ?? 'none',
                    textOverlays: ((post['textOverlays'] as List<dynamic>?)
                            ?.map((m) => TextOverlayData.fromMap(
                                m as Map<String, dynamic>))
                            .toList()) ??
                        const [],
                    effectsBaked: post['effectsBaked'] as bool? ?? false,
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

// Full-screen, swipeable viewer for the signed-in user's saved videos,
// opened from saved_videos_screen.dart's grid. Takes the already-loaded
// post docs (newest save first) instead of running its own query, so it
// shows exactly what the grid showed, in the same order.
class SavedVideosFeedScreen extends StatefulWidget {
  final List<DocumentSnapshot> posts;
  final int initialIndex;

  const SavedVideosFeedScreen({
    super.key,
    required this.posts,
    this.initialIndex = 0,
  });

  @override
  State<SavedVideosFeedScreen> createState() => _SavedVideosFeedScreenState();
}

class _SavedVideosFeedScreenState extends State<SavedVideosFeedScreen> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _preloadAround(widget.initialIndex);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  String _urlOf(int i) =>
      ((widget.posts[i].data() as Map<String, dynamic>?)?['videoUrl']
          as String?) ??
      '';

  // Same next-2 / prev-1 preload window as the other feed screens.
  void _preloadAround(int index) {
    final int count = widget.posts.length;
    final Set<String> keep = {_urlOf(index)};
    for (final int i in [index + 1, index + 2, index - 1]) {
      if (i < 0 || i >= count) continue;
      final String url = _urlOf(i);
      keep.add(url);
      VideoPreloadCache.preload(url);
    }
    VideoPreloadCache.evictExcept(keep);
  }

  void _goToNextVideo() {
    final int? currentPage = _pageController.page?.round();
    if (currentPage != null && currentPage < widget.posts.length - 1) {
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
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: widget.posts.length,
            onPageChanged: _preloadAround,
            itemBuilder: (context, index) {
              final postDoc = widget.posts[index];
              final post = (postDoc.data() as Map<String, dynamic>?) ?? {};
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
                videoSpeed: ((post['videoSpeed']) as num?)?.toDouble() ?? 1.0,
                filterType: (post['filterType'] as String?) ?? 'none',
                textOverlays: ((post['textOverlays'] as List<dynamic>?)
                        ?.map((m) =>
                            TextOverlayData.fromMap(m as Map<String, dynamic>))
                        .toList()) ??
                    const [],
                effectsBaked: post['effectsBaked'] as bool? ?? false,
                onVideoEnd: _goToNextVideo,
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
  late final Stream<QuerySnapshot> _postsStream;
  final PageController _pageController = PageController();
  bool _jumpedToInitial = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    // 25 Oct 2026 (step B2): Everyone posts only (same query + index as
    // Home's For You). A tapped friends-only video isn't in this list, so
    // it falls back to the single-video view below.
    _postsStream = FirebaseFirestore.instance
        .collection('posts')
        .where('audience', isEqualTo: 'everyone')
        .orderBy('createdAt', descending: true)
        .limit(kHomeFeedLimit)
        .snapshots();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  void _goToNextVideo(int totalCount) {
    if (!_pageController.hasClients || _pageController.page == null) return;
    final int next = _pageController.page!.round() + 1;
    if (next < totalCount) {
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _backButton(BuildContext context) {
    return SafeArea(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StreamBuilder<QuerySnapshot>(
        stream: _postsStream,
        builder: (context, snapshot) {
          // Only videos I may see (audience / failed encoding).
          final String? myId = FirebaseAuth.instance.currentUser?.uid;
          final List<QueryDocumentSnapshot> docs = (snapshot.data?.docs ?? [])
              .where((d) =>
                  isVideoVisibleTo(d.data() as Map<String, dynamic>, myId))
              .toList();
          final int initialIndex =
              docs.indexWhere((d) => d.id == widget.postId);

          // Feed hasn't loaded yet, or this post isn't in it for some
          // reason - fall back to just showing the single tapped video so
          // the screen never looks broken.
          if (initialIndex == -1) {
            return Stack(
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
                    videoSpeed: 1.0,
                    filterType: 'none',
                    textOverlays: const [],
                    effectsBaked: true,
                    onVideoEnd: () {},
                  ),
                ),
                _backButton(context),
              ],
            );
          }

          if (!_jumpedToInitial) {
            _jumpedToInitial = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_pageController.hasClients) {
                _pageController.jumpToPage(initialIndex);
              }
            });
          }

          if (initialIndex + 1 < docs.length) {
            final String nextUrl = (docs[initialIndex + 1].data()
                    as Map<String, dynamic>)['videoUrl'] ??
                '';
            VideoPreloadCache.preload(nextUrl);
          }
          if (initialIndex + 2 < docs.length) {
            final String nextNextUrl = (docs[initialIndex + 2].data()
                    as Map<String, dynamic>)['videoUrl'] ??
                '';
            VideoPreloadCache.preload(nextNextUrl);
          }

          return Stack(
            children: [
              SafeArea(
                top: false,
                child: PageView.builder(
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  itemCount: docs.length,
                  onPageChanged: (index) {
                    String urlOf(int i) =>
                        (docs[i].data() as Map<String, dynamic>)['videoUrl'] ??
                        '';
                    final String currentUrl = urlOf(index);
                    final Set<String> keep = {currentUrl};
                    if (index + 1 < docs.length) {
                      final String nextUrl = urlOf(index + 1);
                      keep.add(nextUrl);
                      VideoPreloadCache.preload(nextUrl);
                    }
                    // Also start the one after that - keeps fast, repeated
                    // swipes from ever catching up to an unstarted
                    // download.
                    if (index + 2 < docs.length) {
                      final String nextNextUrl = urlOf(index + 2);
                      keep.add(nextNextUrl);
                      VideoPreloadCache.preload(nextNextUrl);
                    }
                    if (index - 1 >= 0) {
                      final String prevUrl = urlOf(index - 1);
                      keep.add(prevUrl);
                      VideoPreloadCache.preload(prevUrl);
                    }
                    VideoPreloadCache.evictExcept(keep);
                  },
                  itemBuilder: (context, index) {
                    final postDoc = docs[index];
                    final post = postDoc.data() as Map<String, dynamic>;
                    final Map<String, dynamic> reactions =
                        (post['reactions'] as Map<String, dynamic>?) ?? {};
                    // Only the video actually tapped into keeps its
                    // "shared by" context — videos you swipe to next show
                    // as plain posts, same as the main feed.
                    final bool isInitial = postDoc.id == widget.postId;

                    return _VideoPostItem(
                      key: ValueKey(postDoc.id),
                      postId: postDoc.id,
                      userId: post['userId'] ?? '',
                      videoUrl: post['videoUrl'] ?? '',
                      caption: post['caption'] ?? '',
                      userEmail: post['userEmail'] ?? 'Unknown user',
                      reactions: reactions,
                      videoType: (post['videoType'] as String?) ?? 'short',
                      repostNote: isInitial ? widget.repostNote : null,
                      repostByName: isInitial ? widget.repostByName : null,
                      repostByUserId: isInitial ? widget.repostByUserId : null,
                      repostByPhoto: isInitial ? widget.repostByPhoto : null,
                      videoSpeed:
                          ((post['videoSpeed']) as num?)?.toDouble() ?? 1.0,
                      filterType: (post['filterType'] as String?) ?? 'none',
                      textOverlays: ((post['textOverlays'] as List<dynamic>?)
                              ?.map((m) => TextOverlayData.fromMap(
                                  m as Map<String, dynamic>))
                              .toList()) ??
                          const [],
                      effectsBaked: post['effectsBaked'] as bool? ?? false,
                      onVideoEnd: () => _goToNextVideo(docs.length),
                    );
                  },
                ),
              ),
              _backButton(context),
            ],
          );
        },
      ),
    );
  }
}

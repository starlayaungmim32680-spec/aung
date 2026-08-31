import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'notifications_screen.dart';
import 'public_profile_screen.dart';
import 'story_screen.dart';
import 'search_screen.dart';
import 'upload_screen.dart';
import 'live_screen.dart';
import 'sound_screen.dart';
import 'video_effects_screen.dart';
import 'translation_service.dart';
import 'text_overlay_style.dart';
import 'gifting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'media_utils.dart';
import 'content_filter.dart';
import 'video_preload_cache.dart';

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

// Two small cross-screen signals that let MainNavigationScreen's back-button
// handling talk to whichever HomeScreen is currently mounted, without
// needing a GlobalKey into its private State:
//   - homeFeedAtTop tracks whether the video feed is currently scrolled to
//     its very first video.
//   - homeFeedScrollToTopSignal is "pinged" (value incremented) to make the
//     feed animate back to the first video.
final ValueNotifier<bool> homeFeedAtTop = ValueNotifier<bool>(true);
final ValueNotifier<int> homeFeedScrollToTopSignal = ValueNotifier<int>(0);
// True while browsing the Home video feed should hide MainNavigationScreen's
// bottom bar - set to false while actively swiping down to later videos,
// back to true when swiping back up towards earlier ones. Facebook-style:
// the bar tucks away for an immersive view, then comes back the moment you
// scroll the other way.
final ValueNotifier<bool> homeFeedScrollingDown = ValueNotifier<bool>(false);
// Pinged by UploadScreen right after a post finishes uploading, so
// MainNavigationScreen can jump the person straight from Upload to the
// Home tab, at the newest video, instead of leaving them on the Upload
// screen to find it themselves.
final ValueNotifier<int> navigateToHomeSignal = ValueNotifier<int>(0);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PageController _pageController = PageController();
  // Last page index seen in the feed's onPageChanged, so it can tell
  // whether a swipe went forward (later videos) or backward (earlier
  // ones) - drives the bottom bar's hide-on-scroll-down behavior in
  // MainNavigationScreen (homeFeedScrollingDown).
  int _lastPageIndex = 0;

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

  // Accounts the current user has blocked — their posts/reposts are hidden
  // from the feed regardless of which tab is active.
  Set<String> _blockedIds = {};
  StreamSubscription<QuerySnapshot>? _blockedSub;

  @override
  void initState() {
    super.initState();
    // Stop the phone from dimming/locking while videos are playing.
    WakelockPlus.enable();
    homeFeedScrollToTopSignal.addListener(_onScrollToTopSignal);
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
      _blockedSub = FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('blocked')
          .snapshots()
          .listen((snap) {
        if (mounted) {
          setState(() {
            _blockedIds = snap.docs.map((d) => d.id).toSet();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    homeFeedScrollToTopSignal.removeListener(_onScrollToTopSignal);
    _followingSub?.cancel();
    _blockedSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // Called when MainNavigationScreen pings homeFeedScrollToTopSignal (the
  // phone's Back button while the feed is scrolled down) - animates back
  // to the very first video, Facebook-style.
  void _onScrollToTopSignal() {
    if (!mounted || !_pageController.hasClients) return;
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
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

              // Never show posts/reposts from accounts you've blocked,
              // regardless of which tab is active.
              final List<_FeedItem> unblockedItems = _blockedIds.isEmpty
                  ? feedItems
                  : feedItems.where((item) {
                      final String posterId = (item.isRepost
                              ? item.sharedByUserId
                              : item.originalUserId) ??
                          '';
                      if (_blockedIds.contains(posterId)) return false;
                      // A repost of a blocked user's original video should
                      // also be hidden.
                      if (item.isRepost &&
                          _blockedIds.contains(item.originalUserId)) {
                        return false;
                      }
                      return true;
                    }).toList();

              // On the Following tab, keep only videos from accounts you
              // follow - either the original poster, or whoever shared it.
              final List<_FeedItem> visibleItems = _followingOnly
                  ? unblockedItems.where((item) {
                      if (item.isRepost) {
                        return _followingIds.contains(item.sharedByUserId);
                      }
                      return _followingIds.contains(item.originalUserId);
                    }).toList()
                  : unblockedItems;

              // Every 5 real videos swiped, insert a YouTube-style "Shorts
              // shelf" page: a horizontal strip previewing a few of the
              // upcoming shorts, so the user can jump straight to one
              // instead of swiping through everything in between.
              final _FeedSlots slots = _FeedSlots(visibleItems);

              // Get a head start on the second video so even the very
              // first swipe (before onPageChanged has ever fired) is fast.
              if (visibleItems.length > 1) {
                VideoPreloadCache.preload(visibleItems[1].videoUrl);
              }

              if (feedItems.isEmpty) {
                return const Center(
                  child: Text(
                    'No posts yet. Be the first to upload!',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              // Header (search bar/tabs/bell/stories/live) gets its own
              // fixed area at the top, and the video feed gets the rest -
              // Column, not a Stack overlay, so the two never overlap:
              // Stories/search always have their own space, and the video
              // never renders underneath them.
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
                            itemCount: slots.length,
                            onPageChanged: (index) {
                              // Track whether the feed is scrolled to its
                              // very first video, for the Back-button
                              // scroll-to-top behavior in
                              // MainNavigationScreen.
                              homeFeedAtTop.value = index == 0;
                              // Hide MainNavigationScreen's bottom bar
                              // while swiping down to later videos, bring
                              // it back the moment the swipe direction
                              // reverses - Facebook-style.
                              if (index > _lastPageIndex) {
                                homeFeedScrollingDown.value = true;
                              } else if (index < _lastPageIndex) {
                                homeFeedScrollingDown.value = false;
                              }
                              _lastPageIndex = index;
                              // Preloading only makes sense for actual
                              // videos - a shelf slot has no single video
                              // of its own.
                              final _FeedItem? current = slots.itemAt(index);
                              if (current == null) return;
                              final Set<String> keep = {current.videoUrl};
                              final _FeedItem? next = slots.itemAt(index + 1);
                              if (next != null) {
                                keep.add(next.videoUrl);
                                VideoPreloadCache.preload(next.videoUrl);
                              }
                              final _FeedItem? prev = slots.itemAt(index - 1);
                              if (prev != null) {
                                keep.add(prev.videoUrl);
                                VideoPreloadCache.preload(prev.videoUrl);
                              }
                              VideoPreloadCache.evictExcept(keep);
                            },
                            itemBuilder: (context, index) {
                              final List<int>? shelfRealIndices =
                                  slots.shelfAt(index);
                              if (shelfRealIndices != null) {
                                return _ShortsShelfPage(
                                  entries: shelfRealIndices
                                      .map((i) => MapEntry(i, visibleItems[i]))
                                      .toList(),
                                  onTapItem: (realIndex) {
                                    _pageController.animateToPage(
                                      slots.displayIndexForReal(realIndex),
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                );
                              }

                              final item = slots.itemAt(index)!;

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
                                onVideoEnd: () => _goToNextVideo(slots.length),
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
                                // Tapping opens the same video full-screen,
                                // starting right on this item.
                                onTapToExpand: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => FullScreenVideoScreen(
                                      items: visibleItems,
                                      initialIndex:
                                          slots.realIndexAt(index) ?? 0,
                                    ),
                                  ),
                                ),
                              );
                            },
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
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

  // Accounts the current user has blocked — their posts/reposts are hidden
  // from Reels too.
  Set<String> _blockedIds = {};
  StreamSubscription<QuerySnapshot>? _blockedSub;

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

    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      _blockedSub = FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('blocked')
          .snapshots()
          .listen((snap) {
        if (mounted) {
          setState(() {
            _blockedIds = snap.docs.map((d) => d.id).toSet();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _blockedSub?.cancel();
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

              // Get a head start on the second video so even the very
              // first swipe (before onPageChanged has ever fired) is fast.
              if (visibleItems.length > 1) {
                VideoPreloadCache.preload(visibleItems[1].videoUrl);
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
          if (posts.length > 1) {
            final String nextUrl =
                (posts[1].data() as Map<String, dynamic>)['videoUrl'] ?? '';
            VideoPreloadCache.preload(nextUrl);
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
    _postsStream = FirebaseFirestore.instance
        .collection('posts')
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
          final List<QueryDocumentSnapshot> docs = snapshot.data?.docs ?? [];
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
  // Playback effects chosen at upload time (see video_effects_screen.dart).
  final double videoSpeed;
  final String filterType;
  final bool blurBackground;
  final List<TextOverlayData> textOverlays;
  // True once speed/filter/text/sticker effects are baked directly into
  // videoUrl itself (Cloudinary transformations applied at upload time) -
  // when true, videoSpeed/filterType/textOverlays above are only kept as
  // editable metadata and must NOT be re-applied during playback, or the
  // effects would show twice. False for older posts uploaded before this
  // existed, which still need the client-side overlay/color-filter below.
  final bool effectsBaked;
  // When set, a single tap on the video calls this instead of the normal
  // play/pause toggle - used on the compact Home feed to open the video
  // in FullScreenVideoScreen (see below), where the header/stories bar no
  // longer eats into the video's height. Left null inside that fullscreen
  // screen itself, so tapping there behaves normally (play/pause).
  final VoidCallback? onTapToExpand;

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
    this.videoSpeed = 1.0,
    this.filterType = 'none',
    this.blurBackground = true,
    this.textOverlays = const [],
    this.effectsBaked = false,
    this.onTapToExpand,
  });

  @override
  State<_VideoPostItem> createState() => _VideoPostItemState();
}

class _VideoPostItemState extends State<_VideoPostItem>
    with RouteAware, WidgetsBindingObserver {
  // How many times a video replays on its own before we auto-advance to
  // the next one. The user can still swipe away manually at any time.
  static const int _maxLoopsBeforeAutoSkip = 3;
  // Height of the solid black caption/username/sound panel below the
  // video (see build()) - the video is sized to leave exactly this much
  // room, rather than the panel floating on top of it.
  static const double _kCaptionPanelHeight = 128;

  // Wraps [child] in a ColorFiltered matrix ONLY when the uploader actually
  // picked a filter at post time. Most videos have none, so this skips the
  // ColorFiltered layer entirely rather than applying a technically-identity
  // matrix - some devices render even an identity ColorFilter with a very
  // slight colour/gamma shift, and the goal is the video looking exactly
  // like what was uploaded, with nothing added.
  Widget _withOptionalFilter(Widget child) {
    final String effectiveFilter =
        widget.effectsBaked ? 'none' : widget.filterType;
    if (effectiveFilter == 'none') return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(kVideoFilterMatrices[effectiveFilter] ??
          kVideoFilterMatrices['none']!),
      child: child,
    );
  }

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

  Widget _positionedOverlayText(TextOverlayData overlay) {
    final double fontSize = (overlay.isSticker ? 56 : 20) * overlay.scale;
    return IgnorePointer(
      child: Align(
        alignment: Alignment(overlay.dx * 2 - 1, overlay.dy * 2 - 1),
        child: overlay.imageUrl != null
            ? Image.network(overlay.imageUrl!,
                width: 80 * overlay.scale, height: 80 * overlay.scale)
            : overlay.isSticker
                ? Text(overlay.text, style: TextStyle(fontSize: fontSize))
                : AnimatedOverlayText(
                    text: overlay.text,
                    fontSize: fontSize,
                    color: overlay.color,
                    styleId: overlay.styleId,
                    animationId: overlay.animationId,
                  ),
      ),
    );
  }

  Future<void> _initializeVideo() async {
    if (widget.videoUrl.isEmpty) return;

    // If this video was already preloaded while the previous one was
    // playing, reuse that controller instead of starting a fresh network
    // fetch — this is what makes swiping to the next video feel instant.
    VideoPlayerController? controller =
        VideoPreloadCache.claim(widget.videoUrl);

    if (controller == null) {
      controller = VideoPlayerController.networkUrl(
          Uri.parse(playableVideoUrl(widget.videoUrl)));
      await controller.initialize();
    }
    await controller.setVolume(1);
    // Baked posts already play at the chosen speed inside the file itself
    // (see video_effects_baker.dart) - applying videoSpeed again on top
    // would speed it up/slow it down a second time.
    if (!widget.effectsBaked) {
      await controller.setPlaybackSpeed(widget.videoSpeed);
    }
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
      CoinService.instance.awardWatchComplete();

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
    if (widget.onTapToExpand != null) {
      widget.onTapToExpand!();
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
        CoinService.instance.awardShare();
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
          'videoSpeed': widget.videoSpeed,
          'filterType': widget.filterType,
          'textOverlays': widget.textOverlays.map((o) => o.toMap()).toList(),
          'effectsBaked': widget.effectsBaked,
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

  // Plain "Watch this video on Fly: <link>" text, used by every external
  // share destination below (WhatsApp / Messenger / Facebook / Email /
  // Copy link / More apps) — none of those write a repost, only the
  // "Share to Fly" tile above does that.
  String get _plainShareText {
    return widget.caption.isNotEmpty
        ? '${widget.caption}\n\nWatch on Fly: ${widget.videoUrl}'
        : 'Watch this video on Fly: ${widget.videoUrl}';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // Tries to open an external app via its scheme/URL. If the app isn't
  // installed (or the OS blocks the visibility check), falls back to the
  // web link inside [webFallback] so the user still gets somewhere useful.
  Future<void> _launchWithFallback(
      Uri appUri, Uri? webFallback, String appName) async {
    try {
      final bool launched =
          await launchUrl(appUri, mode: LaunchMode.externalApplication);
      if (launched) return;
    } catch (_) {
      // fall through to web fallback below
    }
    if (webFallback != null) {
      try {
        await launchUrl(webFallback, mode: LaunchMode.externalApplication);
        return;
      } catch (_) {}
    }
    _toast("Couldn't open $appName — check that it's installed");
  }

  Future<void> _shareToWhatsApp() async {
    Navigator.of(context).maybePop();
    final String text = Uri.encodeComponent(_plainShareText);
    // wa.me with no phone number opens WhatsApp's own contact/group picker,
    // so this naturally covers both individual friends and groups.
    await _launchWithFallback(
      Uri.parse('whatsapp://send?text=$text'),
      Uri.parse('https://wa.me/?text=$text'),
      'WhatsApp',
    );
  }

  Future<void> _shareToMessenger() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    // Messenger's own share dialog opens the user's friend/group list.
    await _launchWithFallback(
      Uri.parse('fb-messenger://share?link=$link'),
      Uri.parse('https://www.facebook.com/dialog/send'
          '?link=$link&app_id=0&redirect_uri=$link'),
      'Messenger',
    );
  }

  Future<void> _shareToFacebook() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    // Facebook's sharer dialog lets the user post to their feed/story or
    // send it straight to a friend, from inside the Facebook app itself.
    await _launchWithFallback(
      Uri.parse('fb://facewebmodal/f?href=https://www.facebook.com/sharer/'
          'sharer.php?u=$link'),
      Uri.parse('https://www.facebook.com/sharer/sharer.php?u=$link'),
      'Facebook',
    );
  }

  Future<void> _shareToTelegram() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    final String text = Uri.encodeComponent(_plainShareText);
    // Telegram's own share dialog opens the user's chat/group/channel list.
    await _launchWithFallback(
      Uri.parse('tg://msg_url?url=$link&text=$text'),
      Uri.parse('https://t.me/share/url?url=$link&text=$text'),
      'Telegram',
    );
  }

  Future<void> _shareToX() async {
    Navigator.of(context).maybePop();
    final String text = Uri.encodeComponent(_plainShareText);
    await _launchWithFallback(
      Uri.parse('twitter://post?message=$text'),
      Uri.parse('https://twitter.com/intent/tweet?text=$text'),
      'X',
    );
  }

  Future<void> _shareViaSms() async {
    Navigator.of(context).maybePop();
    final String body = Uri.encodeComponent(_plainShareText);
    // No recipient number - opens the phone's own contact picker, same as
    // tapping the "New message" compose button in the Messages app.
    final Uri smsUri = Uri.parse('sms:?body=$body');
    try {
      final bool launched =
          await launchUrl(smsUri, mode: LaunchMode.externalApplication);
      if (!launched) _toast("Couldn't open a messaging app");
    } catch (_) {
      _toast("Couldn't open a messaging app");
    }
  }

  Future<void> _shareViaEmail() async {
    Navigator.of(context).maybePop();
    final Uri emailUri = Uri(
      scheme: 'mailto',
      query: 'subject=${Uri.encodeComponent('Check out this video on Fly')}'
          '&body=${Uri.encodeComponent(_plainShareText)}',
    );
    try {
      final bool launched =
          await launchUrl(emailUri, mode: LaunchMode.externalApplication);
      if (!launched) _toast("Couldn't open an email app");
    } catch (_) {
      _toast("Couldn't open an email app");
    }
  }

  Future<void> _copyShareLink() async {
    await Clipboard.setData(ClipboardData(text: widget.videoUrl));
    if (mounted) Navigator.of(context).maybePop();
    _toast('Link copied to clipboard');
  }

  // Falls back to the OS's own share sheet (Telegram, SMS, Bluetooth, save
  // to Drive, and every other app installed on the phone) without going
  // through the "add a note" dialog or saving a repost.
  Future<void> _shareMoreApps() async {
    Navigator.of(context).maybePop();
    await Share.share(_plainShareText);
  }

  Future<void> _downloadVideo() async {
    Navigator.of(context).maybePop();
    _toast('Downloading video...');
    try {
      final response = await http.get(Uri.parse(widget.videoUrl));
      if (response.statusCode != 200) {
        _toast('Download failed');
        return;
      }
      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/'
          'fly_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final File tempFile = File(tempPath);
      await tempFile.writeAsBytes(response.bodyBytes);

      final bool hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final bool granted = await Gal.requestAccess();
        if (!granted) {
          _toast('Gallery access is needed to save the video');
          return;
        }
      }
      await Gal.putVideo(tempPath, album: 'Fly');
      await tempFile.delete();
      _toast('Video saved to your gallery');
    } catch (_) {
      _toast('Download failed — please try again');
    }
  }

  Widget _shareOptionTile(
      {required IconData icon,
      required Color color,
      required String label,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 68,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  // The main share bottom sheet: a row of direct-share destinations
  // (WhatsApp / Messenger / Facebook / Email / Copy link / More apps —
  // "More apps" opens the full OS chooser, which covers every other app
  // and lets the user pick a specific group chat inside it), plus the
  // existing in-app "Share to Fly" repost action and the video download.
  Future<void> _openShareSheet() {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Share video',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 18),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      _shareOptionTile(
                        icon: Icons.chat,
                        color: const Color(0xFF25D366),
                        label: 'WhatsApp',
                        onTap: _shareToWhatsApp,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.send,
                        color: const Color(0xFF0084FF),
                        label: 'Messenger',
                        onTap: _shareToMessenger,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.facebook,
                        color: const Color(0xFF1877F2),
                        label: 'Facebook',
                        onTap: _shareToFacebook,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.send_rounded,
                        color: const Color(0xFF29A9EA),
                        label: 'Telegram',
                        onTap: _shareToTelegram,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.close,
                        color: Colors.black,
                        label: 'X',
                        onTap: _shareToX,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.sms,
                        color: const Color(0xFF34C759),
                        label: 'Text',
                        onTap: _shareViaSms,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.email,
                        color: Colors.orangeAccent,
                        label: 'Email',
                        onTap: _shareViaEmail,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.link,
                        color: Colors.grey.shade700,
                        label: 'Copy link',
                        onTap: _copyShareLink,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.apps,
                        color: Colors.grey.shade700,
                        label: 'More apps',
                        onTap: _shareMoreApps,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: Colors.white24, height: 1),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.redAccent,
                    child: Icon(Icons.flight, color: Colors.white, size: 18),
                  ),
                  title: const Text('Share to Fly',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Repost this on your own profile',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _shareVideo();
                  },
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.grey.shade800,
                    child: const Icon(Icons.download,
                        color: Colors.white, size: 18),
                  ),
                  title: const Text('Download video',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Save to your phone gallery',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  onTap: _downloadVideo,
                ),
              ],
            ),
          ),
        );
      },
    );
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
                if (widget.repostByName != null &&
                    widget.repostByName!.isNotEmpty)
                  // Reposts show the original video inside a framed box
                  // (not edge-to-edge), so it visually reads as "this
                  // person's video", clearly separate from the sharer's
                  // own header above it.
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 30,
                    left: 8,
                    right: 8,
                    bottom: 130,
                    child: GestureDetector(
                      // Tapping the framed video jumps to the original
                      // post's own page (not the repost wrapper), so it
                      // reads like "go see this video where it lives".
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SingleVideoScreen(
                              postId: widget.postId,
                              userId: widget.userId,
                              videoUrl: widget.videoUrl,
                              caption: widget.caption,
                              userEmail: widget.userEmail,
                              videoType: widget.videoType,
                            ),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.white.withOpacity(0.3),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _withOptionalFilter(
                                  FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _controller!.value.size.width,
                                      height: _controller!.value.size.height,
                                      child: VideoPlayer(_controller!),
                                    ),
                                  ),
                                ),
                                if (!widget.effectsBaked)
                                  for (final overlay in widget.textOverlays)
                                    _positionedOverlayText(overlay),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else ...[
                  // "Smart Fit": compare the video's own shape to the
                  // phone's screen shape. When they're close (a normal
                  // vertical video on a normal vertical phone), fill the
                  // screen edge-to-edge - the sliver that gets cropped off
                  // is barely noticeable. When they're very different (a
                  // landscape recording, a square video), show the video
                  // in full instead, with plain black behind it, rather
                  // than cropping away a big chunk of what was actually
                  // filmed.
                  Builder(builder: (context) {
                    final Size screenSize = MediaQuery.of(context).size;
                    final double screenRatio =
                        screenSize.width / screenSize.height;
                    final double videoRatio = _controller!.value.aspectRatio;
                    final double mismatch = videoRatio > screenRatio
                        ? videoRatio / screenRatio
                        : screenRatio / videoRatio;
                    final bool shouldCover = mismatch < 1.35;

                    final Widget videoContent = shouldCover
                        ? FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _controller!.value.size.width,
                              height: _controller!.value.size.height,
                              child: _withOptionalFilter(
                                  VideoPlayer(_controller!)),
                            ),
                          )
                        : Stack(
                            children: [
                              Container(color: Colors.black),
                              Center(
                                child: AspectRatio(
                                  aspectRatio: videoRatio,
                                  child: _withOptionalFilter(
                                      VideoPlayer(_controller!)),
                                ),
                              ),
                            ],
                          );

                    // Leave room at the bottom for the caption/profile
                    // panel below - the video fills the screen only down
                    // to where that panel starts, not underneath it.
                    return Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: _kCaptionPanelHeight,
                      child: ClipRect(child: videoContent),
                    );
                  }),
                  if (!widget.effectsBaked)
                    for (final overlay in widget.textOverlays)
                      _positionedOverlayText(overlay),
                ],
              ] else
                Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.videoUrl.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: cloudinaryThumbUrl(widget.videoUrl),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey[900]),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey[900]),
                      ),
                    const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      ),
                    ),
                  ],
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

              if (widget.repostByName != null &&
                  widget.repostByName!.isNotEmpty)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: 16,
                  right: 90,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 13,
                              backgroundColor: Colors.grey[850],
                              backgroundImage: (widget.repostByPhoto != null &&
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
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: widget.repostByName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        shadows: [
                                          Shadow(
                                              color: Colors.black54,
                                              blurRadius: 6),
                                        ],
                                      ),
                                    ),
                                    const TextSpan(text: ' shared this'),
                                  ],
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black54, blurRadius: 6),
                                  ],
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.repostNote != null &&
                          widget.repostNote!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.repostNote!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 6),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

              // A solid black panel of its own for the caption/username/
              // sound row - not just text floating over the video with a
              // shadow, but its own distinctly separate area underneath
              // (the video above is sized to leave exactly this much
              // room, see the Smart Fit Builder above).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _kCaptionPanelHeight,
                child: IgnorePointer(
                  child: Container(
                    color: const Color(0xFF000000),
                  ),
                ),
              ),

              Positioned(
                left: 16,
                bottom: 100,
                right: 90,
                child: (widget.repostByName != null &&
                        widget.repostByName!.isNotEmpty)
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.25),
                            width: 0.6,
                          ),
                        ),
                        child: _OwnerInfo(
                          userId: widget.userId,
                          fallbackEmail: widget.userEmail,
                          caption: widget.caption,
                          postId: widget.postId,
                          soundId: soundId,
                          soundLabel: soundLabel,
                          reactionCount: liveReactions.length,
                          replyToPostId:
                              livePostData?['replyToPostId'] as String?,
                          replyToOwnerId:
                              livePostData?['replyToOwnerId'] as String?,
                          replyToOwnerName:
                              livePostData?['replyToOwnerName'] as String?,
                          compact: true,
                        ),
                      )
                    : _OwnerInfo(
                        userId: widget.userId,
                        fallbackEmail: widget.userEmail,
                        caption: widget.caption,
                        postId: widget.postId,
                        soundId: soundId,
                        soundLabel: soundLabel,
                        reactionCount: liveReactions.length,
                        replyToPostId:
                            livePostData?['replyToPostId'] as String?,
                        replyToOwnerId:
                            livePostData?['replyToOwnerId'] as String?,
                        replyToOwnerName:
                            livePostData?['replyToOwnerName'] as String?,
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

              if (widget.repostByName == null || widget.repostByName!.isEmpty)
                Positioned(
                  right: 12,
                  bottom: 120,
                  // Fly's action dock: Like/Comment/Share/Save float
                  // directly over the video (no background panel), sitting
                  // close together, each with its own icon design and a
                  // soft glow chip that lights up when active.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Like (long-press for reactions)
                      GestureDetector(
                        onTap: () => _quickToggleLike(liveReactions),
                        onLongPress: () =>
                            setState(() => _showReactionPicker = true),
                        child: Column(
                          children: [
                            _FlyActionGlow(
                              active: myReaction != null,
                              child: SizedBox(
                                width: 46,
                                height: 46,
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
                                              size: 32,
                                              shadows: [
                                                Shadow(
                                                    color: Colors.black,
                                                    blurRadius: 8),
                                              ],
                                            ),
                                ),
                              ),
                            ),
                            _countLabel(_formatCount(liveReactions.length)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
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
                                _FlyActionGlow(
                                  active: false,
                                  child: SizedBox(
                                    width: 46,
                                    height: 46,
                                    child: Center(
                                      child: _FlyCommentIcon(size: 30),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // Share
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('shares'),
                        builder: (context, snap) {
                          final int count =
                              snap.hasData ? snap.data!.docs.length : 0;
                          return GestureDetector(
                            onTap: _openShareSheet,
                            child: Column(
                              children: [
                                _FlyActionGlow(
                                  active: false,
                                  child: SizedBox(
                                    width: 46,
                                    height: 46,
                                    child: Center(
                                      child: _FlySwooshShareIcon(size: 30),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // Save / bookmark
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('saves'),
                        builder: (context, snap) {
                          final myId = FirebaseAuth.instance.currentUser?.uid;
                          final docs =
                              snap.hasData ? snap.data!.docs : const [];
                          final int count = docs.length;
                          final bool isSaved =
                              myId != null && docs.any((d) => d.id == myId);
                          return GestureDetector(
                            onTap: () => _toggleSave(isSaved),
                            child: Column(
                              children: [
                                _FlyActionGlow(
                                  active: isSaved,
                                  child: SizedBox(
                                    width: 46,
                                    height: 46,
                                    child: Center(
                                      child: Icon(
                                        isSaved
                                            ? Icons.bookmark
                                            : Icons.bookmark_border,
                                        color: Colors.white,
                                        size: 30,
                                        shadows: const [
                                          Shadow(
                                              color: Colors.black,
                                              blurRadius: 8),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // More options (Report / Block)
                      GestureDetector(
                        onTap: () => _showReportBlockSheet(context),
                        child: _FlyActionGlow(
                          active: false,
                          child: const SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: Icon(
                                Icons.more_horiz,
                                color: Colors.white,
                                size: 26,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 8),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Reposts show like/comment/share as a compact horizontal row
              // under the boxed video (Facebook-style) instead of the
              // vertical right-side rail used for regular posts.
              if (widget.repostByName != null &&
                  widget.repostByName!.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 46,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => _quickToggleLike(liveReactions),
                        onLongPress: () =>
                            setState(() => _showReactionPicker = true),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              myReaction != null
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: myReaction != null
                                  ? const Color(0xFFFF4B6E)
                                  : Colors.white,
                              size: 20,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 6)
                              ],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatCount(liveReactions.length),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 6)
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 18),
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('comments'),
                        builder: (context, snap) {
                          final int count =
                              snap.hasData ? snap.data!.docs.length : 0;
                          return GestureDetector(
                            onTap: _openComments,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  color: Colors.white,
                                  size: 19,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 6)
                                  ],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatCount(count),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
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
                      const SizedBox(width: 18),
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('shares'),
                        builder: (context, snap) {
                          final int count =
                              snap.hasData ? snap.data!.docs.length : 0;
                          return GestureDetector(
                            onTap: _openShareSheet,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.flip(
                                  flipX: true,
                                  child: const Icon(
                                    Icons.reply,
                                    color: Colors.white,
                                    size: 20,
                                    shadows: [
                                      Shadow(color: Colors.black, blurRadius: 6)
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatCount(count),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
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
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _showReportBlockSheet(context),
                        child: const Icon(
                          Icons.more_horiz,
                          color: Colors.white,
                          size: 22,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  ),
                ),
              // "Fly Frame": a small cinematic-style black band top and
              // bottom, each with a thin glowing cyan line right at the
              // screen edge - Fly's own branded framing instead of plain
              // flat black, and it also keeps the status bar clock and
              // the phone's (now-transparent) gesture/nav bar icons easy
              // to read over whatever's playing underneath. The video's
              // own size/fit is untouched - this sits on top of it, not
              // cut out of it. Positioned (not Align+Container) so the
              // bar's width is pinned unambiguously edge-to-edge.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 34,
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.85),
                              Colors.black.withOpacity(0.0),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 1.4,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF35E1E8).withOpacity(0.0),
                                const Color(0xFF35E1E8).withOpacity(0.55),
                                const Color(0xFF5B7CFA).withOpacity(0.55),
                                const Color(0xFF35E1E8).withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 34,
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.85),
                              Colors.black.withOpacity(0.0),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 1.4,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF35E1E8).withOpacity(0.0),
                                const Color(0xFF35E1E8).withOpacity(0.55),
                                const Color(0xFF5B7CFA).withOpacity(0.55),
                                const Color(0xFF35E1E8).withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Looks up a user's display name for the "Replying to @X" banner, since
  // _VideoPostItem only has their uid, not their display name, on hand.
  Future<String> _fetchDisplayName(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final String? name = doc.data()?['displayName'] as String?;
      return (name != null && name.trim().isNotEmpty) ? name : 'user';
    } catch (_) {
      return 'user';
    }
  }

  // Shows a bottom sheet with "Report" (always) and "Block user" (only for
  // other people's posts) options.
  void _showReportBlockSheet(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    final bool isOwnPost = myId != null && myId == widget.userId;

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
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.white),
                title: const Text('Report post',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showReportReasonSheet(
                    targetType: 'post',
                    targetId: widget.postId,
                    targetOwnerId: widget.userId,
                  );
                },
              ),
              if (!isOwnPost)
                ListTile(
                  leading: const Icon(Icons.reply, color: Color(0xFF35E1F2)),
                  title: const Text('Reply with video',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final String replyOwnerName =
                        await _fetchDisplayName(widget.userId);
                    if (!context.mounted) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UploadScreen(
                          replyToPostId: widget.postId,
                          replyToOwnerId: widget.userId,
                          replyToOwnerName: replyOwnerName,
                        ),
                      ),
                    );
                  },
                ),
              if (!isOwnPost)
                ListTile(
                  leading: const Icon(Icons.block, color: Colors.redAccent),
                  title: const Text('Block user',
                      style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _confirmBlockUser(widget.userId);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // Shows the reason picker, then writes a 'reports' document.
  void _showReportReasonSheet({
    required String targetType, // 'post' or 'comment'
    required String targetId,
    required String targetOwnerId,
    String? parentPostId, // set when targetType == 'comment'
  }) {
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
                  child: Text('Why are you reporting this?',
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
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _submitReport(
                        targetType: targetType,
                        targetId: targetId,
                        targetOwnerId: targetOwnerId,
                        reason: reason,
                        parentPostId: parentPostId,
                      );
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitReport({
    required String targetType,
    required String targetId,
    required String targetOwnerId,
    required String reason,
    String? parentPostId,
  }) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'targetType': targetType,
        'targetId': targetId,
        'parentPostId': parentPostId,
        'targetOwnerId': targetOwnerId,
        'reporterId': myId,
        'reason': reason,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted. Thank you.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not submit report. Try again.')),
        );
      }
    }
  }

  Future<void> _confirmBlockUser(String userIdToBlock) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Block this user?',
            style: TextStyle(color: Colors.white)),
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
            child:
                const Text('Block', style: TextStyle(color: Colors.redAccent)),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User blocked.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not block user. Try again.')),
        );
      }
    }
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

  // Accounts the current user has blocked — their comments are hidden here.
  Set<String> _blockedIds = {};
  StreamSubscription<QuerySnapshot>? _blockedSub;

  @override
  void initState() {
    super.initState();
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      _blockedSub = FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('blocked')
          .snapshots()
          .listen((snap) {
        if (mounted) {
          setState(() {
            _blockedIds = snap.docs.map((d) => d.id).toSet();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    _blockedSub?.cancel();
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

  // Base URL of the self-hosted moderation service (Flask on Render.com),
  // which proxies to OpenAI's free, multilingual omni-moderation model.
  static const String _moderationBaseUrl =
      'https://fly-moderation.onrender.com';

  // Calls the moderation service and returns whether the content was
  // flagged. Fails "open" (returns false / not flagged) on any network
  // error or timeout - e.g. the free Render instance waking up from a
  // cold start can take up to ~50s - so a moderation-service outage never
  // blocks comments outright. The local ContentFilter word-list check
  // still runs regardless as a first line of defense.
  Future<bool> _isFlaggedByModerationServer(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_moderationBaseUrl$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) return false;
      final Map<String, dynamic> data = jsonDecode(response.body);
      return data['flagged'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sendComment() async {
    final user = FirebaseAuth.instance.currentUser;
    final String text = _commentController.text.trim();
    if (user == null || text.isEmpty) return;

    // Block obviously inappropriate comments before writing to Firestore.
    // The local word-list is small and English/Burmese-only, so it won't
    // catch every language or every Burmese slang term.
    if (ContentFilter.containsBlockedContent(text)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Your comment contains inappropriate language. Please edit it.'),
          ),
        );
      }
      return;
    }

    // Second line of defense: OpenAI's multilingual moderation model,
    // which understands far more languages and slang (including Burmese)
    // than the local word-list ever can.
    setState(() => _isSending = true);
    final bool commentFlagged =
        await _isFlaggedByModerationServer('/moderate/text', {'text': text});
    if (commentFlagged) {
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Your comment contains inappropriate language. Please edit it.'),
          ),
        );
      }
      return;
    }

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

  // Shows a reason picker and writes a 'reports' document for a comment.
  void _showCommentReportSheet(
      DocumentReference commentRef, Map<String, dynamic> data) {
    const List<String> reasons = [
      'Nudity or sexual content',
      'Hate speech or harassment',
      'Violence or dangerous content',
      'Spam or scam',
      'Something else',
    ];
    final String commentOwnerId = data['userId'] ?? '';

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
                  child: Text('Report this comment',
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
                      final String? myId =
                          FirebaseAuth.instance.currentUser?.uid;
                      if (myId == null) return;
                      try {
                        await FirebaseFirestore.instance
                            .collection('reports')
                            .add({
                          'targetType': 'comment',
                          'targetId': commentRef.id,
                          'parentPostId': widget.postId,
                          'targetOwnerId': commentOwnerId,
                          'reporterId': myId,
                          'reason': reason,
                          'status': 'pending',
                          'createdAt': FieldValue.serverTimestamp(),
                        });
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Report submitted. Thank you.')),
                          );
                        }
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Could not submit report. Try again.')),
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

                final List<QueryDocumentSnapshot> comments =
                    (snapshot.data?.docs ?? []).where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final String commentUserId = data['userId'] ?? '';
                  return !_blockedIds.contains(commentUserId);
                }).toList();

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
                      onReport: _showCommentReportSheet,
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
  final void Function(DocumentReference ref, Map<String, dynamic> data)
      onReport;

  const _CommentTile({
    required this.commentRef,
    required this.data,
    required this.onReply,
    required this.onReact,
    required this.onReport,
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
        GestureDetector(
          onLongPress: () => widget.onReport(widget.commentRef, widget.data),
          child: Padding(
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
                              if (replyCount == 0)
                                return const SizedBox.shrink();
                              return GestureDetector(
                                onTap: () => setState(
                                    () => _showReplies = !_showReplies),
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
// Renders a caption with any #hashtags shown in a distinct color and
// tappable, opening HashtagScreen for that tag.
class _CaptionWithHashtags extends StatefulWidget {
  final String caption;
  final bool compact;

  const _CaptionWithHashtags({required this.caption, required this.compact});

  @override
  State<_CaptionWithHashtags> createState() => _CaptionWithHashtagsState();
}

class _CaptionWithHashtagsState extends State<_CaptionWithHashtags> {
  String? _translated;
  bool _translating = false;
  bool _showTranslated = false;
  // Set only when a translate attempt comes back genuinely not
  // applicable (already the device's language, or an unsupported
  // language) - hides the link. A failed *attempt* (weak connection,
  // low storage - common on budget phones) does NOT set this, so the
  // link stays put and the user can just tap it again once they have a
  // better connection, instead of the feature silently vanishing.
  bool _translationUnavailable = false;

  Future<void> _onTranslateTap() async {
    // Already translated once - just toggle between the two, no need to
    // hit ML Kit again.
    if (_translated != null) {
      setState(() => _showTranslated = !_showTranslated);
      return;
    }
    setState(() => _translating = true);
    final TranslationOutcome outcome = await TranslationService.instance
        .translateToDeviceLanguage(widget.caption);
    if (!mounted) return;
    setState(() {
      _translating = false;
      switch (outcome.status) {
        case TranslationStatus.success:
          _translated = outcome.text;
          _showTranslated = true;
          break;
        case TranslationStatus.notApplicable:
          _translationUnavailable = true;
          break;
        case TranslationStatus.retry:
          // Leave everything as-is so the link (and a quick explanation)
          // shows again and can be tapped to retry.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Couldn't translate - check your connection "
                    'and try again'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
      }
    });
  }

  List<InlineSpan> _spansFor(BuildContext context, String text) {
    final RegExp hashtagPattern = RegExp(r'#([\p{L}\p{N}_]+)', unicode: true);
    final List<InlineSpan> spans = [];
    int lastEnd = 0;

    for (final match in hashtagPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final String tag = match.group(1)!;
      spans.add(
        TextSpan(
          text: '#$tag',
          style: const TextStyle(
            color: Color(0xFF6FC3FF),
            fontWeight: FontWeight.bold,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HashtagScreen(tag: tag.toLowerCase()),
                ),
              );
            },
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final bool compact = widget.compact;
    final String textToShow =
        _showTranslated && _translated != null ? _translated! : widget.caption;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 12 : 14,
              shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
            ),
            children: _spansFor(context, textToShow),
          ),
          maxLines: compact ? 1 : null,
          overflow: compact ? TextOverflow.ellipsis : TextOverflow.visible,
        ),
        // Skip the translate link in the compact (repost card) layout -
        // there's no room for it there - and once we've established
        // there's nothing useful to translate.
        if (!compact && !_translationUnavailable) ...[
          const SizedBox(height: 3),
          GestureDetector(
            onTap: _translating ? null : _onTranslateTap,
            child: _translating
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Translating\u2026',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  )
                : Text(
                    _showTranslated ? 'See original' : 'See translation',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

// Grid of every video tagged with a given #hashtag.
class HashtagScreen extends StatelessWidget {
  final String tag;
  const HashtagScreen({super.key, required this.tag});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('#$tag', style: const TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .where('hashtags', arrayContains: tag)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            );
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('No videos with this hashtag yet.',
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
              childAspectRatio: 9 / 16,
            ),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final String videoUrl = data['videoUrl'] ?? '';
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SingleVideoScreen(
                        postId: doc.id,
                        userId: data['userId'] ?? '',
                        videoUrl: videoUrl,
                        caption: data['caption'] ?? '',
                        userEmail: data['userEmail'] ?? '',
                        videoType: (data['videoType'] as String?) ?? 'short',
                      ),
                    ),
                  );
                },
                child: Container(
                  color: Colors.grey[900],
                  child: CachedNetworkImage(
                    imageUrl: cloudinaryThumbUrl(videoUrl),
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: Colors.grey[900]),
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey[900]),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _OwnerInfo extends StatelessWidget {
  final String userId;
  final String fallbackEmail;
  final String caption;
  final String postId;
  final String? soundId;
  final String soundLabel;
  // "Orbit Ring": how many reactions this video has, drawn as a partial
  // gradient ring around the avatar - a quick, glanceable read on how
  // this specific video is landing, without needing to check the like
  // count separately. Purely visual, computed from data already on hand
  // (no extra reads).
  final int reactionCount;
  // "Reply Video Chain": when this video is itself a reply to someone
  // else's post, these carry who it's replying to, so a small "Replying
  // to @X" chip can link back to the original.
  final String? replyToPostId;
  final String? replyToOwnerId;
  final String? replyToOwnerName;
  // When true, renders a much smaller version (smaller avatar/text, no
  // sound credit or view count, single-line caption) for use inside the
  // repost nested card, where space is tight.
  final bool compact;

  const _OwnerInfo({
    required this.userId,
    required this.fallbackEmail,
    required this.caption,
    required this.postId,
    this.soundId,
    this.soundLabel = '',
    this.reactionCount = 0,
    this.replyToPostId,
    this.replyToOwnerId,
    this.replyToOwnerName,
    this.compact = false,
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
                // Plain avatar (no overlapping badge, so it stays fully
                // visible) with the Follow/Following control as its own
                // small circle right beside it - Fly's own take on the
                // follow control, instead of the pill-shaped button every
                // other app uses. The badge carries Fly's signature
                // blue-cyan gradient (same as the comment icon and orbit
                // menu) so it reads as distinctly "Fly".
                // "Orbit Ring" - a thin gradient arc around the avatar
                // showing how this video's reaction count compares to a
                // rough popularity scale (fuller ring = more reactions).
                // Purely visual, computed from data already streamed to
                // this widget - no extra Firestore reads.
                CustomPaint(
                  painter: _OrbitRingPainter(
                    // sqrt scaling so the ring fills up meaningfully even
                    // at modest reaction counts, instead of looking empty
                    // until a video goes viral.
                    progress: (sqrt(reactionCount.clamp(0, 400)) / 20)
                        .clamp(0.0, 1.0),
                    strokeWidth: compact ? 2 : 2.5,
                  ),
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 4 : 5),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                          ),
                        ),
                        child: CircleAvatar(
                          radius: compact ? 13 : 18,
                          backgroundColor: Colors.grey[850],
                          backgroundImage:
                              (photoUrl != null && photoUrl.isNotEmpty)
                                  ? NetworkImage(photoUrl)
                                  : null,
                          child: (photoUrl == null || photoUrl.isEmpty)
                              ? Text(
                                  displayName.isNotEmpty
                                      ? displayName[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: compact ? 12 : 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                if (myId != null && myId != userId && userId.isNotEmpty) ...[
                  const SizedBox(width: 6),
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
                          width: compact ? 22 : 26,
                          height: compact ? 22 : 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: isFollowing
                                ? null
                                : const LinearGradient(
                                    colors: [
                                      Color(0xFF2E6BFF),
                                      Color(0xFF35E1F2),
                                    ],
                                  ),
                            color: isFollowing ? const Color(0xFF3A3B3C) : null,
                            border: isFollowing
                                ? Border.all(color: Colors.white38, width: 1)
                                : null,
                          ),
                          child: Icon(
                            isFollowing ? Icons.check : Icons.add,
                            color: Colors.white,
                            size: compact ? 13 : 16,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(width: 10),
                Flexible(
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Text(
                      displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: compact ? 13 : 16,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 6)
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (replyToPostId != null && replyToOwnerName != null) ...[
              SizedBox(height: compact ? 3 : 6),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SingleVideoScreen(
                        postId: replyToPostId!,
                        userId: replyToOwnerId ?? '',
                        videoUrl: '',
                        caption: '',
                        userEmail: '',
                        videoType: 'short',
                      ),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply,
                        color: Colors.white70, size: compact ? 12 : 14),
                    const SizedBox(width: 4),
                    Text(
                      'Replying to @$replyToOwnerName',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: compact ? 10 : 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (caption.isNotEmpty) ...[
              SizedBox(height: compact ? 4 : 8),
              _CaptionWithHashtags(
                caption: caption,
                compact: compact,
              ),
            ],
            // Sound credit and view count take up space we don't have in
            // the compact (repost card) layout, so skip them there.
            if (!compact) ...[
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
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 6)
                          ]),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          soundLabel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6)
                            ],
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
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6)
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ], // end if (!compact)
          ],
        );
      },
    );
  }
}

// Paints the "Orbit Ring" - a partial gradient arc around a video's
// avatar, filled proportionally to that video's reaction count. Fly's
// own take on the standard static gradient story-ring border every
// other short-video app uses, since this one actually changes based on
// engagement instead of just being decorative.
class _OrbitRingPainter extends CustomPainter {
  final double progress; // 0.0 - 1.0
  final double strokeWidth;

  _OrbitRingPainter({required this.progress, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.width - strokeWidth) / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Color(0xFF2E6BFF), Color(0xFF35E1F2), Color(0xFF2E6BFF)],
      ).createShader(rect);

    canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, arc);
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.strokeWidth != strokeWidth;
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
                builder: (context) => NotificationsScreen(),
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

// Shared "glow chip" used behind each icon in Fly's action dock: a soft
// cyan radial glow fades in behind the icon when that action is active
// (liked / saved), giving each button its own subtle focus state instead
// of the plain flat icons most short-video apps use.
class _FlyActionGlow extends StatelessWidget {
  final bool active;
  final Widget child;

  const _FlyActionGlow({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: active
            ? RadialGradient(
                colors: [
                  const Color(0xFF35E1E8).withOpacity(0.35),
                  const Color(0xFF35E1E8).withOpacity(0.0),
                ],
              )
            : null,
      ),
      child: child,
    );
  }
}

// Fly's own comment icon (used in the main action dock): a speech bubble
// drawn with the app's cyan-to-blue gradient (the same gradient family as
// the logo / story ring) instead of a plain white outline, plus a small
// solid dot accent — giving it its own identity rather than a generic
// chat-bubble icon shared by other apps.
class _FlyCommentIcon extends StatelessWidget {
  final double size;
  const _FlyCommentIcon({this.size = 24});

  @override
  Widget build(BuildContext context) {
    final double boxSize = size * (80 / 60);
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: CustomPaint(painter: _FlyCommentPainter()),
    );
  }
}

class _FlyCommentPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Shader gradientShader = const LinearGradient(
      colors: [Color(0xFF35E1E8), Color(0xFF5B7CFA)],
    ).createShader(rect);

    // Soft dark backdrop shadow so the gradient stroke still reads clearly
    // over light video frames (there's no glass panel behind it anymore).
    final Paint shadowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    final RRect shadowBubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.08,
        size.height * 0.14,
        size.width * 0.84,
        size.height * 0.6,
      ),
      Radius.circular(size.height * 0.3),
    );
    canvas.drawRRect(shadowBubble, shadowPaint);

    final Paint strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..shader = gradientShader;

    final RRect bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.08,
        size.height * 0.14,
        size.width * 0.84,
        size.height * 0.6,
      ),
      Radius.circular(size.height * 0.3),
    );
    canvas.drawRRect(bubble, strokePaint);

    final Paint fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = gradientShader;
    final Path tail = Path()
      ..moveTo(size.width * 0.26, size.height * 0.72)
      ..lineTo(size.width * 0.18, size.height * 0.94)
      ..lineTo(size.width * 0.42, size.height * 0.74)
      ..close();
    canvas.drawPath(tail, fillPaint);

    // Three small dots inside the bubble - the classic "comment/typing"
    // mark, so the icon reads as a comment bubble at a glance.
    final Paint dotsPaint = Paint()..color = Colors.white;
    final double dotY = size.height * 0.44;
    final double dotRadius = size.width * 0.045;
    for (final double dotX in [0.32, 0.5, 0.68]) {
      canvas.drawCircle(
        Offset(size.width * dotX, dotY),
        dotRadius,
        dotsPaint,
      );
    }

    // Small accent dot — Fly's identity mark on the bubble.
    canvas.drawCircle(
      Offset(size.width * 0.86, size.height * 0.18),
      size.width * 0.065,
      Paint()..color = const Color(0xFF35E1E8),
    );
  }

  @override
  bool shouldRepaint(covariant _FlyCommentPainter oldDelegate) => false;
}

// Fly's own share icon (used in the main action dock): a paper-plane with a
// soft tapering gradient motion trail, echoing the app's short-video "fast"
// feel — used instead of a plain flipped Material "reply" arrow like other
// apps use for share.
class _FlySwooshShareIcon extends StatelessWidget {
  final double size;
  const _FlySwooshShareIcon({this.size = 26});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FlySwooshSharePainter()),
    );
  }
}

class _FlySwooshSharePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Soft dark backdrop shadow so the plane still reads clearly over
    // light video frames (there's no glass panel behind it anymore).
    final Path shadowPlane = Path()
      ..moveTo(size.width * 0.10, size.height * 0.55)
      ..lineTo(size.width * 0.85, size.height * 0.15)
      ..lineTo(size.width * 0.55, size.height * 0.90)
      ..lineTo(size.width * 0.46, size.height * 0.60)
      ..close();
    canvas.drawPath(
      shadowPlane,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.black.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // Tapering trail behind the plane, fading out with each line.
    for (int i = 0; i < 3; i++) {
      final double t = i / 2;
      final Paint trailPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 - i * 0.7
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF35E1E8).withOpacity(0.55 - i * 0.18);
      canvas.drawLine(
        Offset(size.width * (0.66 - t * 0.10), size.height * (0.36 + t * 0.10)),
        Offset(size.width * (0.86 - t * 0.10), size.height * (0.20 + t * 0.10)),
        trailPaint,
      );
    }

    final Shader gradientShader = const LinearGradient(
      colors: [Color(0xFF35E1E8), Color(0xFF5B7CFA)],
    ).createShader(Offset.zero & size);
    final Paint planePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = gradientShader;

    final Path plane = Path()
      ..moveTo(size.width * 0.10, size.height * 0.55)
      ..lineTo(size.width * 0.85, size.height * 0.15)
      ..lineTo(size.width * 0.55, size.height * 0.90)
      ..lineTo(size.width * 0.46, size.height * 0.60)
      ..close();
    canvas.drawPath(plane, planePaint);
  }

  @override
  bool shouldRepaint(covariant _FlySwooshSharePainter oldDelegate) => false;
}

// A round speech-bubble icon: a circular outline with a small pointed tail,
// matching the reference design (rather than Material's rectangular
// chat_bubble_outline icon).
// A TikTok-style comment icon: a rounded-rectangle (pill-ish) speech bubble
// outline with a small pointed tail at the bottom-left, matching Ko's
// reference image more closely than a plain circular bubble.
// A Facebook-style comment icon: a flattened oval speech-bubble outline
// with a small filled pointed tail at the bottom-left.
class _CommentBubbleIcon extends StatelessWidget {
  final double size;
  final Color color;
  final double strokeWidth;

  const _CommentBubbleIcon({
    this.size = 28,
    this.color = Colors.white,
    this.strokeWidth = 3.2,
  });

  @override
  Widget build(BuildContext context) {
    // The painter works in an 80x80 reference space; scale the box to match.
    final double boxSize = size * (80 / 60);
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: CustomPaint(
        painter:
            _FacebookCommentPainter(color: color, strokeWidth: strokeWidth),
      ),
    );
  }
}

class _FacebookCommentPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _FacebookCommentPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / 80;
    canvas.save();
    canvas.scale(scale);

    // Flattened oval bubble body (Facebook-style, not a perfect circle).
    final Rect ellipseRect =
        Rect.fromCenter(center: const Offset(40, 34), width: 60, height: 48);

    // Small filled pointed tail at the bottom-left of the bubble.
    final Path tail = Path()
      ..moveTo(28, 54)
      ..lineTo(22, 68)
      ..lineTo(38, 60)
      ..close();

    // Soft drop shadow so the icon still reads over bright video frames.
    final Paint shadowStroke = Paint()
      ..color = Colors.black38
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final Paint shadowFill = Paint()
      ..color = Colors.black38
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawOval(ellipseRect, shadowStroke);
    canvas.drawPath(tail, shadowFill);

    final Paint bodyStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawOval(ellipseRect, bodyStroke);
    canvas.drawPath(tail, Paint()..color = color);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FacebookCommentPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
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

import 'dart:async';
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
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../video_disk_cache.dart';
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
import 'moderation_service.dart';
import 'video_preload_cache.dart';
import 'video_upload_service.dart' show isVideoVisibleTo;
import 'post_audience.dart';
import 'local_video_cache.dart';
import 'call_push_service.dart' show sendActivityPush;
import '../block_service.dart';

// Pieces of this screen that live in their own files (same library).
part 'home/home_fx_widgets.dart';
part 'home/home_comments.dart';
part 'home/home_post_info.dart';
part 'home/home_notification_post.dart';
part 'home/home_feeds.dart';
part 'home/home_video_post.dart';

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

  // Accounts to hide - people I blocked AND people who blocked me (see
  // block_service.dart). Their posts/reposts never show, on either tab.
  Set<String> _blockedIds = BlockService.instance.hidden.value;
  void _onBlockedChanged() {
    if (mounted) {
      setState(() => _blockedIds = BlockService.instance.hidden.value);
    }
  }

  @override
  void initState() {
    super.initState();
    // Stop the phone from dimming/locking while videos are playing.
    WakelockPlus.enable();
    homeFeedScrollToTopSignal.addListener(_onScrollToTopSignal);
    BlockService.instance.hidden.addListener(_onBlockedChanged);
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
    homeFeedScrollToTopSignal.removeListener(_onScrollToTopSignal);
    _followingSub?.cancel();
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
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
                // Posts still being encoded by Bunny are only shown to
                // their uploader (who plays them from the local file).
                ...ownDocs
                    .where((d) => isVideoVisibleTo(
                        d.data() as Map<String, dynamic>,
                        FirebaseAuth.instance.currentUser?.uid))
                    .map((d) => _FeedItem.post(d)),
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
                              // Also start the one after that - by the time
                              // the person lands on `next`, this one is
                              // already partway loaded too, so back-to-back
                              // fast swipes don't hit a spinner.
                              final _FeedItem? nextNext =
                                  slots.itemAt(index + 2);
                              if (nextNext != null) {
                                keep.add(nextNext.videoUrl);
                                VideoPreloadCache.preload(nextNext.videoUrl);
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

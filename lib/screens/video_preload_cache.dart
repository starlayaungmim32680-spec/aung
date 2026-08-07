import 'package:video_player/video_player.dart';
import 'media_utils.dart';

// A tiny shared cache that lets a feed screen start initializing the NEXT
// video's controller in the background while the CURRENT video is still
// playing, so swiping forward doesn't show a loading gap.
//
// Usage from a feed screen (HomeScreen/ShortsScreen/SingleVideoScreen):
//   - on page change, call VideoPreloadCache.preload(nextUrl)
//   - and VideoPreloadCache.evictExcept({currentUrl, nextUrl}) to keep the
//     cache small (video controllers are relatively expensive resources).
//
// Usage from _VideoPostItemState._initializeVideo():
//   - call VideoPreloadCache.claim(widget.videoUrl) first; if it returns a
//     controller, it's already initialized and ready to play immediately.
//     Otherwise fall back to creating+initializing a fresh controller as
//     before.
class VideoPreloadCache {
  static final Map<String, VideoPlayerController> _ready = {};
  static final Set<String> _pending = {};

  /// Starts initializing [url] in the background if it isn't already
  /// cached or in progress. Safe to call repeatedly - it's a no-op once
  /// a preload for this url is already underway or done.
  static Future<void> preload(String url) async {
    if (url.isEmpty || _ready.containsKey(url) || _pending.contains(url)) {
      return;
    }
    _pending.add(url);
    try {
      final controller =
          VideoPlayerController.networkUrl(Uri.parse(playableVideoUrl(url)));
      await controller.initialize();
      // Mute and pause the preloaded controller - the screen that later
      // claims it decides playback/volume/speed once it's actually shown.
      await controller.setVolume(0);
      _ready[url] = controller;
    } catch (_) {
      // Ignore preload failures; the real _initializeVideo() call will
      // just create its own controller normally when the page is reached.
    } finally {
      _pending.remove(url);
    }
  }

  /// Takes ownership of a preloaded controller for [url], if one is ready.
  /// Removes it from the cache (the caller is now responsible for playing
  /// and eventually disposing it) so it's never double-used or evicted out
  /// from under an active player.
  static VideoPlayerController? claim(String url) {
    return _ready.remove(url);
  }

  /// Disposes any preloaded-but-unclaimed controllers whose url isn't in
  /// [keepUrls] - called after each page change so the cache never grows
  /// beyond what's actually near the user's current position.
  static void evictExcept(Set<String> keepUrls) {
    final List<String> staleUrls =
        _ready.keys.where((u) => !keepUrls.contains(u)).toList();
    for (final url in staleUrls) {
      _ready.remove(url)?.dispose();
    }
  }
}

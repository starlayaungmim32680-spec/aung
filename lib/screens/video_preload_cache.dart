import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../network_service.dart';
import 'data_saver_hls.dart';

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
//   - call `await VideoPreloadCache.claimWhenReady(widget.videoUrl)` first;
//     if it returns a controller, it's already initialized and ready to
//     play immediately. Otherwise fall back to creating+initializing a
//     fresh controller as before.
//
// 20 Nov 2026 ("Instant Start"): a preload that is still IN FLIGHT can now
// be waited for (claimWhenReady) - before, a video whose preload had not
// finished yet started a second, separate download from zero. Also, a
// preload dropped by evictExcept while still loading is disposed as soon
// as it finishes instead of lingering, and a failed preload's controller
// is disposed (it used to leak).
class VideoPreloadCache {
  static final Map<String, VideoPlayerController> _ready = {};
  static final Map<String, Future<VideoPlayerController?>> _pending = {};
  // In-flight preloads nobody wants any more (see evictExcept).
  static final Set<String> _dropped = {};

  /// Starts initializing [url] in the background if it isn't already
  /// cached or in progress. Safe to call repeatedly - it's a no-op once
  /// a preload for this url is already underway or done.
  ///
  /// 23 Nov 2026 (S4 "data saver"): [extra] = a nice-to-have neighbour
  /// (the one AFTER the next, or the previous one). On mobile data those
  /// are skipped - only the very next video is fetched ahead.
  static Future<void> preload(String url, {bool extra = false}) async {
    if (extra && NetworkService.instance.isOnMobileData) return;
    if (url.isEmpty || _ready.containsKey(url)) return;
    if (_pending.containsKey(url)) {
      // Wanted again while loading: keep it.
      _dropped.remove(url);
      return;
    }
    _dropped.remove(url);
    final Completer<VideoPlayerController?> done =
        Completer<VideoPlayerController?>();
    _pending[url] = done.future;
    VideoPlayerController? controller;
    try {
      // S4: 480p-capped local playlist on mobile data (data_saver_hls.dart).
      controller = await DataSaverHls.controllerFor(url);
      // Without a timeout, a lost connection would leave this url stuck in
      // _pending forever - the preload guard at the top of this function
      // would then skip it on every future call, so it could never be
      // retried even after the connection came back.
      await controller.initialize().timeout(const Duration(seconds: 12));
      // Mute and pause the preloaded controller - the screen that later
      // claims it decides playback/volume/speed once it's actually shown.
      await controller.setVolume(0);
      if (_dropped.remove(url)) {
        controller.dispose();
        done.complete(null);
      } else {
        _ready[url] = controller;
        done.complete(controller);
      }
    } catch (_) {
      // Ignore preload failures; the real _initializeVideo() call will
      // just create its own controller normally when the page is reached.
      controller?.dispose();
      _dropped.remove(url);
      if (!done.isCompleted) done.complete(null);
    } finally {
      _pending.remove(url);
    }
  }

  /// Hands an already-initialized, playing controller to the cache so the
  /// next screen that shows [url] can [claim] it and continue seamlessly
  /// (used when a Home video is opened full-screen). Ownership moves to
  /// the cache / the claimer; the giver must not use or dispose it.
  static void adopt(String url, VideoPlayerController controller) {
    final VideoPlayerController? old = _ready[url];
    if (old != null && !identical(old, controller)) old.dispose();
    _ready[url] = controller;
  }

  /// Takes ownership of a preloaded controller for [url], if one is ready.
  /// Removes it from the cache (the caller is now responsible for playing
  /// and eventually disposing it) so it's never double-used or evicted out
  /// from under an active player.
  static VideoPlayerController? claim(String url) {
    return _ready.remove(url);
  }

  /// Like [claim], but if a preload of [url] is still loading, waits for
  /// it (instead of starting a second download from zero) and takes it.
  /// Returns null when there is no preload or it failed.
  static Future<VideoPlayerController?> claimWhenReady(String url) async {
    final VideoPlayerController? ready = _ready.remove(url);
    if (ready != null) return ready;
    final Future<VideoPlayerController?>? loading = _pending[url];
    if (loading == null) return null;
    _dropped.remove(url);
    final VideoPlayerController? c = await loading;
    if (c == null) return null;
    return _ready.remove(url);
  }

  /// Throws away the preload of [url] (now, or when it finishes loading).
  static void drop(String url) {
    _ready.remove(url)?.dispose();
    if (_pending.containsKey(url)) _dropped.add(url);
  }

  /// Disposes any preloaded-but-unclaimed controllers whose url isn't in
  /// [keepUrls] - called after each page change so the cache never grows
  /// beyond what's actually near the user's current position. Preloads
  /// still loading are marked and disposed when they finish.
  static void evictExcept(Set<String> keepUrls) {
    final List<String> staleUrls =
        _ready.keys.where((u) => !keepUrls.contains(u)).toList();
    for (final url in staleUrls) {
      _ready.remove(url)?.dispose();
    }
    for (final url in _pending.keys) {
      if (!keepUrls.contains(url)) _dropped.add(url);
    }
  }
}

// 20 Nov 2026 - "Instant Start": the video at the top of Home when the app
// was last used is remembered, and on the next launch main() starts
// loading it at once - in parallel with Firebase, sign-in and reading the
// feed - instead of only after all of that. When it is still the first
// video (no newer post), it is ready the moment Home appears.
class LaunchVideo {
  LaunchVideo._();

  static const String _key = 'launchVideoUrl';
  static String? _saved;
  static String? _warmed; // the url warmUp() started loading
  static bool _settled = false;

  /// Called first thing in main(); never waits, never throws.
  static void warmUp() {
    SharedPreferences.getInstance().then((p) {
      final String? url = p.getString(_key);
      _saved = url;
      if (url != null && url.isNotEmpty) {
        _warmed = url;
        VideoPreloadCache.preload(url);
      }
    }).catchError((Object _) {});
  }

  /// The video warmUp() started loading (Fly Mix puts it first).
  static String? get warmedUrl => _warmed;

  /// Once Home knows its first videos: if the warmed-up video is not among
  /// them (newer posts came in), free it instead of keeping it loaded.
  static void settle(Set<String> topUrls) {
    if (_settled) return;
    _settled = true;
    final String? url = _warmed;
    if (url != null && !topUrls.contains(url)) VideoPreloadCache.drop(url);
  }

  /// Home's first video right now - remembered for the next launch.
  static void remember(String url) {
    if (url.isEmpty || url == _saved) return;
    _saved = url;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_key, url))
        .catchError((Object _) => false);
  }
}

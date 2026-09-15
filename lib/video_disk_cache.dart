import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// Persists a copy of each watched video to the device's own storage, so a
// video the person already watched once can be replayed later - even with
// no connection at all - instead of only ever streaming from Cloudinary.
// This is separate from VideoPreloadCache (video_preload_cache.dart),
// which only holds the next couple of videos in memory for a moment to
// make swiping feel instant; this cache is about videos already watched,
// kept on disk, surviving across app restarts.
//
// Built on flutter_cache_manager (already pulled in transitively by
// cached_network_image) rather than anything custom, since disk eviction,
// concurrent-download de-duplication, and cache bookkeeping are exactly
// what it already handles.
class VideoDiskCache {
  VideoDiskCache._();

  static final CacheManager instance = CacheManager(
    Config(
      'flyRecentlyWatchedVideos',
      // A video not watched again in a week falls out of cache on its own
      // - "recently watched", not "every video ever seen".
      stalePeriod: const Duration(days: 7),
      // Caps how many videos sit on disk at once (oldest evicted first)
      // rather than a byte size, since that's what flutter_cache_manager
      // exposes directly - a reasonable ceiling for short vertical clips
      // without needing to inspect file sizes.
      maxNrOfCacheObjects: 60,
    ),
  );
}

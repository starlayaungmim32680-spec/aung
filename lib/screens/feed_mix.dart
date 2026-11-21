// 21 Nov 2026 - "Fly Mix": the order of Home's For You feed.
//
// Ko: every time the app opened, the newest upload was always first and
// the feed never changed ("the videos don't go round"). Before, For You
// was simply newest -> oldest. Now each app start ranks the latest 100
// videos by a score:
//   + 100  pinned: my own upload from the last 15 minutes, or the video
//          the last session picked and preloaded (Instant Start)
//   +   3  I have NOT watched it yet (WatchedVideos, kept on the phone)
//   + 0..2.2  freshness - newer is higher, fading over a day or two
//   + a little for likes and views (log scale, so big numbers don't win
//          everything)
//   + 0..1.4  a random mix that is different every app start
// then the same creator is kept from appearing twice in a row when
// possible. The order is decided once per app run (home_screen.dart
// _mixed), so nothing jumps while scrolling. Following stays newest first.

import 'dart:math';

class FeedMix {
  FeedMix._();

  static const double pinBonus = 100;

  // A new random mix for every app start.
  static final int _seed = Random().nextInt(1 << 30);

  static double _jitter(String key) {
    int h = _seed;
    for (final int c in key.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
    return (h % 10000) / 10000;
  }

  static double score({
    required String key,
    required double ageHours,
    required int reactions,
    required int views,
    required bool watched,
    required bool pinned,
  }) {
    double s = pinned ? pinBonus : 0;
    if (!watched) s += 3;
    s += 2.2 * exp(-max(0.0, ageHours) / 36);
    s += 0.6 * log(1 + max(0, reactions)) + 0.3 * log(1 + max(0, views));
    s += 1.4 * _jitter(key);
    return s;
  }

  /// Keeps the ranked order, but avoids the same creator twice in a row
  /// by pulling the next different creator (up to 6 places) forward.
  static List<T> spreadCreators<T>(
      List<T> ranked, String Function(T) creatorOf) {
    final List<T> pool = List<T>.of(ranked);
    final List<T> out = [];
    while (pool.isNotEmpty) {
      int pick = 0;
      if (out.isNotEmpty) {
        final String last = creatorOf(out.last);
        for (int i = 0; i < pool.length && i < 6; i++) {
          if (creatorOf(pool[i]) != last) {
            pick = i;
            break;
          }
        }
      }
      out.add(pool.removeAt(pick));
    }
    return out;
  }
}

// 21 Nov 2026 - Scale plan 2, step S1: feeds load in PAGES, once.
//
// Before, Home / For You and the video-from-profile screen LISTENED live
// (.snapshots()) to the newest 100 posts. Every like / view / comment
// count change on any of those 100 posts then cost one read on EVERY open
// phone - the cost grows with (views x people online).
//
// Now a feed asks for [pageSize] posts with one .get(), and asks for the
// next page (startAfterDocument) when the person gets near the end - like
// TikTok's "give me the next 10". Live numbers (likes, views) still come
// from the ONE video on screen: _VideoPostItem listens to its own post doc.
//
// [docs] only grows while paging; [refresh] starts over from the newest.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class FeedPager {
  FeedPager(this.query, {this.pageSize = 20, this.startAfter});

  /// The query WITHOUT limit / cursor (orderBy must be set).
  final Query<Map<String, dynamic>> query;
  final int pageSize;

  /// Optional first cursor: the list starts right after this doc (used by
  /// SingleVideoScreen to continue after the tapped video).
  final DocumentSnapshot? startAfter;

  /// Everything loaded so far, in query order, no duplicates.
  final ValueNotifier<List<QueryDocumentSnapshot<Map<String, dynamic>>>> docs =
      ValueNotifier(const []);

  /// Becomes true when the first page has answered (data OR error).
  final ValueNotifier<bool> loaded = ValueNotifier<bool>(false);

  /// The last error (null when the last load worked).
  Object? error;

  bool _loading = false;
  bool _hasMore = true;
  DocumentSnapshot? _last;
  int _generation = 0;
  bool _disposed = false;

  bool get hasMore => _hasMore;
  bool get isLoading => _loading;

  /// Loads the first page again (pull-to-refresh). The old list stays on
  /// screen until the new page arrives.
  Future<void> refresh() {
    _generation++;
    _last = null;
    _hasMore = true;
    _loading = false;
    return _load(reset: true);
  }

  /// Loads the next page, if there is one and nothing is loading.
  Future<void> loadMore() {
    if (_loading || !_hasMore || _disposed) return Future.value();
    return _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    final int gen = _generation;
    _loading = true;
    try {
      Query<Map<String, dynamic>> q = query.limit(pageSize);
      final DocumentSnapshot? cursor =
          reset ? startAfter : (_last ?? startAfter);
      if (cursor != null) q = q.startAfterDocument(cursor);
      final QuerySnapshot<Map<String, dynamic>> snap = await q.get();
      if (_disposed || gen != _generation) return;
      error = null;
      if (snap.docs.isNotEmpty) _last = snap.docs.last;
      _hasMore = snap.docs.length == pageSize;
      final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId = {
        if (!reset)
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d
              in docs.value)
            d.id: d,
      };
      for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs) {
        byId[d.id] = d;
      }
      docs.value = byId.values.toList();
    } catch (e) {
      if (_disposed || gen != _generation) return;
      error = e;
      debugPrint('FeedPager: load failed ($e)');
    } finally {
      if (!_disposed && gen == _generation) {
        _loading = false;
        loaded.value = true;
      }
    }
  }

  void dispose() {
    _disposed = true;
    docs.dispose();
    loaded.dispose();
  }
}

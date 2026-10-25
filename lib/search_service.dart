// Search (4 Oct 2026) - Fly's search runs on Cloudflare D1 behind the
// Worker, not on the phone any more.
//
//   App -> Worker POST /search {q} -> D1 (SQLite FTS5) -> IDs (max 20 each)
//       -> App reads ONLY those docs from Firestore -> shows them.
//
// Firestore stays the source of truth: anything deleted, blocked, failed
// or not yet encoded that is still in D1 simply doesn't come back / gets
// filtered here, so search can never show something it shouldn't. Before,
// every search downloaded 200 users + 300 posts and filtered on the phone.
//
// Keeping D1 up to date:
//   - users: syncMe() on every app start (MainNavigationScreen) - the Worker
//     reads my users/{uid} doc itself and only writes when the name changed;
//   - posts: indexed at once by indexPost() right after posting
//     (/search-index-post, 19 Oct 2026); the Bunny webhook also indexes a
//     post when its video becomes ready (a safety net);
//   - old data: the one-time /search-backfill page (see the Worker).
//
// Trending on Fly (4 Oct 2026): logSearch() tells the Worker (/search-log)
// when someone REALLY searches (presses search, taps a recent/trending
// item, opens a video from results) - never on each typed letter. The
// Worker counts each word once per person per day, only if it finds a
// video. loadTrending() fills [trending] with the top words of the last 7
// days that different people searched (/search-trending, cached 10 min on
// the Worker and here; the phone's last copy shows instantly).
import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'block_service.dart';
import 'screens/video_call_screen.dart' show kTokenServerUrl;
import 'screens/video_upload_service.dart' show isVideoVisibleTo;
import 'screens/worker_auth.dart';

class SearchResults {
  final List<DocumentSnapshot<Map<String, dynamic>>> users;
  final List<DocumentSnapshot<Map<String, dynamic>>> posts;
  const SearchResults({required this.users, required this.posts});

  bool get isEmpty => users.isEmpty && posts.isEmpty;
}

class SearchException implements Exception {
  final String message;
  const SearchException(this.message);
  @override
  String toString() => message;
}

class SearchService {
  SearchService._();

  static bool _syncedThisRun = false;

  /// Keeps my name in search up to date. Once per app run, best-effort.
  static Future<void> syncMe() async {
    if (_syncedThisRun) return;
    _syncedThisRun = true;
    try {
      await http
          .post(
            Uri.parse('$kTokenServerUrl/search-sync-me'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Try again next time the app starts.
      _syncedThisRun = false;
    }
  }

  /// Makes my brand-new post searchable at once (19 Oct 2026) instead of
  /// waiting for Bunny's webhook. Best-effort, one retry; the webhook
  /// indexes it later anyway if this fails.
  static Future<void> indexPost(String postId) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await http
            .post(
              Uri.parse('$kTokenServerUrl/search-index-post'),
              headers: {
                ...await workerAuthHeaders(),
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'postId': postId}),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) return;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  // Words already sent this app run (the Worker ignores repeats anyway -
  // this just saves requests).
  static final Set<String> _logged = <String>{};

  /// Counts [query] towards Trending. Fire-and-forget, best-effort.
  static Future<void> logSearch(String query) async {
    final String q = query.trim().toLowerCase();
    if (q.length < 2 || q.length > 60 || !_logged.add(q)) return;
    try {
      await http
          .post(
            Uri.parse('$kTokenServerUrl/search-log'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'q': q}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      _logged.remove(q); // Try again next time it's searched.
    }
  }

  static const String _trendingPrefsKey = 'fly_trending_searches';
  static const Duration _trendingFresh = Duration(minutes: 10);
  static DateTime? _trendingAt;

  /// Top searched words on Fly (max 8). Listen with ValueListenableBuilder.
  static final ValueNotifier<List<String>> trending =
      ValueNotifier(const <String>[]);

  /// Shows the phone's last copy at once, then refreshes from the Worker
  /// (at most every 10 minutes). Call when Search opens.
  static Future<void> loadTrending() async {
    if (trending.value.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getStringList(_trendingPrefsKey);
        if (saved != null && trending.value.isEmpty) {
          trending.value = List.unmodifiable(saved);
        }
      } catch (_) {}
    }
    final DateTime now = DateTime.now();
    if (_trendingAt != null && now.difference(_trendingAt!) < _trendingFresh) {
      return;
    }
    _trendingAt = now;
    try {
      final res = await http
          .post(
            Uri.parse('$kTokenServerUrl/search-trending'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('trending ${res.statusCode}');
      final Map<String, dynamic> body = jsonDecode(res.body);
      final List<String> terms = ((body['terms'] as List?) ?? const [])
          .whereType<String>()
          .where((t) => t.trim().isNotEmpty)
          .take(8)
          .toList();
      if (!listEquals(terms, trending.value)) {
        trending.value = List.unmodifiable(terms);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_trendingPrefsKey, terms);
    } catch (_) {
      _trendingAt = null; // Offline - keep the old list, retry next time.
    }
  }

  /// Accounts + videos matching [query]. Throws [SearchException] with a
  /// friendly message when the Worker can't be reached.
  static Future<SearchResults> search(String query) async {
    final String q = query.trim();
    if (q.isEmpty) return const SearchResults(users: [], posts: []);

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$kTokenServerUrl/search'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'q': q}),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const SearchException('Search is taking too long. Try again.');
    } catch (_) {
      throw const SearchException(
          "Couldn't reach search. Check your connection.");
    }
    if (res.statusCode != 200) {
      throw const SearchException('Search is busy right now. Try again.');
    }

    final Map<String, dynamic> body = jsonDecode(res.body);
    final List<String> userIds =
        ((body['users'] as List?) ?? const []).cast<String>();
    final List<String> postIds =
        ((body['posts'] as List?) ?? const []).cast<String>();

    final db = FirebaseFirestore.instance;
    final results = await Future.wait([
      _fetchInOrder(db.collection('users'), userIds),
      // Only Everyone posts are searchable; the audience constraint also
      // lets the Firestore rules accept this query (25 Oct 2026, step C).
      _fetchInOrder(db.collection('posts'), postIds, everyoneOnly: true),
    ]);

    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    final users = results[0]
        .where((d) => d.id != myId && !BlockService.instance.isHidden(d.id))
        .toList();
    final posts = results[1].where((d) {
      final data = d.data() ?? const {};
      final String owner = (data['userId'] as String?) ?? '';
      if (BlockService.instance.isHidden(owner)) return false;
      // Same rule as the Home feed (Early-Play, 16-18 Oct 2026): a video
      // is visible as soon as it is posted; only a failed encode is hidden
      // (except from its uploader).
      return isVideoVisibleTo(data, myId);
    }).toList();
    return SearchResults(users: users, posts: posts);
  }

  // Reads [ids] (max 30 - Firestore's whereIn limit) and returns them in
  // the same order D1 ranked them. Missing (deleted) docs are skipped.
  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> _fetchInOrder(
    CollectionReference<Map<String, dynamic>> col,
    List<String> ids, {
    bool everyoneOnly = false,
  }) async {
    if (ids.isEmpty) return const [];
    final List<String> wanted = ids.take(30).toList();
    Query<Map<String, dynamic>> q =
        col.where(FieldPath.documentId, whereIn: wanted);
    if (everyoneOnly) q = q.where('audience', isEqualTo: 'everyone');
    final snap = await q.get();
    final byId = {for (final d in snap.docs) d.id: d};
    return [
      for (final id in wanted)
        if (byId[id] != null) byId[id]!,
    ];
  }
}

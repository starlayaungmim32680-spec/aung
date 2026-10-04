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
//   - posts: the Worker's Bunny webhook indexes a post when its video
//     becomes ready;
//   - old data: the one-time /search-backfill page (see the Worker).
import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'block_service.dart';
import 'screens/video_call_screen.dart' show kTokenServerUrl;
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
      _fetchInOrder(db.collection('posts'), postIds),
    ]);

    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    final users = results[0]
        .where((d) => d.id != myId && !BlockService.instance.isHidden(d.id))
        .toList();
    final posts = results[1].where((d) {
      final data = d.data() ?? const {};
      final String owner = (data['userId'] as String?) ?? '';
      if (BlockService.instance.isHidden(owner)) return false;
      if (data['videoFailed'] == true) return false;
      // Others only see a video once it's encoded (old posts have no
      // flag and count as ready) - same rule as the Home feed.
      if (data['videoReady'] == false && owner != myId) return false;
      return true;
    }).toList();
    return SearchResults(users: users, posts: posts);
  }

  // Reads [ids] (max 30 - Firestore's whereIn limit) and returns them in
  // the same order D1 ranked them. Missing (deleted) docs are skipped.
  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> _fetchInOrder(
    CollectionReference<Map<String, dynamic>> col,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final List<String> wanted = ids.take(30).toList();
    final snap = await col.where(FieldPath.documentId, whereIn: wanted).get();
    final byId = {for (final d in snap.docs) d.id: d};
    return [
      for (final id in wanted)
        if (byId[id] != null) byId[id]!,
    ];
  }
}

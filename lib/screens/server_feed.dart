// 25 Nov 2026 - Scale plan 2, step S2: the For You list made on the server.
//
// Before (S1, feed_pager.dart) EVERY phone read the newest 30 posts + 10
// reposts from Firestore on every app start and ranked them itself - the
// same docs read again and again by everyone.
//
// Now the Worker (cloudflare/livekit_token_worker.js, "For You feed, made
// on the server") reads Firestore once every 5 minutes, ranks ~200
// Everyone videos (fresh + liked + viewed) and keeps that list in
// Cloudflare KV. This class asks for it with ONE call to POST /feed - 0
// Firestore reads. Home still does the personal part on the phone (Fly
// Mix: unwatched first, its own random mix, blocked / reported left out)
// and still adds my circle's posts (circle_posts.dart, live).
//
// If the call fails (no internet, Worker without the FEED_KV binding,
// empty list) [failed] is true and Home falls back to the old Firestore
// pages - the feed never stays empty because of this.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'video_call_screen.dart' show kTokenServerUrl;
import 'worker_auth.dart';

/// One video of the server list: an Everyone post or a repost. [data] has
/// the same field names as the Firestore doc (only the ones Home needs);
/// createdAt comes separately as [createdAt].
class ServerFeedItem {
  final bool isRepost;

  /// The post id, or for a repost the repost doc id.
  final String id;
  final DateTime createdAt;
  final Map<String, dynamic> data;

  const ServerFeedItem._(this.isRepost, this.id, this.createdAt, this.data);

  /// The post this item plays (for a repost: the original post).
  String get postId =>
      isRepost ? (data['originalPostId'] as String? ?? '') : id;

  static ServerFeedItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['id'];
    final Object? data = json['data'];
    if (id is! String || id.isEmpty || data is! Map) return null;
    final int ms = (json['createdAtMs'] as num?)?.toInt() ?? 0;
    return ServerFeedItem._(
      json['kind'] == 'repost',
      id,
      ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : DateTime.now(),
      Map<String, dynamic>.from(data),
    );
  }
}

class ServerFeed {
  /// The list, best first (the Worker's order). Replaced on [refresh].
  final ValueNotifier<List<ServerFeedItem>> items =
      ValueNotifier<List<ServerFeedItem>>(const []);

  /// True once the first answer (or failure) is in.
  final ValueNotifier<bool> loaded = ValueNotifier<bool>(false);

  /// True when there is no server list to show - Home then uses the
  /// Firestore pages instead. A failed pull-to-refresh keeps the old list.
  bool failed = false;

  int _generation = 0;
  bool _disposed = false;

  /// [fresh] (26 Nov 2026, pull-to-refresh): the Worker rebuilds the list
  /// first if it is over a minute old, so a video someone just posted is
  /// in it (before, the list could be up to 5 minutes behind).
  Future<void> refresh({bool fresh = false}) async {
    final int gen = ++_generation;
    try {
      final http.Response res = await http
          .post(
            Uri.parse('$kTokenServerUrl/feed'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'fresh': fresh}),
          )
          .timeout(Duration(seconds: fresh ? 20 : 10));
      if (_disposed || gen != _generation) return;
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final Object? decoded = jsonDecode(res.body);
      final Object? raw = decoded is Map ? decoded['items'] : null;
      if (raw is! List) throw const FormatException('no items');
      final List<ServerFeedItem> list = [];
      for (final Object? r in raw) {
        final ServerFeedItem? item = ServerFeedItem.fromJson(r);
        if (item != null) list.add(item);
      }
      if (list.isEmpty) throw StateError('empty list');
      failed = false;
      items.value = list;
    } catch (e) {
      if (_disposed || gen != _generation) return;
      failed = items.value.isEmpty;
      debugPrint('ServerFeed: refresh failed (fresh: $fresh, $e)');
    } finally {
      if (!_disposed && gen == _generation) loaded.value = true;
    }
  }

  void dispose() {
    _disposed = true;
    items.dispose();
    loaded.dispose();
  }
}

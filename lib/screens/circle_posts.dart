// "My circle" posts for the Home feed (25 Oct 2026, "Who can watch" step
// B2).
//
// Before B2 the Home feed downloaded EVERY post and filtered on the phone.
// Now Home asks for two things only:
//   1. Everyone posts, newest first, max kHomeFeedLimit (home_screen.dart);
//   2. this class: the posts only my circle can see -
//        - my own posts (any audience, so I see my private ones too);
//        - Followers & Friends / Friends posts of people I follow or am
//          friends with, 10 accounts per query
//          (where userId in [10] and audience in [followers, friends]).
// Home merges both lists (no duplicates) and still runs isVideoVisibleTo /
// canSeeAudience on each post, so e.g. a Friends-only post of someone I
// merely follow is still hidden.
//
// The queries are rebuilt only when my friends / following lists really
// change (FriendService / FollowingService). No orderBy, so no composite
// index is needed; Home sorts by createdAt itself.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../following_service.dart';
import '../friend_service.dart';

class CirclePostsFeed {
  /// The merged circle posts (unsorted). Starts empty.
  final ValueNotifier<List<QueryDocumentSnapshot>> docs =
      ValueNotifier<List<QueryDocumentSnapshot>>(const []);

  static const int _accountsPerQuery = 10;

  final Map<int, List<QueryDocumentSnapshot>> _parts = {};
  final List<StreamSubscription<QuerySnapshot>> _subs = [];
  Set<String> _ids = <String>{};
  String? _me;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started) return;
    _started = true;
    FriendService.instance.friends.addListener(_refresh);
    FollowingService.instance.following.addListener(_refresh);
    _refresh();
  }

  void _refresh() {
    if (_disposed) return;
    final String? me = FirebaseAuth.instance.currentUser?.uid;
    final Set<String> ids = {
      ...FriendService.instance.friends.value,
      ...FollowingService.instance.following.value,
    }..remove(me);
    if (me == _me && setEquals(ids, _ids)) return;
    _me = me;
    _ids = ids;

    for (final StreamSubscription<QuerySnapshot> s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _parts.clear();
    if (me == null) {
      docs.value = const [];
      return;
    }

    final CollectionReference<Map<String, dynamic>> posts =
        FirebaseFirestore.instance.collection('posts');
    int key = 0;
    // My own posts, whatever their audience.
    _listen(key++, posts.where('userId', isEqualTo: me));
    // Non-public posts of my friends and the accounts I follow.
    final List<String> list = ids.toList()..sort();
    for (int i = 0; i < list.length; i += _accountsPerQuery) {
      final List<String> chunk = list.sublist(
          i,
          i + _accountsPerQuery > list.length
              ? list.length
              : i + _accountsPerQuery);
      _listen(
        key++,
        posts
            .where('userId', whereIn: chunk)
            .where('audience', whereIn: const ['followers', 'friends']),
      );
    }
    _publish();
  }

  void _listen(int key, Query query) {
    _subs.add(query.snapshots().listen(
      (snap) {
        _parts[key] = snap.docs;
        _publish();
      },
      onError: (Object e) => debugPrint('circle posts: query $key failed ($e)'),
    ));
  }

  void _publish() {
    if (_disposed) return;
    final Map<String, QueryDocumentSnapshot> byId = {};
    for (final List<QueryDocumentSnapshot> part in _parts.values) {
      for (final QueryDocumentSnapshot d in part) {
        byId[d.id] = d;
      }
    }
    docs.value = byId.values.toList();
  }

  void dispose() {
    _disposed = true;
    FriendService.instance.friends.removeListener(_refresh);
    FollowingService.instance.following.removeListener(_refresh);
    for (final StreamSubscription<QuerySnapshot> s in _subs) {
      s.cancel();
    }
    _subs.clear();
    docs.dispose();
  }
}

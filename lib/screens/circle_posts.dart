// "My circle" posts for the Home feed (25 Oct 2026, "Who can watch" step
// B2).
//
// Before B2 the Home feed downloaded EVERY post and filtered on the phone.
// Now Home asks for two things only:
//   1. Everyone posts, newest first, max kHomeFeedLimit (home_screen.dart);
//   2. this class: the posts only my circle can see -
//        - my own posts (any audience, so I see my private ones too);
//        - non-public posts of people I'm friends with
//          (where userId in [4] and audience in [followers, friends]);
//        - Followers & Friends posts of people I only follow
//          (where userId in [4] and audience == followers).
//      25 Oct 2026 (step C): split this way because Firestore rules are
//      not filters - a query that could return a post I may not see is
//      refused as a whole - and kept to 4 accounts per query so the rules'
//      exists() checks stay under Firestore's limit of 10 per query.
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

  static const int _accountsPerQuery = 4;

  final Map<int, List<QueryDocumentSnapshot>> _parts = {};
  final List<StreamSubscription<QuerySnapshot>> _subs = [];
  Set<String> _ids = <String>{};
  Set<String> _friendSet = <String>{};
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
    final Set<String> friendSet = {...FriendService.instance.friends.value};
    // Rebuilt when who I follow OR who my friends are changes (a followed
    // account that becomes a friend needs the friends query).
    if (me == _me && setEquals(ids, _ids) && setEquals(friendSet, _friendSet)) {
      return;
    }
    _me = me;
    _ids = ids;
    _friendSet = friendSet;

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
    final List<String> friendIds = ids.where(friendSet.contains).toList()
      ..sort();
    final List<String> followOnlyIds =
        ids.where((id) => !friendSet.contains(id)).toList()..sort();
    // Non-public posts of my friends.
    for (final List<String> chunk in _chunks(friendIds)) {
      _listen(
        key++,
        posts
            .where('userId', whereIn: chunk)
            .where('audience', whereIn: const ['followers', 'friends']),
      );
    }
    // Followers & Friends posts of people I only follow.
    for (final List<String> chunk in _chunks(followOnlyIds)) {
      _listen(
        key++,
        posts
            .where('userId', whereIn: chunk)
            .where('audience', isEqualTo: 'followers'),
      );
    }
    _publish();
  }

  static List<List<String>> _chunks(List<String> ids) => [
        for (int i = 0; i < ids.length; i += _accountsPerQuery)
          ids.sublist(
              i,
              i + _accountsPerQuery > ids.length
                  ? ids.length
                  : i + _accountsPerQuery),
      ];

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

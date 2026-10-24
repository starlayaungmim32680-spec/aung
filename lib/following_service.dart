// Who I follow, app-wide (24 Oct 2026) - like FriendService, one live
// listener on users/{me}/following, started once in MainNavigationScreen.
//
// Used by post audiences (lib/screens/post_audience.dart): a
// "Followers & Friends" video is shown to me when I follow its owner (or
// we are friends). Screens that already keep their own following list
// (Home's Following tab) can keep it; this is the shared copy.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class FollowingService {
  FollowingService._();
  static final FollowingService instance = FollowingService._();

  /// uids of the accounts I follow.
  final ValueNotifier<Set<String>> following = ValueNotifier(<String>{});

  /// True once the list has arrived at least once.
  final ValueNotifier<bool> loaded = ValueNotifier(false);

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _sub;
  String? _uid;

  bool isFollowing(String? uid) =>
      uid != null && uid.isNotEmpty && following.value.contains(uid);

  /// Safe to call more than once.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onUser);
    _onUser(FirebaseAuth.instance.currentUser);
  }

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _sub?.cancel();
    if (following.value.isNotEmpty) following.value = <String>{};
    loaded.value = false;
    if (user == null) return;
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('following')
        .snapshots()
        .listen(
      (snap) {
        final Set<String> next = snap.docs.map((d) => d.id).toSet();
        if (!setEquals(next, following.value)) following.value = next;
        loaded.value = true;
      },
      onError: (_) {},
    );
  }
}

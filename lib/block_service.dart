// App-wide blocking (30 Sep 2026). Blocking works both ways, like
// Facebook/Messenger:
//   - the person who blocks never sees the blocked account again (posts,
//     reposts, stories, comments, chat list, search, notifications);
//   - the blocked person doesn't see the blocker either, and can't message
//     or call them.
//
// Firestore layout (both written together, in one batch, by the BLOCKER):
//   users/{me}/blocked/{them}     - my own block list (as before)
//   users/{them}/blockedBy/{me}   - a mirror, so the blocked person's app
//                                   knows to hide me too. Only they can read
//                                   it; only I can create/delete it.
// Firestore rules also refuse chat messages and calls between two people
// when either has blocked the other - so it holds even for an old app
// build or someone bypassing the UI.
//
// Blocking also ends a friendship and clears any pending friend request
// either way (4 Oct 2026, see friend_service.dart).
//
// Start once after login (main_navigation_screen.dart); screens read
// [hidden] (a ValueNotifier - listen to it, or use isHidden()).
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class BlockService {
  BlockService._();
  static final BlockService instance = BlockService._();

  /// People I blocked.
  final ValueNotifier<Set<String>> blockedByMe = ValueNotifier(<String>{});

  /// People who blocked me.
  final ValueNotifier<Set<String>> blockedMe = ValueNotifier(<String>{});

  /// Everyone to hide from me: both of the above together.
  final ValueNotifier<Set<String>> hidden = ValueNotifier(<String>{});

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _blockedSub;
  StreamSubscription<QuerySnapshot>? _blockedBySub;
  String? _uid;
  // Blocks made before the mirror existed get their blockedBy doc written
  // once per session (see _backfillMirrors).
  final Set<String> _mirrorChecked = {};

  bool isHidden(String? uid) =>
      uid != null && uid.isNotEmpty && hidden.value.contains(uid);

  /// Safe to call more than once.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onUser);
    _onUser(FirebaseAuth.instance.currentUser);
  }

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _blockedSub?.cancel();
    _blockedBySub?.cancel();
    _mirrorChecked.clear();
    blockedByMe.value = <String>{};
    blockedMe.value = <String>{};
    _updateHidden();
    if (user == null) return;

    final users = FirebaseFirestore.instance.collection('users');
    _blockedSub = users.doc(user.uid).collection('blocked').snapshots().listen(
      (snap) {
        blockedByMe.value = snap.docs.map((d) => d.id).toSet();
        _updateHidden();
        _backfillMirrors(user.uid, blockedByMe.value);
      },
      onError: (_) {},
    );
    _blockedBySub =
        users.doc(user.uid).collection('blockedBy').snapshots().listen(
      (snap) {
        blockedMe.value = snap.docs.map((d) => d.id).toSet();
        _updateHidden();
      },
      // Fails harmlessly until the new Firestore rules are published.
      onError: (_) {},
    );
  }

  // Only notify when the set really changed - every Firestore snapshot used
  // to hand out a new Set, which rebuilt every listening screen for nothing.
  void _updateHidden() {
    final Set<String> next = {...blockedByMe.value, ...blockedMe.value};
    if (setEquals(next, hidden.value)) return;
    hidden.value = next;
  }

  void _backfillMirrors(String myId, Set<String> ids) {
    for (final String other in ids) {
      if (!_mirrorChecked.add(other)) continue;
      FirebaseFirestore.instance
          .collection('users')
          .doc(other)
          .collection('blockedBy')
          .doc(myId)
          .set({'createdAt': FieldValue.serverTimestamp()}).catchError((_) {});
    }
  }

  /// Blocks [other]: both docs in one batch, I stop following them, and
  /// any friendship / friend request between us is removed.
  Future<void> block(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty || other == myId) return;
    final users = FirebaseFirestore.instance.collection('users');
    final batch = FirebaseFirestore.instance.batch();
    batch.set(users.doc(myId).collection('blocked').doc(other),
        {'createdAt': FieldValue.serverTimestamp()});
    batch.set(users.doc(other).collection('blockedBy').doc(myId),
        {'createdAt': FieldValue.serverTimestamp()});
    // My side of the follow link (the rules only let me remove my own).
    batch.delete(users.doc(myId).collection('following').doc(other));
    batch.delete(users.doc(other).collection('followers').doc(myId));
    // Friends + pending requests, both ways (friend_service.dart).
    batch.delete(users.doc(myId).collection('friends').doc(other));
    batch.delete(users.doc(other).collection('friends').doc(myId));
    batch.delete(users.doc(myId).collection('friendRequests').doc(other));
    batch.delete(users.doc(other).collection('friendRequests').doc(myId));
    await batch.commit();
    _mirrorChecked.add(other);
  }

  /// Unblocks [other]: removes both docs.
  Future<void> unblock(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty) return;
    final users = FirebaseFirestore.instance.collection('users');
    final batch = FirebaseFirestore.instance.batch();
    batch.delete(users.doc(myId).collection('blocked').doc(other));
    batch.delete(users.doc(other).collection('blockedBy').doc(myId));
    await batch.commit();
    _mirrorChecked.remove(other);
  }
}

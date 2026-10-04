// Friends (4 Oct 2026) - separate from Followers, like Facebook:
//   - Follow  = see someone's videos. One-sided, no approval needed.
//   - Friends = both people agreed. Needed to chat and call (enforced in a
//               later step, in the UI and in the Firestore rules).
//
// Firestore layout:
//   users/{to}/friendRequests/{from}  - a pending request, written by the
//                                       SENDER. Both people can read it;
//                                       either one can delete it (cancel /
//                                       decline).
//   users/{a}/friends/{b} and
//   users/{b}/friends/{a}             - written together, in one batch, by
//                                       the person who ACCEPTS. The rules
//                                       only allow that while the request
//                                       still exists. Either friend can
//                                       remove both (unfriend).
//
// Blocking someone also removes the friendship and any pending request
// (block_service.dart). The rules refuse a new request between two people
// when either has blocked the other.
//
// Since step 3 (4 Oct 2026) only FRIENDS can message or call each other -
// in the UI (chat_screen.dart, public_profile_screen.dart, story replies)
// and in the Firestore rules (areFriends()).
//
// Start it with FriendService.instance.start() - safe to call many times
// (the profile button, Messages, chat threads and the story viewer do).
// Screens read [friends] / [incoming] / [loaded] (ValueNotifiers - listen
// to them, or use isFriend()/hasIncoming()).
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Where I stand with another person.
enum FriendStatus {
  /// Not friends, no request either way.
  none,

  /// I sent them a request; waiting for them.
  requested,

  /// They sent me a request; waiting for me.
  incoming,

  /// We're friends.
  friends,
}

class FriendService {
  FriendService._();
  static final FriendService instance = FriendService._();

  /// My friends' uids.
  final ValueNotifier<Set<String>> friends = ValueNotifier(<String>{});

  /// uids of people who sent ME a friend request.
  final ValueNotifier<Set<String>> incoming = ValueNotifier(<String>{});

  /// True once my friends list has arrived at least once (from the cache
  /// or the server) - until then an empty [friends] set means "not known
  /// yet", not "no friends", so screens shouldn't show "not friends" UI.
  final ValueNotifier<bool> loaded = ValueNotifier(false);

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _friendsSub;
  StreamSubscription<QuerySnapshot>? _incomingSub;
  String? _uid;

  bool isFriend(String? uid) =>
      uid != null && uid.isNotEmpty && friends.value.contains(uid);

  bool hasIncoming(String? uid) =>
      uid != null && uid.isNotEmpty && incoming.value.contains(uid);

  CollectionReference<Map<String, dynamic>> get _users =>
      FirebaseFirestore.instance.collection('users');

  /// Safe to call more than once.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onUser);
    _onUser(FirebaseAuth.instance.currentUser);
  }

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _friendsSub?.cancel();
    _incomingSub?.cancel();
    _setIfChanged(friends, <String>{});
    _setIfChanged(incoming, <String>{});
    loaded.value = false;
    if (user == null) return;

    _friendsSub = _users.doc(user.uid).collection('friends').snapshots().listen(
      (snap) {
        _setIfChanged(friends, snap.docs.map((d) => d.id).toSet());
        loaded.value = true;
      },
      // Fails harmlessly until the new Firestore rules are published.
      onError: (_) {},
    );
    _incomingSub =
        _users.doc(user.uid).collection('friendRequests').snapshots().listen(
              (snap) =>
                  _setIfChanged(incoming, snap.docs.map((d) => d.id).toSet()),
              onError: (_) {},
            );
  }

  // Only notify when the set really changed, so listening screens don't
  // rebuild on every snapshot.
  void _setIfChanged(ValueNotifier<Set<String>> n, Set<String> next) {
    if (setEquals(next, n.value)) return;
    n.value = next;
  }

  /// My OWN request to [other] (lives under their doc), as a live stream -
  /// used by the profile button to show "Requested".
  Stream<bool> watchSentRequest(String other) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty) return Stream.value(false);
    return _users
        .doc(other)
        .collection('friendRequests')
        .doc(myId)
        .snapshots()
        .map((d) => d.exists)
        .handleError((_) {});
  }

  /// Sends a friend request to [other] + an in-app notification.
  Future<void> sendRequest(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty || other == myId) return;
    // They already asked me - just accept instead of crossing requests.
    if (hasIncoming(other)) {
      await accept(other);
      return;
    }
    await _users.doc(other).collection('friendRequests').doc(myId).set({
      'createdAt': FieldValue.serverTimestamp(),
    });
    _notify(other, 'friend_request');
  }

  /// Takes back my pending request to [other].
  Future<void> cancelRequest(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty) return;
    await _users.doc(other).collection('friendRequests').doc(myId).delete();
  }

  /// Accepts [other]'s request: both friend docs in one batch, and both
  /// request docs (theirs, and mine if we crossed) are cleared.
  Future<void> accept(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty || other == myId) return;
    final batch = FirebaseFirestore.instance.batch();
    final data = {'createdAt': FieldValue.serverTimestamp()};
    batch.set(_users.doc(myId).collection('friends').doc(other), data);
    batch.set(_users.doc(other).collection('friends').doc(myId), data);
    batch.delete(_users.doc(myId).collection('friendRequests').doc(other));
    batch.delete(_users.doc(other).collection('friendRequests').doc(myId));
    await batch.commit();
    _notify(other, 'friend_accept');
  }

  /// Declines [other]'s request (they aren't told).
  Future<void> decline(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty) return;
    await _users.doc(myId).collection('friendRequests').doc(other).delete();
  }

  /// Ends the friendship on both sides.
  Future<void> unfriend(String other) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || other.isEmpty) return;
    final batch = FirebaseFirestore.instance.batch();
    batch.delete(_users.doc(myId).collection('friends').doc(other));
    batch.delete(_users.doc(other).collection('friends').doc(myId));
    await batch.commit();
  }

  // Best-effort in-app notification (notifications_screen.dart shows
  // 'friend_request' and 'friend_accept'). A failure never undoes the
  // friend action itself.
  Future<void> _notify(String to, String type) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    try {
      final me = (await _users.doc(myId).get()).data();
      final String myName =
          (me?['displayName'] as String?)?.trim().isNotEmpty == true
              ? me!['displayName']
              : 'Someone';
      await _users.doc(to).collection('notifications').add({
        'type': type,
        'text': '',
        'fromId': myId,
        'fromName': myName,
        'fromPhoto': (me?['photoUrl'] as String?) ?? '',
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }
}

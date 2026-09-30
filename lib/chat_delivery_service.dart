// Messenger-style "Delivered" ticks (1 Oct 2026).
//
// A message is "Delivered" once it has actually reached the other person's
// phone - i.e. their Fly app is running (foreground, or still alive in the
// background) and has received it from Firestore. If their internet is off
// (or the app is fully closed) it stays "Sent" until the app gets it.
//
// How: this service listens to my `chats` docs (the same query the chat
// list uses). Whenever a chat's last message is from the other person, it
// fetches that chat's messages from them that I haven't seen yet and marks
// them `delivered: true`. Only messages really present on this phone get
// marked, so it can't claim a delivery that didn't happen.
//
// Firestore rules let the receiver change only `seen` / `delivered` (and
// their own reaction). Start once after login (main_navigation_screen.dart).
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatDeliveryService {
  ChatDeliveryService._();
  static final ChatDeliveryService instance = ChatDeliveryService._();

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _chatsSub;
  String? _uid;

  // chatId -> the lastMessageAt already handled, so each new message is
  // processed once instead of on every chat-list update.
  final Map<String, Timestamp> _handled = {};

  /// Safe to call more than once.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onUser);
    _onUser(FirebaseAuth.instance.currentUser);
  }

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _chatsSub?.cancel();
    _chatsSub = null;
    _handled.clear();
    if (user == null) return;

    final String myId = user.uid;
    _chatsSub = FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: myId)
        .snapshots()
        .listen(
      (snap) {
        for (final doc in snap.docs) {
          final data = doc.data();
          final String? lastSender = data['lastSenderId'] as String?;
          if (lastSender == null || lastSender == myId) continue;
          final Timestamp? at = data['lastMessageAt'] as Timestamp?;
          if (at == null || _handled[doc.id] == at) continue;
          _handled[doc.id] = at;
          _markDelivered(doc.id, myId);
        }
      },
      onError: (_) {},
    );
  }

  Future<void> _markDelivered(String chatId, String myId) async {
    final List<String> ids = chatId.split('_');
    if (ids.length != 2 || !ids.contains(myId)) return;
    final String other = ids[0] == myId ? ids[1] : ids[0];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .where('senderId', isEqualTo: other)
          .where('seen', isEqualTo: false)
          .limit(100)
          .get();
      final batch = FirebaseFirestore.instance.batch();
      int count = 0;
      for (final doc in snap.docs) {
        if (doc.data()['delivered'] == true) continue;
        batch.update(doc.reference, {'delivered': true});
        count++;
      }
      if (count > 0) await batch.commit();
    } catch (_) {
      // Best effort - the next message (or opening the chat) retries.
    }
  }
}

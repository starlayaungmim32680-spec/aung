// Sends the incoming-call push that wakes the callee's phone even when
// Fly is backgrounded or fully closed - see notification_service.dart's
// firebaseMessagingBackgroundHandler for the receiving side. This is
// best-effort: if it fails, the call still rings normally for anyone
// with the app open, since that path relies on the Firestore listener
// in main_navigation_screen.dart, not this push.
//
// Also sends the matching "call cancelled" push (sendCallCancelledPush,
// below) that stops that ringing again if the caller hangs up first.
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'video_call_screen.dart' show kTokenServerUrl;
import 'worker_auth.dart';

Future<void> sendCallPush({
  required String calleeId,
  required String callerId,
  required String callerName,
  required String callerPhoto,
  required String roomName,
  required bool isVideo,
}) async {
  try {
    final calleeDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(calleeId)
        .get();
    final String? fcmToken = calleeDoc.data()?['fcmToken'] as String?;
    if (fcmToken == null || fcmToken.isEmpty) return;

    final Uri uri = Uri.parse('$kTokenServerUrl/call-push');
    await http.post(
      uri,
      headers: {
        ...await workerAuthHeaders(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'fcmToken': fcmToken,
        'callerId': callerId,
        'callerName': callerName,
        'callerPhoto': callerPhoto,
        'roomName': roomName,
        'isVideo': isVideo,
      }),
    );
  } catch (_) {
    // Best-effort, as noted above.
  }
}

// Tells the callee's phone to stop ringing because the caller hung up (or
// the caller's 45s no-answer timer ran out) before they answered. This is
// what stops the ringing when Fly was fully swiped away on the callee's
// phone - if Fly is still open or backgrounded there, the Firestore
// listener in main_navigation_screen.dart already does it, and receiving
// both is harmless (dismissing an already-dismissed call does nothing).
//
// Looks the callee up from the call doc itself (calls/{roomName}), so the
// call screen doesn't need to know who it called. Best-effort, like
// sendCallPush: if it fails, the callee's ringing screen still closes on
// its own after its 45s duration.
Future<void> sendCallCancelledPush({required String roomName}) async {
  try {
    final callDoc = await FirebaseFirestore.instance
        .collection('calls')
        .doc(roomName)
        .get();
    final String? calleeId = callDoc.data()?['calleeId'] as String?;
    if (calleeId == null || calleeId.isEmpty) return;

    final calleeDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(calleeId)
        .get();
    final String? fcmToken = calleeDoc.data()?['fcmToken'] as String?;
    if (fcmToken == null || fcmToken.isEmpty) return;

    final Uri uri = Uri.parse('$kTokenServerUrl/call-push');
    await http.post(
      uri,
      headers: {
        ...await workerAuthHeaders(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'type': 'call_cancelled',
        'fcmToken': fcmToken,
        'roomName': roomName,
      }),
    );
  } catch (_) {
    // Best-effort, as noted above.
  }
}

// Wakes the other person's phone for a new chat message (1 Oct 2026), so
// they get a notification and the message turns "Delivered" even when Fly
// is fully closed there - see main.dart's background handler. The Worker
// checks that I'm one of the two people in [chatId]. Best-effort: if it
// fails, an open app still shows the message through its own Firestore
// listener.
Future<void> sendChatPush({
  required String receiverId,
  required String chatId,
  required String senderName,
  required String senderPhoto,
  required String text,
}) async {
  try {
    final receiverDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(receiverId)
        .get();
    final String? fcmToken = receiverDoc.data()?['fcmToken'] as String?;
    if (fcmToken == null || fcmToken.isEmpty) return;

    final Uri uri = Uri.parse('$kTokenServerUrl/call-push');
    await http.post(
      uri,
      headers: {
        ...await workerAuthHeaders(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'type': 'chat_message',
        'fcmToken': fcmToken,
        'chatId': chatId,
        'senderName': senderName,
        'senderPhoto': senderPhoto,
        'text': text,
      }),
    );
  } catch (_) {
    // Best-effort, as noted above.
  }
}

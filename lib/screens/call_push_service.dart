// Sends the incoming-call push that wakes the callee's phone even when
// Fly is backgrounded or fully closed - see notification_service.dart's
// firebaseMessagingBackgroundHandler for the receiving side. This is
// best-effort: if it fails, the call still rings normally for anyone
// with the app open, since that path relies on the Firestore listener
// in main_navigation_screen.dart, not this push.
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'video_call_screen.dart' show kTokenServerUrl, kAppSharedSecret;

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
        'X-App-Secret': kAppSharedSecret,
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

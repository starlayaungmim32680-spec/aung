// Wraps flutter_callkit_incoming so an incoming Fly call shows Android's
// real native call screen (built on the same ConnectionService/CallStyle
// mechanism WhatsApp and Messenger use for their own calls), instead of a
// plain notification. This is what lets a call wake the screen and ring
// even under battery/background restrictions that block a normal
// notification's full-screen intent - the OS treats it as an actual call,
// not "just another app trying to interrupt you".
//
// Two entry points call showIncomingCall: the live Firestore listener in
// main_navigation_screen.dart (app open/backgrounded-but-alive) and the
// FCM background handler in main.dart (app closed). Either way, once the
// native call screen is up, the person's Accept/Decline tap comes back
// through the single onEvent listener set up here - registered once, in
// main(), so it's ready to catch that tap even on a cold start.
//
// v3.1.5's event stream delivers a sealed CallEvent - each action (Accept,
// Decline, Timeout, ...) is its own subclass carrying the original
// CallKitParams back (including id/extra), rather than a generic
// event+body pair - see entities/call_event.dart in the package source.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'screens/video_call_screen.dart';

class CallKitService {
  // Set from main.dart's MaterialApp so this can navigate without needing
  // a BuildContext of its own - necessary since Accept can come from a
  // cold start with no screen open yet.
  static GlobalKey<NavigatorState>? navigatorKey;

  static bool _listening = false;

  // Asks for the two Android permissions CallKit itself needs beyond the
  // ones the rest of the app already requests: the plain notification
  // permission (13+) and the "full screen intent" special permission
  // (14+) - without these, calls can still arrive but the native call
  // screen may not actually pop up. Call once after login, alongside
  // NotificationService.registerAndSaveToken().
  static Future<void> requestPermissions() async {
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Notification permission',
        'rationaleMessagePermission': 'Fly needs this to show incoming calls.',
        'postNotificationMessageRequired':
            'Please allow notifications for Fly from Settings so calls can '
                'reach you.',
      });
    } catch (_) {}

    try {
      final bool canUseFullScreen =
          await FlutterCallkitIncoming.canUseFullScreenIntent();
      if (!canUseFullScreen) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {
      // Not on Android 14+, or the OEM doesn't expose this - harmless
      // either way.
    }
  }

  // Shows the native incoming-call screen. roomName doubles as the
  // call's id, so the same call is never shown twice and Accept/Decline
  // events can be matched straight back to it without any extra
  // bookkeeping.
  static Future<void> showIncomingCall({
    required String roomName,
    required String callerName,
    required String callerPhoto,
    required bool isVideo,
  }) async {
    final CallKitParams params = CallKitParams(
      id: roomName,
      nameCaller: callerName,
      appName: 'Fly',
      avatar: callerPhoto.isNotEmpty ? callerPhoto : null,
      handle: callerName,
      type: isVideo ? 1 : 0,
      duration: 45000,
      extra: <String, dynamic>{
        'roomName': roomName,
        'callerName': callerName,
        'callerPhoto': callerPhoto,
        'isVideo': isVideo,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        // File name only, no extension - Android looks it up from
        // android/app/src/main/res/raw/fly_ringtone.mp3. Falls back to
        // the phone's own default ringtone automatically if that file
        // isn't there, so this is safe even before it's added.
        ringtonePath: 'fly_ringtone',
        backgroundColor: '#0E0E0E',
        actionColor: '#24D17E',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Incoming Calls',
        // Keeps the call treated as a genuine full-screen, over-the-
        // lock-screen experience for its whole lifetime, not just while
        // the ring UI itself is showing - part of what's needed for
        // Answer to lead into VideoCallScreen without an extra unlock
        // prompt on phones without a secure (PIN/pattern) lock set.
        isShowFullLockedScreen: true,
        missedCallNotificationChannelName: 'Missed Calls',
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
    );
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (_) {
      // Best-effort - a failure here (e.g. an unusual OEM ROM) shouldn't
      // crash the call flow; the Firestore call doc still exists, so the
      // person can still find and join it from the app if they open it.
    }
  }

  // Registers the CALLER's own side of the call with Android's Telecom
  // system too - without this, only the person receiving the call gets
  // real OS-level "this is an actual phone call" protection (from
  // showIncomingCall's ConnectionService registration below), while the
  // person who dialed only has Fly's own CallForegroundService to lean
  // on, which turned out not to be enough on its own: their audio was
  // the side that kept dropping on leaving the app, while the receiving
  // side stayed connected fine. This puts both sides on equal footing.
  static Future<void> startOutgoingCall({
    required String roomName,
    required String otherName,
    required String otherPhoto,
    required bool isVideo,
  }) async {
    final CallKitParams params = CallKitParams(
      id: roomName,
      nameCaller: otherName,
      appName: 'Fly',
      avatar: otherPhoto.isNotEmpty ? otherPhoto : null,
      handle: otherName,
      type: isVideo ? 1 : 0,
      extra: <String, dynamic>{
        'roomName': roomName,
        'callerName': otherName,
        'callerPhoto': otherPhoto,
        'isVideo': isVideo,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        backgroundColor: '#0E0E0E',
        actionColor: '#24D17E',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Outgoing Calls',
      ),
    );
    try {
      await FlutterCallkitIncoming.startCall(params);
    } catch (_) {
      // Best-effort - the call still works over Fly's own foreground
      // service even if this fails, just without the extra protection.
    }
  }

  static Future<void> endCall(String roomName) async {
    try {
      await FlutterCallkitIncoming.endCall(roomName);
    } catch (_) {}
    try {
      // endCall(id) alone can leave the "on-going call" notification
      // stuck on some Android versions/OEMs once a call has moved from
      // ringing to connected - endAllCalls() is the more reliable way to
      // actually clear it. Fly only ever has one call active at a time,
      // so there's nothing else it could wrongly end.
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  // Registers the single, app-wide listener for Accept/Decline. Call once
  // from main() - calling it again is a harmless no-op.
  static void initListener() {
    if (_listening) return;
    _listening = true;

    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
      if (event == null) return;

      if (event is CallEventActionCallAccept) {
        final params = event.callKitParams;
        final String roomName = params.id;
        if (roomName.isEmpty) return;
        final Map<String, dynamic> extra = params.extra ?? {};
        final String callerName = extra['callerName']?.toString() ?? 'Someone';
        final String callerPhoto = extra['callerPhoto']?.toString() ?? '';

        try {
          await FirebaseFirestore.instance
              .collection('calls')
              .doc(roomName)
              .update({'status': 'accepted'});
        } catch (_) {}

        final String? myId = FirebaseAuth.instance.currentUser?.uid;
        if (myId == null) return;
        navigatorKey?.currentState?.push(
          MaterialPageRoute(
            builder: (context) => VideoCallScreen(
              roomName: roomName,
              myName: myId,
              otherName: callerName,
              otherPhoto: callerPhoto,
              fromIncomingCall: true,
            ),
          ),
        );
      } else if (event is CallEventActionCallDecline) {
        await _markDeclined(event.callKitParams.id);
      } else if (event is CallEventActionCallTimeout) {
        // Timeout events carry only the call id, not the full params.
        await _markDeclined(event.id);
      }
    });
  }

  static Future<void> _markDeclined(String roomName) async {
    if (roomName.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(roomName)
          .update({'status': 'declined'});
    } catch (_) {}
  }
}

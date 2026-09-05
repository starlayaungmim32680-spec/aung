// Holds a call's LiveKit Room when the person minimizes VideoCallScreen
// back into the rest of Fly instead of ending it - the same "keep
// talking while you use the app" behavior a real phone call has. Only
// one call is ever active at a time, so this is a plain singleton, not
// a class you construct.
//
// Ownership handoff: while a call is minimized, THIS is what's watching
// the Firestore call doc and cleaning everything up if it ends (there's
// no VideoCallScreen open to notice otherwise). The moment VideoCallScreen
// reopens on top of a minimized call, it reclaims the Room and takes that
// watching duty back for itself.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livekit_client/livekit_client.dart';
import 'call_kit_service.dart';

class ActiveCall {
  static Room? room;
  static String? roomName;
  static String? otherName;
  static String? otherPhoto;
  static bool startWithCamera = false;
  static DateTime? connectedAt;
  // Whether the call currently minimized here started as an incoming
  // call (VideoCallScreen's own widget.fromIncomingCall at the moment it
  // was minimized) - carried across the minimize -> banner -> reopen
  // cycle so that reopened screen still knows to use the popUntil route-
  // safety treatment on hang-up/re-minimize, the same way the original
  // screen did. See video_call_screen.dart's _exitVideoCallRoute().
  static bool fromIncomingCall = false;

  static StreamSubscription<DocumentSnapshot>? _statusSub;

  static bool get hasActiveCall => room != null;

  static void adopt({
    required Room activeRoom,
    required String activeRoomName,
    required String? activeOtherName,
    required String? activeOtherPhoto,
    required bool activeStartWithCamera,
    required DateTime activeConnectedAt,
    required bool activeFromIncomingCall,
  }) {
    room = activeRoom;
    roomName = activeRoomName;
    otherName = activeOtherName;
    otherPhoto = activeOtherPhoto;
    startWithCamera = activeStartWithCamera;
    connectedAt = activeConnectedAt;
    fromIncomingCall = activeFromIncomingCall;

    _statusSub?.cancel();
    _statusSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(activeRoomName)
        .snapshots()
        .listen((doc) {
      final String? status = doc.data()?['status'] as String?;
      if (status == 'ended' || status == 'declined') {
        endActiveCall();
      }
    });
  }

  // VideoCallScreen calls this on reopening - hands the still-connected
  // Room back to it and stops watching independently. Returns null if
  // there's no minimized call for this room (a fresh call, most of the
  // time).
  static Room? reclaim(String forRoomName) {
    if (roomName != forRoomName || room == null) return null;
    final Room r = room!;
    _statusSub?.cancel();
    _statusSub = null;
    room = null;
    roomName = null;
    otherName = null;
    otherPhoto = null;
    connectedAt = null;
    fromIncomingCall = false;
    return r;
  }

  static Future<void> endActiveCall() async {
    final String? rn = roomName;
    await _statusSub?.cancel();
    _statusSub = null;
    try {
      await room?.disconnect();
      await room?.dispose();
    } catch (_) {}
    room = null;
    roomName = null;
    otherName = null;
    otherPhoto = null;
    connectedAt = null;
    fromIncomingCall = false;
    if (rn != null) await CallKitService.endCall(rn);
  }
}

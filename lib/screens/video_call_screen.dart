import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../call_kit_service.dart';
import '../call_permissions.dart';
import '../active_call.dart';

// LiveKit connection details for the Fly project.
//
// Tokens are minted by our own Cloudflare Worker (livekit_token_worker.js)
// instead of LiveKit's "Sandbox" endpoint - Sandbox is meant for demos/
// development only, and this app is moving to real users. Fill these in
// after deploying the Worker (see that file's setup comment).
const String kTokenServerUrl =
    'https://livekit-token-worker.chakaboycom.workers.dev';
const String kAppSharedSecret = 'FlySecret2026xyz';

// Shared with MainActivity.kt - lets Dart minimize the app / tell native
// code about the active call for Picture-in-Picture (see that file).
final MethodChannel kBackgroundChannel = MethodChannel('fly/background');

// Colors available for drawing on the call
const List<int> kDrawColors = [
  0xFFFFEB3B, // yellow
  0xFFFF5252, // red
  0xFF18FFFF, // cyan
  0xFF69F0AE, // green
  0xFFFFFFFF, // white
];

// A one-on-one call powered by LiveKit. Starts as a voice call (camera off).
// Includes a shared drawing layer synced over LiveKit data channel.
class VideoCallScreen extends StatefulWidget {
  final String roomName;
  final String myName;
  final String? otherName;
  final String? otherPhoto;
  // Every call here can switch between voice/video mid-call regardless -
  // this only decides which one it opens as. True for a call started
  // from a "video call" button, false (the default) for a plain voice
  // call - camera stays off until the person taps the camera icon.
  final bool startWithCamera;
  // True only when this screen was pushed via CallKitService's Accept
  // handler (the person receiving the call, tapping Accept on the
  // native ring UI) - see _leaveCall's own comment for why that path
  // needs a different "where do I land after hanging up" strategy than
  // a call someone placed themselves from inside e.g. a chat thread.
  final bool fromIncomingCall;

  const VideoCallScreen({
    super.key,
    required this.roomName,
    required this.myName,
    this.otherName,
    this.otherPhoto,
    this.startWithCamera = false,
    this.fromIncomingCall = false,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen>
    with WidgetsBindingObserver {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  bool _connecting = true;
  String? _error;
  String? _debugInfo;

  bool _micEnabled = true;
  bool _cameraEnabled = false;
  // Starts on speaker for video calls (screen's usually held away from
  // the ear anyway) and earpiece for voice calls - matches how most
  // phones behave by default, and the button lets either be flipped
  // mid-call.
  bool _speakerOn = false;
  bool _isFrontCamera = true;

  LocalVideoTrack? _localVideoTrack;
  VideoTrack? _remoteVideoTrack;
  String? _remoteName;
  bool _remoteJoined = false;

  StreamSubscription<DocumentSnapshot>? _callStatusSub;
  bool _hangingUp = false;

  // Call duration - starts counting once setCallConnected fires (see
  // _connect), ticks every second, shown in the app bar area.
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;

  // Backstop for "I called, they didn't answer, but my screen never
  // found out" - if the CallKit decline tap on their end doesn't make it
  // back to Firestore (e.g. their app process wasn't fully alive to run
  // CallKitService's listener when they tapped it), this makes sure the
  // caller's own screen doesn't just sit on "Ringing..." forever. Same
  // 45-second window CallKitParams already uses for the callee's own
  // ring timeout, so both sides give up around the same time either way.
  Timer? _noAnswerTimer;

  // Voice calls only (never video - the screen needs to stay visible for
  // that): mirrors what a real phone call does when held to the ear -
  // Android turns the screen off itself via setProximityScreenOff, but
  // per the plugin's own example, that flag alone isn't enough on some
  // builds - it also needs an active listener on the raw sensor stream
  // for the native side to actually engage. The events themselves aren't
  // used for anything here; just keeping the subscription alive is what
  // matters.
  StreamSubscription<dynamic>? _proximitySub;

  // Drawing state
  bool _drawMode = false;
  Color _drawColor = const Color(0xFFFFEB3B);
  final List<_DrawStroke> _strokes = [];
  _DrawStroke? _activeLocal;
  _DrawStroke? _activeRemote;
  Offset? _lastLocalPixel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Request call-related permissions (notifications, and Android 14+'s
    // "full screen intent" for incoming-call alerts) right here, at the
    // moment a call actually starts - not on app open, and not on every
    // app open regardless of whether the person ever uses calling.
    CallKitService.requestPermissions();
    // Battery-optimization exemption, overlay, full-screen intent, and
    // OEM autostart settings - same reasoning, only asked once a call is
    // actually happening.
    maybeAskForCallReliabilityPermissions(context);
    _connect();
    _listenForCallEnd();
    _noAnswerTimer = Timer(const Duration(seconds: 45), () {
      if (!_remoteJoined && mounted) _endCall();
    });
  }

  // Leaving Fly for the Home screen or another app (AppLifecycleState.
  // paused) no longer ends the call - CallForegroundService.kt is already
  // running by this point (started in _markCallActiveNatively when the
  // call connected) and is what keeps this process alive in the
  // background, exactly like a real phone call. Nothing here needs to
  // disconnect the Room, dispose the listener, or stop the service - all
  // of that is left completely alone, so coming back to Fly (via the
  // "Fly call in progress" notification or the app icon) simply resumes
  // this same, still-connected screen. For a video call specifically,
  // MainActivity.kt's onUserLeaveHint() already tries Picture-in-Picture
  // first, so this path is mainly what covers voice calls and any device
  // where PiP isn't available - video's local camera preview may freeze
  // without a visible Surface in that fallback case (an Android OS
  // limitation, not something fixable in Dart), but audio keeps working
  // either way since the foreground service holds the microphone.
  //
  // AppLifecycleState.detached means the engine itself is being torn
  // down (not just backgrounded) - nothing would be listening to resume
  // into afterwards, so the call is ended cleanly here rather than left
  // as a one-sided "zombie" connection on the other participant's side.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isMinimizing) return;
    if (state == AppLifecycleState.detached) {
      _endCall();
    }
  }

  void _startCallTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  String get _formattedDuration {
    final int totalSeconds = _callDuration.inSeconds;
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _startProximityScreenOffIfVoiceCall() async {
    if (widget.startWithCamera) return; // video call - keep screen on
    try {
      await ProximitySensor.setProximityScreenOff(true);
      _proximitySub = ProximitySensor.events.listen((_) {});
    } catch (_) {
      // Not available on this device/ROM - not a functional problem,
      // the call itself is unaffected either way.
    }
  }

  DocumentReference get _callRef =>
      FirebaseFirestore.instance.collection('calls').doc(widget.roomName);

  void _listenForCallEnd() {
    _callStatusSub = _callRef.snapshots().listen((doc) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return;
      final status = data['status'] as String?;
      if (status == 'ended' || status == 'declined') {
        _leaveCall();
      }
    });
  }

  Future<Map<String, String>?> _fetchConnectionDetails() async {
    try {
      final uri = Uri.parse(kTokenServerUrl);

      final response = await http.post(
        uri,
        headers: {
          'X-App-Secret': kAppSharedSecret,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'room_name': widget.roomName,
          'participant_name': widget.myName,
        }),
      );

      _debugInfo = 'HTTP ${response.statusCode}\n${response.body}';

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final String? token = data['participantToken'] as String?;
        final String? url = data['serverUrl'] as String?;
        if (token != null && url != null) {
          return {'token': token, 'url': url};
        }
      }
      return null;
    } catch (e) {
      _debugInfo = 'Exception: $e';
      return null;
    }
  }

  DateTime? _connectedAt;
  bool _isMinimizing = false;

  Future<void> _connect() async {
    // If this exact call is already running because it was minimized
    // rather than ended, reuse that connection instead of dialing again -
    // reconnecting would drop and re-establish media for no reason, and
    // briefly show "Ringing..." on a call that's actually been going for
    // a while.
    final Room? existing = ActiveCall.reclaim(widget.roomName);
    if (existing != null) {
      _adoptExistingRoom(existing);
      return;
    }

    final details = await _fetchConnectionDetails();

    if (details == null) {
      setState(() {
        _connecting = false;
        _error = 'Could not get access token. Please try again.';
      });
      return;
    }

    try {
      final room = Room(
        // Explicit rather than relying on the library's own defaults -
        // these already default to true, but making it explicit means
        // nothing else in the connect path can silently leave them off,
        // which is exactly the kind of thing that would cause the
        // person to hear their own voice echoed back.
        roomOptions: const RoomOptions(
          defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
          ),
        ),
      );

      final listener = room.createListener();
      _setupListeners(listener);

      await room.connect(details['url']!, details['token']!);

      await room.localParticipant?.setCameraEnabled(widget.startWithCamera);
      await room.localParticipant?.setMicrophoneEnabled(true);

      LocalVideoTrack? startingVideoTrack;
      if (widget.startWithCamera) {
        final localPub =
            room.localParticipant?.videoTrackPublications.firstOrNull;
        startingVideoTrack = localPub?.track as LocalVideoTrack?;
      }

      setState(() {
        _room = room;
        _listener = listener;
        _connecting = false;
        _cameraEnabled = widget.startWithCamera;
        _localVideoTrack = startingVideoTrack;
      });

      // Tells CallKit the call is actually live now, not just ringing -
      // its own internal call-state tracking needs this to later clean up
      // the "on-going call" notification reliably when either side hangs
      // up (see CallKitService.endCall).
      try {
        await FlutterCallkitIncoming.setCallConnected(widget.roomName);
      } catch (_) {}
      _connectedAt = DateTime.now();
      _startCallTimer();
      await _startProximityScreenOffIfVoiceCall();
      // Video calls default to speaker (screen's held out to see the
      // other person, not up to the ear); voice calls default to
      // earpiece, like a normal phone call.
      if (widget.startWithCamera) {
        _speakerOn = true;
        Helper.setSpeakerphoneOn(true).catchError((_) {});
      }
      // Keeps the CPU from sleeping for the length of the call - helps
      // the connection survive Android's background throttling if the
      // person switches away to another app mid-call.
      WakelockPlus.enable();
      _markCallActiveNatively();

      _refreshRemote();
    } catch (e) {
      setState(() {
        _connecting = false;
        _error = 'Could not connect to the call.';
        _debugInfo = 'Connect error: $e';
      });
    }
  }

  // Picks a Room back up after minimizing (see ActiveCall) - rebuilds
  // this screen's state from whatever the room's participants/tracks
  // already are, instead of connecting fresh.
  Future<void> _adoptExistingRoom(Room room) async {
    final listener = room.createListener();
    _setupListeners(listener);

    final LocalVideoTrack? localVideo = room.localParticipant
        ?.videoTrackPublications.firstOrNull?.track as LocalVideoTrack?;
    final bool cameraOn = localVideo != null;

    setState(() {
      _room = room;
      _listener = listener;
      _connecting = false;
      _cameraEnabled = cameraOn;
      _localVideoTrack = localVideo;
    });

    _connectedAt = ActiveCall.connectedAt ?? DateTime.now();
    _callDuration = DateTime.now().difference(_connectedAt!);
    _startCallTimer();
    await _startProximityScreenOffIfVoiceCall();
    WakelockPlus.enable();
    _markCallActiveNatively();

    _refreshRemote();
  }

  // Tells MainActivity.kt whether there's a call it should treat
  // specially: starting CallForegroundService (see that file) so the
  // process survives leaving the app, and entering Picture-in-Picture
  // automatically for video calls. Shows a SnackBar on failure - this
  // native call has broken silently before, and there's no other way to
  // see why without a full debugger attached.
  Future<void> _markCallActiveNatively() async {
    try {
      await kBackgroundChannel.invokeMethod(
        'setCallActive',
        {'isVideo': _cameraEnabled},
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Background call service failed to start: $e'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  Future<void> _clearCallActiveNatively() async {
    try {
      await kBackgroundChannel.invokeMethod('clearCallActive');
    } catch (_) {}
  }

  void _setupListeners(EventsListener<RoomEvent> listener) {
    listener
      ..on<TrackSubscribedEvent>((event) {
        _refreshRemote();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _refreshRemote();
      })
      ..on<ParticipantConnectedEvent>((event) {
        _refreshRemote();
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _endCall();
      })
      // My own connection dropping (network loss, the phone's background
      // throttling silencing the call, etc.) - without this, the other
      // person's screen would just sit there looking "connected" with no
      // audio coming through and no way to know the call actually died
      // on my end. Reusing _endCall() marks the Firestore doc "ended",
      // which is what lets their own _listenForCallEnd() close their
      // screen too, instead of one side hanging in a zombie call.
      ..on<RoomDisconnectedEvent>((event) {
        _endCall();
      })
      // Receive the other person's drawing strokes
      ..on<DataReceivedEvent>((event) {
        try {
          final msg =
              jsonDecode(utf8.decode(event.data)) as Map<String, dynamic>;
          _handleRemoteData(msg);
        } catch (_) {}
      });
  }

  void _refreshRemote() {
    final room = _room;
    if (room == null) return;

    VideoTrack? remoteTrack;
    String? remoteName;
    final bool joined = room.remoteParticipants.isNotEmpty;

    for (final participant in room.remoteParticipants.values) {
      remoteName =
          participant.name.isNotEmpty ? participant.name : participant.identity;
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null) {
          remoteTrack = pub.track as VideoTrack;
          break;
        }
      }
      if (remoteTrack != null) break;
    }

    if (mounted) {
      setState(() {
        _remoteVideoTrack = remoteTrack;
        _remoteName = remoteName;
        _remoteJoined = joined;
      });
      if (joined) {
        _noAnswerTimer?.cancel();
      }
    }
  }

  // ---- Drawing: sending ----

  Future<void> _sendDraw(double x, double y, bool start) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final msg = <String, dynamic>{
      't': 'd',
      'x': x,
      'y': y,
      's': start,
      if (start) 'c': _drawColor.value,
    };
    try {
      await lp.publishData(utf8.encode(jsonEncode(msg)));
    } catch (_) {}
  }

  Future<void> _sendClear() async {
    setState(() {
      _strokes.clear();
      _activeLocal = null;
      _activeRemote = null;
    });
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      await lp.publishData(utf8.encode(jsonEncode({'t': 'clear'})));
    } catch (_) {}
  }

  void _onDrawStart(Offset pos, Size size) {
    final nx = pos.dx / size.width;
    final ny = pos.dy / size.height;
    final stroke = _DrawStroke(_drawColor)..points.add(Offset(nx, ny));
    setState(() {
      _strokes.add(stroke);
      _activeLocal = stroke;
      _lastLocalPixel = pos;
    });
    _sendDraw(nx, ny, true);
  }

  void _onDrawUpdate(Offset pos, Size size) {
    final active = _activeLocal;
    if (active == null) return;
    // Skip tiny movements to reduce network traffic
    if (_lastLocalPixel != null && (pos - _lastLocalPixel!).distance < 3.0) {
      return;
    }
    _lastLocalPixel = pos;
    final nx = pos.dx / size.width;
    final ny = pos.dy / size.height;
    setState(() {
      active.points.add(Offset(nx, ny));
    });
    _sendDraw(nx, ny, false);
  }

  void _onDrawEnd() {
    _activeLocal = null;
    _lastLocalPixel = null;
  }

  // ---- Drawing: receiving ----

  void _handleRemoteData(Map<String, dynamic> msg) {
    if (!mounted) return;
    final t = msg['t'];
    if (t == 'clear') {
      setState(() {
        _strokes.clear();
        _activeLocal = null;
        _activeRemote = null;
      });
      return;
    }
    if (t == 'd') {
      final double x = (msg['x'] as num).toDouble();
      final double y = (msg['y'] as num).toDouble();
      final bool start = msg['s'] == true;
      if (start) {
        final int c = (msg['c'] as num?)?.toInt() ?? 0xFFFFFFFF;
        final stroke = _DrawStroke(Color(c))..points.add(Offset(x, y));
        setState(() {
          _strokes.add(stroke);
          _activeRemote = stroke;
        });
      } else {
        final active = _activeRemote;
        if (active != null) {
          setState(() {
            active.points.add(Offset(x, y));
          });
        }
      }
    }
  }

  // ---- Call controls ----

  Future<void> _toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final next = !_micEnabled;
    await lp.setMicrophoneEnabled(next);
    setState(() => _micEnabled = next);
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    try {
      await Helper.setSpeakerphoneOn(next);
      setState(() => _speakerOn = next);
    } catch (_) {
      // Not available on this device - leaves the phone on whichever
      // output it was already using, which is still a working call.
    }
  }

  Future<void> _toggleCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final next = !_cameraEnabled;
    await lp.setCameraEnabled(next);

    final localPub = lp.videoTrackPublications.firstOrNull;
    setState(() {
      _cameraEnabled = next;
      _localVideoTrack = next ? (localPub?.track as LocalVideoTrack?) : null;
    });
  }

  Future<void> _switchCamera() async {
    final track = _localVideoTrack;
    if (track == null) return;
    try {
      final newPosition =
          _isFrontCamera ? CameraPosition.back : CameraPosition.front;
      await track.setCameraPosition(newPosition);
      setState(() => _isFrontCamera = !_isFrontCamera);
    } catch (_) {}
  }

  Future<void> _endCall() async {
    if (_hangingUp) return;
    _hangingUp = true;
    // Fired together instead of one after another - if the phone is in
    // the middle of leaving the app right now (the exact moment Android
    // is most likely to start throttling this process), waiting for the
    // Firestore write to finish before even starting CallKit's own
    // cleanup risked never getting to the second step at all. Doing
    // both at once gives each the best chance of actually completing
    // before that happens - this is what left the "Ongoing call"
    // notification stuck on the leaving person's own phone even though
    // the other side correctly saw the call end via Firestore.
    unawaited(CallKitService.endCall(widget.roomName));
    try {
      await _callRef.update({'status': 'ended'});
    } catch (_) {}
    await _leaveCall();
  }

  Future<void> _leaveCall() async {
    // Dismisses CallKit's own native "ongoing call" notification/UI - the
    // Firestore status update above closes this screen, but that's a
    // separate thing from CallKit's own system-level call session, which
    // otherwise keeps showing "On-going call" / Hang up on both phones
    // even after one side has actually left.
    await CallKitService.endCall(widget.roomName);
    if (!mounted) return;
    await _room?.disconnect();
    if (!mounted) return;
    if (widget.fromIncomingCall) {
      // A plain pop() left the person receiving the call on a black
      // screen sometimes - their VideoCallScreen was pushed via the
      // app-wide navigatorKey from CallKitService's Accept handler,
      // not the in-context Navigator.push the caller's side uses, and
      // something about that path leaves an extra, empty route behind.
      // popUntil the first route sidesteps needing to know exactly why:
      // whatever's stacked above the base MainNavigationScreen gets
      // cleared, always landing on a real, populated screen.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      // The caller placed this call from wherever they were (e.g. a
      // chat thread) via a normal in-context push - a single pop
      // correctly returns them right there, so this path is left alone.
      Navigator.pop(context);
    }
  }

  // Keeps the call fully connected but hands it off to ActiveCall and
  // closes this screen - lets the person go use the rest of Fly while
  // still talking, the same way a real phone call doesn't force you to
  // stare at the dialer the whole time.
  void _minimizeCall() {
    if (_room == null) {
      // Nothing connected yet to preserve (still connecting, or errored
      // out) - closing the screen here is the same as leaving the call.
      _leaveCall();
      return;
    }
    _isMinimizing = true;
    ActiveCall.adopt(
      activeRoom: _room!,
      activeRoomName: widget.roomName,
      activeOtherName: widget.otherName ?? _remoteName,
      activeOtherPhoto: widget.otherPhoto,
      activeStartWithCamera: _cameraEnabled,
      activeConnectedAt: _connectedAt ?? DateTime.now(),
    );
    // PiP only makes sense while this screen itself is what's showing -
    // once minimized in-app, leaving Fly entirely should just background
    // normally, not try to shrink a screen that's no longer open.
    _clearCallActiveNatively();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callStatusSub?.cancel();
    _durationTimer?.cancel();
    _noAnswerTimer?.cancel();
    _proximitySub?.cancel();
    // Turn the screen-off-on-proximity behavior back off - otherwise it
    // stays active app-wide even outside calls.
    ProximitySensor.setProximityScreenOff(false).catchError((_) {});
    WakelockPlus.disable();

    if (_isMinimizing) {
      // The call keeps running under ActiveCall - only this screen's own
      // UI-bound listener needs cleaning up, not the room itself or
      // CallKit's session, both of which ActiveCall now owns.
      _listener?.dispose();
      super.dispose();
      return;
    }

    _clearCallActiveNatively();
    _listener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    // Safety net for exits that skip _leaveCall (e.g. system back
    // gesture) - makes sure CallKit's native call session never gets
    // left stuck showing "On-going call" on either phone.
    CallKitService.endCall(widget.roomName);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _minimizeCall();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildRemoteView(),
              ),

              // My own camera preview - only when my camera is on
              if (_cameraEnabled && _localVideoTrack != null)
                Positioned(
                  top: 16,
                  right: 16,
                  child: Container(
                    width: 110,
                    height: 160,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24, width: 1),
                      color: Colors.grey[900],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: VideoTrackRenderer(_localVideoTrack!),
                  ),
                ),

              // Drawing layer - always shows strokes; captures touch in draw mode
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_drawMode,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _onDrawStart(d.localPosition, size),
                        onPanUpdate: (d) =>
                            _onDrawUpdate(d.localPosition, size),
                        onPanEnd: (d) => _onDrawEnd(),
                        child: CustomPaint(
                          painter: _DrawPainter(_strokes),
                          size: Size.infinite,
                        ),
                      );
                    },
                  ),
                ),
              ),

              // Switch-camera button (only when my camera is on)
              if (_cameraEnabled && !_connecting && _error == null)
                Positioned(
                  top: 16,
                  left: 16,
                  child: GestureDetector(
                    onTap: _switchCamera,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: const Icon(Icons.cameraswitch,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ),

              // Draw toolbar (colors + clear) - shown when in draw mode
              if (_drawMode && _error == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 110,
                  child: Center(child: _buildDrawToolbar()),
                ),

              Positioned(
                left: 0,
                right: 0,
                bottom: 30,
                child: _buildControls(),
              ),

              _buildMinimizeButton(),
            ],
          ),
        ),
      ),
    );
  }

  // Backgrounds the app the way pressing the Home button would (see
  // MainActivity.kt's method channel) - the LiveKit room, CallKit
  // session, and this whole widget's state are left completely alone,
  // so returning to the app (task switcher or the CallKit notification)
  // drops the person right back into the still-connected call, instead
  // of the back gesture hanging up the way a normal screen-pop would.
  Future<void> _minimizeToBackground() async {
    try {
      await kBackgroundChannel.invokeMethod('moveToBackground');
    } catch (_) {
      // Fall back to the old behavior (actually leaving the call) rather
      // than trapping the person on this screen with no way out.
      _leaveCall();
    }
  }

  Widget _buildDrawToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...kDrawColors.map((c) {
            final bool selected = _drawColor.value == c;
            return GestureDetector(
              onTap: () => setState(() => _drawColor = Color(c)),
              child: Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
            );
          }),
          const SizedBox(width: 6),
          Container(width: 1, height: 24, color: Colors.white24),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _sendClear,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Colors.white12,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline,
                  color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteView() {
    if (_connecting) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.redAccent),
            SizedBox(height: 16),
            Text('Connecting...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              if (_debugInfo != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _debugInfo!,
                    style: const TextStyle(
                        color: Colors.orangeAccent, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      );
    }

    if (_remoteVideoTrack != null) {
      return VideoTrackRenderer(_remoteVideoTrack!);
    }

    final String name = widget.otherName ?? _remoteName ?? 'Calling';
    final String photo = widget.otherPhoto ?? '';

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
              ),
            ),
            child: CircleAvatar(
              radius: 60,
              backgroundColor: Colors.grey[850],
              backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
              child: photo.isEmpty
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 44,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _remoteJoined
                ? (_callDuration.inSeconds > 0 ? _formattedDuration : 'In call')
                : 'Ringing...',
            style: const TextStyle(color: Colors.white60, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ControlButton(
          icon: _micEnabled ? Icons.mic : Icons.mic_off,
          color: _micEnabled ? Colors.white24 : Colors.redAccent,
          onTap: _toggleMic,
        ),
        const SizedBox(width: 14),
        _ControlButton(
          icon: _speakerOn ? Icons.volume_up : Icons.hearing,
          color: _speakerOn ? const Color(0xFF24D17E) : Colors.white24,
          onTap: _toggleSpeaker,
        ),
        const SizedBox(width: 14),
        _ControlButton(
          icon: Icons.call_end,
          color: Colors.red,
          size: 62,
          onTap: _endCall,
        ),
        const SizedBox(width: 14),
        _ControlButton(
          icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
          color: _cameraEnabled ? Colors.white24 : Colors.redAccent,
          onTap: _toggleCamera,
        ),
        const SizedBox(width: 14),
        // Draw toggle
        _ControlButton(
          icon: Icons.edit,
          color: _drawMode ? const Color(0xFF24D17E) : Colors.white24,
          onTap: () => setState(() => _drawMode = !_drawMode),
        ),
      ],
    );
  }

  // A small, explicit "minimize" affordance up top - the back gesture
  // does the same thing (see PopScope in build()), but this makes it
  // discoverable without relying on people knowing that.
  Widget _buildMinimizeButton() {
    return Positioned(
      top: 8,
      left: 8,
      child: SafeArea(
        child: GestureDetector(
          onTap: _minimizeCall,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.keyboard_arrow_down,
                color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 54,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.45),
      ),
    );
  }
}

// One drawn line: a list of normalized (0-1) points and a color
class _DrawStroke {
  final Color color;
  final List<Offset> points = [];
  _DrawStroke(this.color);
}

// Paints all strokes (local + remote) over the call
class _DrawPainter extends CustomPainter {
  final List<_DrawStroke> strokes;
  _DrawPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = 4.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      if (stroke.points.length == 1) {
        final p = stroke.points.first;
        canvas.drawCircle(
          Offset(p.dx * size.width, p.dy * size.height),
          2.0,
          Paint()..color = stroke.color,
        );
        continue;
      }

      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.dx * size.width, first.dy * size.height);
      for (int i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_DrawPainter oldDelegate) => true;
}

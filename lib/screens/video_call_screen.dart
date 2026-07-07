import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livekit_client/livekit_client.dart';

// LiveKit connection details for the Fly project
const String kLiveKitUrl = 'wss://fly-iv33xo63.livekit.cloud';
const String kSandboxId = 'fly-fu1yvy';

// A one-on-one call powered by LiveKit. Starts as a voice call
// (camera off) - users turn on video only if they want.
class VideoCallScreen extends StatefulWidget {
  final String roomName;
  final String myName;
  final String? otherName;
  final String? otherPhoto;

  const VideoCallScreen({
    super.key,
    required this.roomName,
    required this.myName,
    this.otherName,
    this.otherPhoto,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  bool _connecting = true;
  String? _error;
  String? _debugInfo;

  bool _micEnabled = true;
  bool _cameraEnabled = false;
  bool _isFrontCamera = true;

  LocalVideoTrack? _localVideoTrack;
  VideoTrack? _remoteVideoTrack;
  String? _remoteName;
  bool _remoteJoined = false;

  StreamSubscription<DocumentSnapshot>? _callStatusSub;
  bool _hangingUp = false;

  @override
  void initState() {
    super.initState();
    _connect();
    _listenForCallEnd();
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
      final uri = Uri.parse(
          'https://cloud-api.livekit.io/api/sandbox/connection-details');

      final response = await http.post(
        uri,
        headers: {
          'X-Sandbox-ID': kSandboxId,
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

  Future<void> _connect() async {
    final details = await _fetchConnectionDetails();

    if (details == null) {
      setState(() {
        _connecting = false;
        _error = 'Could not get access token. Please try again.';
      });
      return;
    }

    try {
      final room = Room();

      final listener = room.createListener();
      _setupListeners(listener);

      await room.connect(details['url']!, details['token']!);

      // Start as a voice call - camera off, mic on
      await room.localParticipant?.setCameraEnabled(false);
      await room.localParticipant?.setMicrophoneEnabled(true);

      setState(() {
        _room = room;
        _listener = listener;
        _connecting = false;
      });

      _refreshRemote();
    } catch (e) {
      setState(() {
        _connecting = false;
        _error = 'Could not connect to the call.';
        _debugInfo = 'Connect error: $e';
      });
    }
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
        // The other person left - end the call for me too
        _endCall();
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
    }
  }

  Future<void> _toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final next = !_micEnabled;
    await lp.setMicrophoneEnabled(next);
    setState(() => _micEnabled = next);
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
    try {
      await _callRef.update({'status': 'ended'});
    } catch (_) {}
    await _leaveCall();
  }

  Future<void> _leaveCall() async {
    if (!mounted) return;
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _callStatusSub?.cancel();
    _listener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _buildRemoteView(),
            ),

            // My own camera preview - only shown when my camera is on
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

            Positioned(
              left: 0,
              right: 0,
              bottom: 30,
              child: _buildControls(),
            ),
          ],
        ),
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

    // The other person turned their camera on - show their video
    if (_remoteVideoTrack != null) {
      return VideoTrackRenderer(_remoteVideoTrack!);
    }

    // Voice-call style: show the other person's avatar + name
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
            _remoteJoined ? 'In call' : 'Ringing...',
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
        const SizedBox(width: 20),
        _ControlButton(
          icon: Icons.call_end,
          color: Colors.red,
          size: 64,
          onTap: _endCall,
        ),
        const SizedBox(width: 20),
        _ControlButton(
          icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
          color: _cameraEnabled ? Colors.white24 : Colors.redAccent,
          onTap: _toggleCamera,
        ),
      ],
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
    this.size = 56,
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

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livekit_client/livekit_client.dart';

// LiveKit connection details for the Fly project
const String kLiveKitUrl = 'wss://fly-iv33xo63.livekit.cloud';
const String kSandboxId = 'fly-fu1yvy';

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
                      onPanUpdate: (d) => _onDrawUpdate(d.localPosition, size),
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
          ],
        ),
      ),
    );
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
        const SizedBox(width: 16),
        _ControlButton(
          icon: Icons.call_end,
          color: Colors.red,
          size: 62,
          onTap: _endCall,
        ),
        const SizedBox(width: 16),
        _ControlButton(
          icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
          color: _cameraEnabled ? Colors.white24 : Colors.redAccent,
          onTap: _toggleCamera,
        ),
        const SizedBox(width: 16),
        // Draw toggle
        _ControlButton(
          icon: Icons.edit,
          color: _drawMode ? const Color(0xFF24D17E) : Colors.white24,
          onTap: () => setState(() => _drawMode = !_drawMode),
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

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:collection/collection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'video_call_screen.dart' show kTokenServerUrl, kAppSharedSecret;
import 'gifting.dart';

// Shared helper: gets a LiveKit access token + server url from our own
// token-minting server (see livekit_token_worker.js) - the same one the
// 1-on-1 calls use.
Future<Map<String, String>?> _fetchLiveKitConnectionDetails({
  required String roomName,
  required String participantName,
}) async {
  try {
    final uri = Uri.parse(kTokenServerUrl);
    final response = await http.post(
      uri,
      headers: {
        'X-App-Secret': kAppSharedSecret,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'room_name': roomName,
        'participant_name': participantName,
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final String? token = data['participantToken'] as String?;
      final String? url = data['serverUrl'] as String?;
      if (token != null && url != null) {
        return {'token': token, 'url': url};
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------
// Broadcaster
// ---------------------------------------------------------------------

// Screen the host uses to start and run their own live stream. Publishes
// camera + mic to a LiveKit room named "live_{uid}" and keeps a
// liveStreams/{uid} Firestore doc up to date so viewers can find it.
class GoLiveScreen extends StatefulWidget {
  final String title;

  const GoLiveScreen({super.key, this.title = ''});

  @override
  State<GoLiveScreen> createState() => _GoLiveScreenState();
}

class _GoLiveScreenState extends State<GoLiveScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  LocalVideoTrack? _localVideoTrack;

  bool _connecting = true;
  bool _isFrontCamera = true;
  String? _error;
  bool _ending = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _roomName => 'live_$_uid';

  @override
  void initState() {
    super.initState();
    // Don't let the phone dim/lock while broadcasting.
    WakelockPlus.enable();
    _goLive();
  }

  Future<void> _goLive() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _connecting = false;
        _error = 'You need to be signed in to go live.';
      });
      return;
    }

    // Ask for camera + mic up front. Without these granted, publishing
    // the local tracks below throws and the stream can't start.
    try {
      final statuses = await [
        Permission.camera,
        Permission.microphone,
      ].request();

      final bool cameraOk = statuses[Permission.camera]?.isGranted ?? false;
      final bool micOk = statuses[Permission.microphone]?.isGranted ?? false;

      if (!cameraOk || !micOk) {
        setState(() {
          _connecting = false;
          _error = 'Camera and microphone permission are required to go '
              'live.\nPlease enable them in Settings > Apps > fly > '
              'Permissions.';
        });
        return;
      }
    } catch (e) {
      setState(() {
        _connecting = false;
        _error = 'Could not request camera/microphone permission:\n$e';
      });
      return;
    }

    // Look up my own display name/photo for the live card viewers will see
    String hostName = user.email?.split('@').first ?? 'Someone';
    String hostPhoto = '';
    try {
      final myProfile =
          await FirebaseFirestore.instance.collection('users').doc(_uid).get();
      final data = myProfile.data();
      hostName = (data?['displayName'] as String?)?.trim().isNotEmpty == true
          ? data!['displayName']
          : hostName;
      hostPhoto = (data?['photoUrl'] as String?) ?? '';
    } catch (_) {
      // Keep fallback name
    }

    final details = await _fetchLiveKitConnectionDetails(
      roomName: _roomName,
      participantName: hostName,
    );

    if (details == null) {
      setState(() {
        _connecting = false;
        _error = 'Could not reach the live server to get an access token.\n'
            'Check your internet connection and try again.';
      });
      return;
    }

    try {
      final room = Room();
      final listener = room.createListener();
      listener.on<ParticipantConnectedEvent>((event) => setState(() {}));
      listener.on<ParticipantDisconnectedEvent>((event) => setState(() {}));

      await room.connect(details['url']!, details['token']!);
      await room.localParticipant?.setCameraEnabled(true);
      await room.localParticipant?.setMicrophoneEnabled(true);

      final localPub = room.localParticipant?.videoTrackPublications
          .where((p) => p.track != null)
          .firstOrNull;

      // Mark this stream as live so it shows up for viewers
      await FirebaseFirestore.instance.collection('liveStreams').doc(_uid).set({
        'hostId': _uid,
        'hostName': hostName,
        'hostPhoto': hostPhoto,
        'roomName': _roomName,
        'title': widget.title,
        'status': 'live',
        'startedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() {
        _room = room;
        _listener = listener;
        _localVideoTrack = localPub?.track as LocalVideoTrack?;
        _connecting = false;
      });
    } catch (e) {
      // Show the real error - a generic message hides whether this was a
      // permission problem, a Firestore rules problem, or a LiveKit one.
      setState(() {
        _connecting = false;
        _error = 'Could not start the live stream:\n$e';
      });
    }
  }

  Future<void> _flipCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final pub = lp.videoTrackPublications.firstOrNull;
    final track = pub?.track;
    if (track is LocalVideoTrack) {
      await track.setCameraPosition(
        _isFrontCamera ? CameraPosition.back : CameraPosition.front,
      );
      setState(() => _isFrontCamera = !_isFrontCamera);
    }
  }

  Future<void> _endLive() async {
    if (_ending) return;
    setState(() => _ending = true);

    // "Timeline Highlights": before marking the stream ended, scan its
    // whole reaction history for the 30-second window with the most
    // reactions, so the host gets a quick "this was your biggest moment"
    // recap instead of having to guess from memory.
    Map<String, dynamic>? highlight;
    try {
      final liveDoc = await FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(_uid)
          .get();
      final Timestamp? startedTs = liveDoc.data()?['startedAt'] as Timestamp?;
      final reactionsSnap = await FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(_uid)
          .collection('reactions')
          .orderBy('createdAt')
          .get();

      if (startedTs != null && reactionsSnap.docs.isNotEmpty) {
        final DateTime started = startedTs.toDate();
        const int windowSeconds = 30;
        final Map<int, int> windowCounts = {};
        for (final doc in reactionsSnap.docs) {
          final Timestamp? ts = doc.data()['createdAt'] as Timestamp?;
          if (ts == null) continue;
          final int secondsIn = ts.toDate().difference(started).inSeconds;
          final int windowIndex = secondsIn ~/ windowSeconds;
          windowCounts[windowIndex] = (windowCounts[windowIndex] ?? 0) + 1;
        }
        final MapEntry<int, int> peak =
            windowCounts.entries.reduce((a, b) => b.value > a.value ? b : a);
        highlight = {
          'highlightAtSeconds': peak.key * windowSeconds,
          'highlightReactionCount': peak.value,
          'totalReactions': reactionsSnap.docs.length,
        };
      }
    } catch (_) {
      // Highlight computation is a bonus, never block ending the stream.
    }

    try {
      // Keep the doc (marked "ended") instead of deleting it, so the live
      // still shows up - as a recap with its comment thread - afterward.
      await FirebaseFirestore.instance.collection('liveStreams').doc(_uid).set(
        {
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
          if (highlight != null) ...highlight,
        },
        SetOptions(merge: true),
      );
    } catch (_) {}
    await _room?.disconnect();
    if (!mounted) return;
    if (highlight != null) {
      await _showHighlightRecap(highlight);
    }
    if (mounted) Navigator.pop(context);
  }

  // Small recap shown right after ending, summarizing the stream's peak
  // engagement moment - not tied to video playback (Fly doesn't record
  // live streams), just a quick "here's how it went" for the host.
  Future<void> _showHighlightRecap(Map<String, dynamic> highlight) async {
    final int seconds = highlight['highlightAtSeconds'] as int;
    final int minutesIn = seconds ~/ 60;
    final int secondsIn = seconds % 60;
    final String timeLabel =
        minutesIn > 0 ? '$minutesIn min ${secondsIn}s in' : '${secondsIn}s in';
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('🔥 Timeline Highlight',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Your biggest moment was $timeLabel, with '
          '${highlight['highlightReactionCount']} reactions in 30 seconds.\n\n'
          'Total reactions this stream: ${highlight['totalReactions']}.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Nice!', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmEnd() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('End live stream?',
            style: TextStyle(color: Colors.white)),
        content: const Text('Your viewers will be disconnected.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _endLive();
    }
    return false; // We handle popping ourselves in _endLive
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _listener?.dispose();
    _room?.disconnect();
    // Best-effort cleanup if the screen is dismissed some other way -
    // still mark it ended rather than deleting, same as _endLive above.
    if (_uid.isNotEmpty) {
      FirebaseFirestore.instance.collection('liveStreams').doc(_uid).set(
        {
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).catchError((_) => null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _confirmEnd,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_connecting)
              const Center(
                child: CircularProgressIndicator(color: Colors.redAccent),
              )
            else if (_error != null)
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(_error!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center),
                ),
              )
            else if (_localVideoTrack != null)
              VideoTrackRenderer(_localVideoTrack!)
            else
              const Center(
                child: Text('Starting camera...',
                    style: TextStyle(color: Colors.white54)),
              ),
            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_connecting && _error == null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('liveStreams')
                              .doc(_uid)
                              .collection('viewers')
                              .snapshots(),
                          builder: (context, snap) {
                            final int count = snap.data?.docs.length ?? 0;
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.remove_red_eye,
                                    color: Colors.white, size: 14),
                                const SizedBox(width: 4),
                                Text('$count',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13)),
                              ],
                            );
                          },
                        ),
                      ),
                    const Spacer(),
                    if (!_connecting) ...[
                      GestureDetector(
                        onTap: _flipCamera,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.cameraswitch,
                              color: Colors.white, size: 20),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    GestureDetector(
                      onTap: _confirmEnd,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!_connecting && _error == null)
              Positioned(
                top: 90,
                left: 12,
                right: 12,
                child: _ReactionPulseBar(hostId: _uid),
              ),
            if (!_connecting && _error == null)
              LiveInteractionLayer(hostId: _uid),
          ],
        ),
      ),
    );
  }
}

// "Reaction Pulse" - a small live-updating bar chart showing how heavily
// viewers are reacting (❤️😂😮👏🔥all counted together) over the last
// ~40 seconds, host-only, so the streamer can see which moments are
// landing without reading through the comment/reaction stream itself.
class _ReactionPulseBar extends StatelessWidget {
  final String hostId;

  const _ReactionPulseBar({required this.hostId});

  static const int _bucketSeconds = 2;
  static const int _bucketCount = 20; // 40 seconds of history

  @override
  Widget build(BuildContext context) {
    final DateTime windowStart = DateTime.now()
        .subtract(Duration(seconds: _bucketSeconds * _bucketCount));

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(hostId)
          .collection('reactions')
          .where('createdAt', isGreaterThan: Timestamp.fromDate(windowStart))
          .snapshots(),
      builder: (context, snapshot) {
        final List<QueryDocumentSnapshot> docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();

        final List<int> buckets = List.filled(_bucketCount, 0);
        final DateTime now = DateTime.now();
        for (final doc in docs) {
          final Timestamp? ts =
              (doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?;
          if (ts == null) continue;
          final int secondsAgo = now.difference(ts.toDate()).inSeconds;
          final int bucketFromEnd = secondsAgo ~/ _bucketSeconds;
          final int index = _bucketCount - 1 - bucketFromEnd;
          if (index >= 0 && index < _bucketCount) buckets[index]++;
        }

        final int maxCount = buckets.reduce((a, b) => a > b ? a : b);
        if (maxCount == 0) return const SizedBox.shrink();

        return Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < _bucketCount; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 4 + (buckets[i] / maxCount) * 22,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: buckets[i] == maxCount && maxCount > 1
                            ? const LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Color(0xFF2E6BFF),
                                  Color(0xFF35E1F2),
                                ],
                              )
                            : null,
                        color: buckets[i] == maxCount && maxCount > 1
                            ? null
                            : Colors.white54,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// Screen a viewer uses to watch someone else's live stream. Joins the
// same LiveKit room as an audience member (camera/mic off).
class LiveViewerScreen extends StatefulWidget {
  final String hostId;
  final String hostName;
  final String hostPhoto;
  final String roomName;
  final String title;

  const LiveViewerScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostPhoto,
    required this.roomName,
    this.title = '',
  });

  @override
  State<LiveViewerScreen> createState() => _LiveViewerScreenState();
}

class _LiveViewerScreenState extends State<LiveViewerScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  VideoTrack? _hostVideoTrack;
  StreamSubscription<DocumentSnapshot>? _statusSub;

  bool _connecting = true;
  bool _ended = false;
  String? _error;

  String get _myId => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    // Don't let the phone dim/lock while watching a live stream.
    WakelockPlus.enable();
    _join();
    _watchStatus();
  }

  void _watchStatus() {
    _statusSub = FirebaseFirestore.instance
        .collection('liveStreams')
        .doc(widget.hostId)
        .snapshots()
        .listen((doc) {
      final data = doc.data();
      if (!doc.exists || data?['status'] != 'live') {
        if (mounted && !_ended) {
          setState(() => _ended = true);
        }
      }
    });
  }

  Future<void> _join() async {
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.email?.split('@').first ?? 'Viewer';

    final details = await _fetchLiveKitConnectionDetails(
      roomName: widget.roomName,
      participantName: myName,
    );

    if (details == null) {
      setState(() {
        _connecting = false;
        _error = 'Could not join the live stream.';
      });
      return;
    }

    try {
      final room = Room();
      final listener = room.createListener();
      listener
        ..on<TrackSubscribedEvent>((event) => _refreshHostTrack())
        ..on<TrackUnsubscribedEvent>((event) => _refreshHostTrack())
        ..on<ParticipantDisconnectedEvent>((event) {
          if (mounted) setState(() => _ended = true);
        });

      await room.connect(details['url']!, details['token']!);
      await room.localParticipant?.setCameraEnabled(false);
      await room.localParticipant?.setMicrophoneEnabled(false);

      if (!mounted) return;
      setState(() {
        _room = room;
        _listener = listener;
        _connecting = false;
      });
      _refreshHostTrack();

      // Mark myself as a viewer so the host sees the count go up
      if (_myId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('liveStreams')
            .doc(widget.hostId)
            .collection('viewers')
            .doc(_myId)
            .set({'joinedAt': FieldValue.serverTimestamp()});
      }
    } catch (e) {
      setState(() {
        _connecting = false;
        _error = 'Could not join the live stream:\n$e';
      });
    }
  }

  void _refreshHostTrack() {
    final room = _room;
    if (room == null) return;
    VideoTrack? track;
    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null) {
          track = pub.track as VideoTrack;
          break;
        }
      }
      if (track != null) break;
    }
    if (mounted) setState(() => _hostVideoTrack = track);
  }

  Future<void> _leave() async {
    _statusSub?.cancel();
    if (_myId.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(widget.hostId)
          .collection('viewers')
          .doc(_myId)
          .delete()
          .catchError((_) {});
    }
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _statusSub?.cancel();
    _listener?.dispose();
    _room?.disconnect();
    if (_myId.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(widget.hostId)
          .collection('viewers')
          .doc(_myId)
          .delete()
          .catchError((_) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_ended)
            const Center(
              child: Text('This live stream has ended',
                  style: TextStyle(color: Colors.white)),
            )
          else if (_connecting)
            const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            )
          else if (_error != null)
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: SelectableText(_error!,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center),
              ),
            )
          else if (_hostVideoTrack != null)
            VideoTrackRenderer(_hostVideoTrack!)
          else
            const Center(
              child: Text('Waiting for host video...',
                  style: TextStyle(color: Colors.white54)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.grey[850],
                    backgroundImage: widget.hostPhoto.isNotEmpty
                        ? NetworkImage(widget.hostPhoto)
                        : null,
                    child: widget.hostPhoto.isEmpty
                        ? Text(
                            widget.hostName.isNotEmpty
                                ? widget.hostName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(color: Colors.white),
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                widget.hostName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        if (widget.title.isNotEmpty)
                          Text(
                            widget.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: _leave,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_ended)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton(
                  onPressed: _leave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  child: const Text('Close'),
                ),
              ),
            ),
          if (!_connecting && !_ended && _error == null)
            LiveInteractionLayer(hostId: widget.hostId),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// "Who's live now" bar (shown in the home feed)
// ---------------------------------------------------------------------

class LiveBadgeBar extends StatelessWidget {
  const LiveBadgeBar({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('liveStreams')
          .where('status', isEqualTo: 'live')
          .snapshots(),
      builder: (context, liveSnapshot) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('liveStreams')
              .where('status', isEqualTo: 'ended')
              .where(
                'endedAt',
                isGreaterThan: Timestamp.fromDate(
                  DateTime.now().subtract(const Duration(hours: 24)),
                ),
              )
              .snapshots(),
          builder: (context, endedSnapshot) {
            final liveDocs = liveSnapshot.data?.docs ?? [];
            final endedDocs = endedSnapshot.data?.docs ?? [];
            if (liveDocs.isEmpty && endedDocs.isEmpty) {
              return const SizedBox.shrink();
            }

            // Live ones first, then recently-ended ones (as recaps)
            final List<_LiveBarEntry> entries = [
              ...liveDocs.map((d) => _LiveBarEntry(doc: d, isLive: true)),
              ...endedDocs.map((d) => _LiveBarEntry(doc: d, isLive: false)),
            ];

            return SizedBox(
              height: 92,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final data = entry.doc.data() as Map<String, dynamic>;
                  final String hostId = data['hostId'] ?? '';
                  final String hostName = data['hostName'] ?? 'Someone';
                  final String hostPhoto = data['hostPhoto'] ?? '';
                  final String roomName = data['roomName'] ?? '';
                  final String title = data['title'] ?? '';

                  return GestureDetector(
                    onTap: () {
                      if (entry.isLive) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LiveViewerScreen(
                              hostId: hostId,
                              hostName: hostName,
                              hostPhoto: hostPhoto,
                              roomName: roomName,
                              title: title,
                            ),
                          ),
                        );
                      } else {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LiveRecapScreen(
                              hostId: hostId,
                              hostName: hostName,
                              hostPhoto: hostPhoto,
                              title: title,
                            ),
                          ),
                        );
                      }
                    },
                    child: Container(
                      width: 68,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: entry.isLive
                                  ? const LinearGradient(
                                      colors: [Colors.redAccent, Colors.orange],
                                    )
                                  : LinearGradient(
                                      colors: [
                                        Colors.grey[600]!,
                                        Colors.grey[800]!
                                      ],
                                    ),
                            ),
                            child: CircleAvatar(
                              radius: 28,
                              backgroundColor: Colors.grey[850],
                              backgroundImage: hostPhoto.isNotEmpty
                                  ? NetworkImage(hostPhoto)
                                  : null,
                              child: hostPhoto.isEmpty
                                  ? Text(
                                      hostName.isNotEmpty
                                          ? hostName[0].toUpperCase()
                                          : '?',
                                      style:
                                          const TextStyle(color: Colors.white),
                                    )
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color:
                                  entry.isLive ? Colors.red : Colors.grey[700],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              entry.isLive ? 'LIVE' : 'ENDED',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _LiveBarEntry {
  final QueryDocumentSnapshot doc;
  final bool isLive;

  _LiveBarEntry({required this.doc, required this.isLive});
}

// ---------------------------------------------------------------------
// Live comments + reactions overlay (used by both host and viewer)
// ---------------------------------------------------------------------

// Shared quick-reaction emoji set for live streams
const List<String> kLiveReactions = ['❤️', '😂', '😮', '👏', '🔥'];

// Comment input + scrolling comment feed + reaction button + flying
// reaction animations. Dropped into both GoLiveScreen and
// LiveViewerScreen so hosts and viewers see the same engagement.
class LiveInteractionLayer extends StatefulWidget {
  final String hostId;

  const LiveInteractionLayer({super.key, required this.hostId});

  @override
  State<LiveInteractionLayer> createState() => _LiveInteractionLayerState();
}

class _LiveInteractionLayerState extends State<LiveInteractionLayer> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  final List<_LiveFlyingReaction> _flyingReactions = [];
  StreamSubscription<QuerySnapshot>? _reactionSub;
  bool _firstReactionSnapshot = true;
  int _nextReactionId = 0;

  final List<LiveFlyingGift> _flyingGifts = [];
  StreamSubscription<QuerySnapshot>? _giftSub;
  bool _firstGiftSnapshot = true;
  int _nextGiftId = 0;

  @override
  void initState() {
    super.initState();
    _listenForReactions();
    _listenForGifts();
  }

  // Watches for reactions from ANYONE in the live (host + all viewers) so
  // everybody sees the same hearts/emojis fly, not just their own taps.
  void _listenForReactions() {
    _reactionSub = FirebaseFirestore.instance
        .collection('liveStreams')
        .doc(widget.hostId)
        .collection('reactions')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (_firstReactionSnapshot) {
        _firstReactionSnapshot = false;
        return;
      }
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data() as Map<String, dynamic>?;
          _addFlyingReaction(data?['emoji'] as String? ?? '❤️');
        }
      }
    });
  }

  void _addFlyingReaction(String emoji) {
    if (!mounted) return;
    final int id = _nextReactionId++;
    final reaction = _LiveFlyingReaction(
      id: id,
      emoji: emoji,
      startX: (id % 5) * 12.0,
    );
    setState(() => _flyingReactions.add(reaction));
  }

  void _removeFlyingReaction(int id) {
    if (mounted) {
      setState(() => _flyingReactions.removeWhere((r) => r.id == id));
    }
  }

  // Watches for gifts sent by ANYONE in the live, same pattern as
  // reactions above, so every gift banner shows for the whole audience,
  // not just the sender.
  void _listenForGifts() {
    _giftSub = FirebaseFirestore.instance
        .collection('liveStreams')
        .doc(widget.hostId)
        .collection('gifts')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (_firstGiftSnapshot) {
        _firstGiftSnapshot = false;
        return;
      }
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data() as Map<String, dynamic>?;
          _addFlyingGift(
            emoji: data?['emoji'] as String? ?? '🎁',
            giftName: data?['giftName'] as String? ?? 'Gift',
            senderName: data?['senderName'] as String? ?? 'Someone',
          );
        }
      }
    });
  }

  void _addFlyingGift({
    required String emoji,
    required String giftName,
    required String senderName,
  }) {
    if (!mounted) return;
    final int id = _nextGiftId++;
    setState(() => _flyingGifts.add(LiveFlyingGift(
          id: id,
          emoji: emoji,
          giftName: giftName,
          senderName: senderName,
        )));
  }

  void _removeFlyingGift(int id) {
    if (mounted) {
      setState(() => _flyingGifts.removeWhere((g) => g.id == id));
    }
  }

  void _openGiftPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      builder: (ctx) => GiftPickerSheet(hostId: widget.hostId),
    );
  }

  void _openTopSupporters() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) => TopSupportersSheet(hostId: widget.hostId),
    );
  }

  Future<void> _sendReaction(String emoji) async {
    // Show it locally right away so it feels instant, then write it so
    // everyone else sees it too.
    _addFlyingReaction(emoji);
    final user = FirebaseAuth.instance.currentUser;
    try {
      await FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(widget.hostId)
          .collection('reactions')
          .add({
        'emoji': emoji,
        'userId': user?.uid ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Reactions are best-effort, fine to drop if this fails
    }
  }

  Future<void> _sendComment() async {
    final String text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();

    final user = FirebaseAuth.instance.currentUser;
    String name = user?.email?.split('@').first ?? 'Someone';
    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user?.uid)
          .get();
      final data = profile.data();
      name = (data?['displayName'] as String?)?.trim().isNotEmpty == true
          ? data!['displayName']
          : name;
    } catch (_) {
      // Keep fallback name
    }

    try {
      await FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(widget.hostId)
          .collection('comments')
          .add({
        'userId': user?.uid ?? '',
        'userName': name,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      // Keep the keyboard up so several comments can be sent in a row.
      if (mounted) _commentFocus.requestFocus();
    } catch (e) {
      // Don't fail silently - a swallowed error here just looks like
      // "the send button does nothing".
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send comment: $e')),
        );
        // Put the text back so it isn't lost.
        _commentController.text = text;
      }
    }
  }

  @override
  void dispose() {
    _reactionSub?.cancel();
    _giftSub?.cancel();
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ..._flyingReactions.map((r) {
          return Positioned(
            right: 24,
            bottom: 130,
            child: _LiveFlyingReactionWidget(
              key: ValueKey(r.id),
              data: r,
              onComplete: () => _removeFlyingReaction(r.id),
            ),
          );
        }),
        // Gift banners stack just above the reactions/comment area, most
        // recent at the bottom, so several gifts in quick succession
        // don't overlap illegibly.
        Positioned(
          left: 12,
          right: 12,
          bottom: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _flyingGifts.map((g) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: LiveFlyingGiftWidget(
                  key: ValueKey(g.id),
                  data: g,
                  onComplete: () => _removeFlyingGift(g.id),
                ),
              );
            }).toList(),
          ),
        ),
        Positioned(
          top: 8,
          right: 12,
          child: SafeArea(
            bottom: false,
            child: GestureDetector(
              onTap: _openTopSupporters,
              child: const CoinBalanceBadge(),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 64,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 150,
                    child: StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('liveStreams')
                          .doc(widget.hostId)
                          .collection('comments')
                          .orderBy('createdAt', descending: true)
                          .limit(30)
                          .snapshots(),
                      builder: (context, snap) {
                        final docs = snap.data?.docs ?? [];
                        if (docs.isEmpty) return const SizedBox.shrink();
                        return ListView.builder(
                          reverse: true,
                          padding: EdgeInsets.zero,
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final data =
                                docs[index].data() as Map<String, dynamic>;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.4),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: RichText(
                                    text: TextSpan(
                                      children: [
                                        TextSpan(
                                          text:
                                              '${data['userName'] ?? 'Someone'}  ',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        TextSpan(
                                          text: data['text'] ?? '',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.only(
                        left: 14, right: 4, top: 4, bottom: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            focusNode: _commentFocus,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              hintText: 'Say something...',
                              hintStyle: TextStyle(color: Colors.white54),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendComment(),
                          ),
                        ),
                        // Explicit send button - don't depend on the
                        // keyboard exposing a "send" key, since many
                        // keyboards show a newline key instead. Drawn as
                        // a solid filled circle so it stays visible over
                        // a bright video background.
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _commentController,
                          builder: (context, value, _) {
                            final bool canSend = value.text.trim().isNotEmpty;
                            return GestureDetector(
                              onTap: canSend ? _sendComment : null,
                              child: Container(
                                margin: const EdgeInsets.only(left: 8),
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: canSend
                                      ? Colors.redAccent
                                      : Colors.white24,
                                ),
                                child: const Icon(
                                  Icons.send_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 76,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                GestureDetector(
                  onTap: _openGiftPicker,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Text('🎁', style: TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => _sendReaction('❤️'),
                  onLongPress: () => _showReactionPicker(context),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.favorite,
                        color: Colors.redAccent, size: 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showReactionPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: kLiveReactions.map((emoji) {
              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  _sendReaction(emoji);
                },
                child: Text(emoji, style: const TextStyle(fontSize: 32)),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _LiveFlyingReaction {
  final int id;
  final String emoji;
  final double startX;

  _LiveFlyingReaction({
    required this.id,
    required this.emoji,
    required this.startX,
  });
}

// Animates one reaction emoji floating upward while fading out, mirroring
// the flying-emoji effect used on regular video posts.
class _LiveFlyingReactionWidget extends StatefulWidget {
  final _LiveFlyingReaction data;
  final VoidCallback onComplete;

  const _LiveFlyingReactionWidget({
    super.key,
    required this.data,
    required this.onComplete,
  });

  @override
  State<_LiveFlyingReactionWidget> createState() =>
      _LiveFlyingReactionWidgetState();
}

class _LiveFlyingReactionWidgetState extends State<_LiveFlyingReactionWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onComplete();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value;
        final double offsetY = -260 * t;
        final double offsetX = widget.data.startX * (1 - t);
        final double opacity = t < 0.7 ? 1.0 : (1.0 - (t - 0.7) / 0.3);
        final double scale = 0.6 + 0.6 * t;

        return Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Text(widget.data.emoji, style: const TextStyle(fontSize: 28)),
    );
  }
}

// ---------------------------------------------------------------------
// Recap screen for a live that has ended
// ---------------------------------------------------------------------

// NOTE: Fly doesn't record live video (that needs LiveKit Cloud's paid
// Egress feature plus a backend to call it securely, neither of which
// this project has set up). So instead of the video, an ended live keeps
// its title, host info, and full comment thread visible here.
class LiveRecapScreen extends StatelessWidget {
  final String hostId;
  final String hostName;
  final String hostPhoto;
  final String title;

  const LiveRecapScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostPhoto,
    this.title = '',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Live ended', style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Colors.grey[850],
                  backgroundImage:
                      hostPhoto.isNotEmpty ? NetworkImage(hostPhoto) : null,
                  child: hostPhoto.isEmpty
                      ? Text(
                          hostName.isNotEmpty ? hostName[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(hostName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      if (title.isNotEmpty)
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Video replay isn\'t available for this live yet - here\'s '
                'what people said during it:',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('liveStreams')
                  .doc(hostId)
                  .collection('comments')
                  .orderBy('createdAt', descending: false)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('No comments on this live',
                        style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '${data['userName'] ?? 'Someone'}  ',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(
                              text: data['text'] ?? '',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

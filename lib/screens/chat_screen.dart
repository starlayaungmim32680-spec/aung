import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'public_profile_screen.dart';
import 'video_call_screen.dart';
import '../call_kit_service.dart';
import 'call_push_service.dart';
import '../block_service.dart';
import 'presence_badge.dart';
import 'worker_auth.dart';

// Chat photos and voice notes go to Bunny Storage through the Worker's
// /upload-image pass-through (1 Oct 2026) - the same path story images and
// profile photos use. They used to go to Cloudinary, whose account is
// disabled, so sending a photo or voice note failed.
const String _bunnyChatCdnHostname = 'fly-images-aungdev756617.b-cdn.net';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Streams are built ONCE here, never inside build() (1 Oct 2026). Before,
  // every rebuild (a block-list update, typing in search) threw away the
  // listener and started a new one, which goes back to "waiting" - on a slow
  // connection the list could spin forever and only showed when offline
  // (where the cache answers instantly).
  late final Stream<QuerySnapshot> _usersStream;
  Stream<QuerySnapshot>? _chatsStream;

  // Blocked accounts (either way - see block_service.dart) disappear from
  // the list and the "online now" strip.
  @override
  void initState() {
    super.initState();
    _usersStream = FirebaseFirestore.instance.collection('users').snapshots();
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      _chatsStream = FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: myId)
          .snapshots();
    }
    BlockService.instance.hidden.addListener(_onBlockedChanged);
  }

  void _onBlockedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Messages', style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.trim().toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: 'Search users...',
                hintStyle: const TextStyle(color: Colors.grey),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.grey[900],
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _usersStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        "Couldn't load chats. Check your connection.",
                        style: TextStyle(color: Colors.grey[600], fontSize: 15),
                      ),
                    );
                  }
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                var users = (snapshot.data?.docs ?? [])
                    .where((doc) =>
                        doc.id != currentUser?.uid &&
                        !BlockService.instance.isHidden(doc.id))
                    .toList();

                if (_searchQuery.isNotEmpty) {
                  users = users.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final name =
                        (data['displayName'] ?? '').toString().toLowerCase();
                    return name.contains(_searchQuery);
                  }).toList();
                }

                if (users.isEmpty) {
                  return Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No users found'
                          : 'No other users yet',
                      style: TextStyle(color: Colors.grey[600], fontSize: 15),
                    ),
                  );
                }

                // Whoever you most recently messaged OR called should sit
                // at the top of the list, like every other chat app - this
                // reads the same `chats` docs that sending a message
                // (lastMessageAt) and starting a call (lastCallAt, see
                // _startVideoCall below) already write.
                return StreamBuilder<QuerySnapshot>(
                  stream: _chatsStream,
                  builder: (context, chatSnap) {
                    final Map<String, DateTime> lastActivity = {};
                    for (final doc in chatSnap.data?.docs ?? []) {
                      final data = doc.data() as Map<String, dynamic>;
                      final participants =
                          (data['participants'] as List?)?.cast<String>() ??
                              const [];
                      final String otherId = participants.firstWhere(
                        (id) => id != currentUser?.uid,
                        orElse: () => '',
                      );
                      if (otherId.isEmpty) continue;
                      final DateTime? msgAt =
                          (data['lastMessageAt'] as Timestamp?)?.toDate();
                      final DateTime? callAt =
                          (data['lastCallAt'] as Timestamp?)?.toDate();
                      DateTime? latest = msgAt;
                      if (callAt != null &&
                          (latest == null || callAt.isAfter(latest))) {
                        latest = callAt;
                      }
                      if (latest != null) lastActivity[otherId] = latest;
                    }

                    final sortedUsers = List.of(users)
                      ..sort((a, b) {
                        final DateTime? aTime = lastActivity[a.id];
                        final DateTime? bTime = lastActivity[b.id];
                        if (aTime != null && bTime != null) {
                          return bTime.compareTo(aTime);
                        }
                        if (aTime != null) return -1;
                        if (bTime != null) return 1;
                        // Neither has chatted/called yet - keep a stable,
                        // deterministic order instead of an unstable sort
                        // leaving them to flicker between rebuilds.
                        return a.id.compareTo(b.id);
                      });

                    final onlineUsers = _searchQuery.isNotEmpty
                        ? const <QueryDocumentSnapshot>[]
                        : sortedUsers
                            .where((doc) => isUserOnline(
                                doc.data() as Map<String, dynamic>))
                            .toList();

                    return Column(
                      children: [
                        if (onlineUsers.isNotEmpty)
                          _OnlineNowStrip(users: onlineUsers),
                        Expanded(
                          child: ListView.builder(
                            itemCount: sortedUsers.length,
                            itemBuilder: (context, index) {
                              final userData = sortedUsers[index].data()
                                  as Map<String, dynamic>;
                              final String otherUserId = sortedUsers[index].id;
                              final String displayName =
                                  userData['displayName'] ?? 'User';
                              final String photoUrl =
                                  userData['photoUrl'] ?? '';
                              final bool isOnline = isUserOnline(userData);

                              return ListTile(
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => PublicProfileScreen(
                                          userId: otherUserId),
                                    ),
                                  );
                                },
                                leading: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          colors: [
                                            Color(0xFFFF4B6E),
                                            Color(0xFF9C4DFF)
                                          ],
                                        ),
                                      ),
                                      child: CircleAvatar(
                                        radius: 24,
                                        backgroundColor: Colors.grey[850],
                                        backgroundImage: photoUrl.isNotEmpty
                                            ? NetworkImage(photoUrl)
                                            : null,
                                        child: photoUrl.isEmpty
                                            ? Text(
                                                displayName.isNotEmpty
                                                    ? displayName[0]
                                                        .toUpperCase()
                                                    : '?',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 18,
                                                ),
                                              )
                                            : null,
                                      ),
                                    ),
                                    if (isOnline)
                                      const Positioned(
                                        right: -2,
                                        bottom: -2,
                                        child: SparkleStarBadge(),
                                      ),
                                  ],
                                ),
                                title: Text(
                                  displayName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: const Icon(Icons.chevron_right,
                                    color: Colors.grey),
                              );
                            },
                          ),
                        ),
                      ],
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

// Horizontal strip of currently-online users, shown above the main Chat
// list - Fly's own take on the "Active now" row other chat apps show,
// using the sparkle-star badge instead of a plain green dot.
class _OnlineNowStrip extends StatelessWidget {
  final List<QueryDocumentSnapshot> users;

  const _OnlineNowStrip({required this.users});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: users.length,
        itemBuilder: (context, index) {
          final data = users[index].data() as Map<String, dynamic>;
          final String userId = users[index].id;
          final String displayName = data['displayName'] ?? 'User';
          final String photoUrl = data['photoUrl'] ?? '';

          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PublicProfileScreen(userId: userId),
                ),
              );
            },
            child: Container(
              width: 68,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                          ),
                        ),
                        child: CircleAvatar(
                          radius: 26,
                          backgroundColor: Colors.grey[850],
                          backgroundImage: photoUrl.isNotEmpty
                              ? NetworkImage(photoUrl)
                              : null,
                          child: photoUrl.isEmpty
                              ? Text(
                                  displayName.isNotEmpty
                                      ? displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const Positioned(
                        right: -2,
                        bottom: -2,
                        child: SparkleStarBadge(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// One-on-one chat conversation screen
class ChatThreadScreen extends StatefulWidget {
  final String otherUserId;
  final String otherUserName;
  final String otherUserPhoto;

  const ChatThreadScreen({
    super.key,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserPhoto,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isUploading = false;

  // Voice recording
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _recorderReady = false;
  bool _isRecording = false;
  String? _recordPath;
  bool _hasText = false;
  StreamSubscription? _recorderSub;
  final ValueNotifier<List<double>> _waveBars = ValueNotifier<List<double>>([]);

  // Typing / recording activity indicator (WhatsApp-style)
  Timer? _typingTimer;
  String? _currentActivity;

  // Built once in initState - never inside build() (see ChatScreen above):
  // this screen rebuilds a lot (recording, typing, uploading), and each
  // rebuild used to restart these listeners.
  late final Stream<QuerySnapshot> _messagesStream;
  late final Stream<DocumentSnapshot> _activityStream;

  // Blocked either way (see block_service.dart): no sending, no calls.
  bool get _blocked => BlockService.instance.isHidden(widget.otherUserId);
  bool get _iBlockedThem =>
      BlockService.instance.blockedByMe.value.contains(widget.otherUserId);

  void _onBlockedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    final chatDoc = FirebaseFirestore.instance.collection('chats').doc(_chatId);
    _messagesStream = chatDoc
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();
    _activityStream =
        chatDoc.collection('activity').doc(widget.otherUserId).snapshots();
    BlockService.instance.hidden.addListener(_onBlockedChanged);
    _initRecorder();
    _messageController.addListener(() {
      final bool has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) {
        setState(() => _hasText = has);
      }
      _onTyping(has);
    });
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
    }
  }

  Future<void> _initRecorder() async {
    try {
      await _recorder.openRecorder();
      await _recorder
          .setSubscriptionDuration(const Duration(milliseconds: 100));
      _recorderReady = true;
    } catch (e) {
      _showError('Recorder init failed: $e');
    }
  }

  String get _chatId {
    final myId = FirebaseAuth.instance.currentUser!.uid;
    final ids = [myId, widget.otherUserId]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  // Writes my current activity (typing/recording/idle) to a separate
  // subcollection so it doesn't disturb the main chat doc or notifications
  Future<void> _setActivity(String? status) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    final normalized = status ?? 'idle';
    if (_currentActivity == normalized) return;
    _currentActivity = normalized;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('activity')
          .doc(myId)
          .set({
        'status': normalized,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // Called on each keystroke - shows "typing" then auto-clears after a pause
  void _onTyping(bool has) {
    _typingTimer?.cancel();
    if (has) {
      _setActivity('typing');
      _typingTimer = Timer(const Duration(seconds: 4), () {
        _setActivity(null);
      });
    } else {
      _setActivity(null);
    }
  }

  @override
  void dispose() {
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
    _typingTimer?.cancel();
    _setActivity(null);
    _messageController.dispose();
    _scrollController.dispose();
    _recorderSub?.cancel();
    _waveBars.dispose();
    if (_recorderReady) _recorder.closeRecorder();
    super.dispose();
  }

  Future<void> _afterSend(String previewText) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
      'participants': [myId, widget.otherUserId],
      'lastMessage': previewText,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastSenderId': myId,
    }, SetOptions(merge: true));

    final myProfile =
        await FirebaseFirestore.instance.collection('users').doc(myId).get();
    final myData = myProfile.data();
    final String myName =
        (myData?['displayName'] as String?)?.trim().isNotEmpty == true
            ? myData!['displayName']
            : 'Someone';
    final String myPhoto = (myData?['photoUrl'] as String?) ?? '';

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.otherUserId)
        .collection('notifications')
        .add({
      'type': 'message',
      'text': previewText,
      'fromId': myId,
      'fromName': myName,
      'fromPhoto': myPhoto,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _sendMessage() async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    final String text = _messageController.text.trim();
    if (myId == null || text.isEmpty) return;

    _messageController.clear();
    _setActivity(null);

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .add({
      'senderId': myId,
      'type': 'text',
      'text': text,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _afterSend(text);
  }

  // File extension (from the recorder's codec) -> MIME type for Bunny.
  static const Map<String, String> _audioContentTypes = {
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
  };

  // Uploads a chat photo / voice note to Bunny Storage via the Worker and
  // returns its public URL, or null (after showing a friendly error) if it
  // failed. The file name must start with my own uid - the Worker rejects
  // anything else - and stays plain ASCII (it travels in an HTTP header).
  Future<String?> _uploadChatFile(
    File file, {
    required String extension,
    required String contentType,
  }) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return null;
    try {
      final bytes = await file.readAsBytes();
      final String fileName =
          '${myId}_chat_${DateTime.now().millisecondsSinceEpoch}.$extension';
      final response = await http
          .post(
            Uri.parse('$kTokenServerUrl/upload-image'),
            headers: {
              ...await workerAuthHeaders(),
              'X-File-Name': fileName,
              'Content-Type': contentType,
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        _showError("Couldn't send it. Please try again.");
        return null;
      }
      return 'https://$_bunnyChatCdnHostname/$fileName';
    } catch (_) {
      _showError("Couldn't send it. Check your connection and try again.");
      return null;
    }
  }

  Future<void> _pickAndSendImage() async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    if (picked == null) return;

    setState(() => _isUploading = true);

    try {
      final String? imageUrl = await _uploadChatFile(
        File(picked.path),
        extension: 'jpg',
        contentType: 'image/jpeg',
      );

      if (imageUrl != null) {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_chatId)
            .collection('messages')
            .add({
          'senderId': myId,
          'type': 'image',
          'imageUrl': imageUrl,
          'text': '',
          'seen': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        await _afterSend('📷 Photo');
      }
    } catch (e) {
      _showError('Send image failed: $e');
    }

    if (mounted) setState(() => _isUploading = false);
  }

  // Starts recording a voice note
  Future<void> _startRecording() async {
    if (!_recorderReady) {
      _showError('Recorder not ready');
      return;
    }

    // Ask for microphone permission before recording
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _showError('Microphone permission denied');
      return;
    }

    // Pick the first codec this device actually supports
    final options = <Codec, String>{
      Codec.aacMP4: 'm4a',
      Codec.aacADTS: 'aac',
      Codec.opusOGG: 'ogg',
      Codec.pcm16WAV: 'wav',
    };
    Codec? chosenCodec;
    String ext = 'm4a';
    for (final entry in options.entries) {
      if (await _recorder.isEncoderSupported(entry.key)) {
        chosenCodec = entry.key;
        ext = entry.value;
        break;
      }
    }
    if (chosenCodec == null) {
      _showError('No supported audio encoder on this device');
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _recorder.startRecorder(toFile: path, codec: chosenCodec);

      // Tell the other person I'm recording audio
      _setActivity('recording');

      // Listen to the recorder's volume to draw live waveform bars.
      _waveBars.value = [];
      _recorderSub = _recorder.onProgress!.listen((event) {
        final double db = event.decibels ?? 0;
        double level = (db / 60).clamp(0.0, 1.0);
        if (level < 0.1) level = 0.1;
        final updated = List<double>.from(_waveBars.value)..add(level);
        if (updated.length > 40) {
          updated.removeAt(0);
        }
        _waveBars.value = updated;
      });

      setState(() {
        _isRecording = true;
        _recordPath = path;
      });
    } catch (e) {
      _showError('Start recording failed: $e');
    }
  }

  // Stops recording and uploads/sends the voice note
  Future<void> _stopAndSendRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.stopRecorder();
    } catch (e) {
      _showError('Stop recording failed: $e');
    }
    await _recorderSub?.cancel();
    _recorderSub = null;
    _setActivity(null);
    setState(() => _isRecording = false);

    final myId = FirebaseAuth.instance.currentUser?.uid;
    final path = _recordPath;
    if (myId == null || path == null) return;

    // Give the recorder a moment to finish writing the file to disk
    await Future.delayed(const Duration(milliseconds: 500));

    // Make sure the recording actually captured audio (not an empty file)
    final file = File(path);
    final int fileLength = await file.exists() ? await file.length() : 0;
    if (fileLength < 1000) {
      _showError('Recording too short ($fileLength bytes) - hold longer');
      return;
    }

    setState(() => _isUploading = true);

    try {
      final String ext = path.split('.').last.toLowerCase();
      final String? audioUrl = await _uploadChatFile(
        file,
        extension: ext,
        contentType: _audioContentTypes[ext] ?? 'application/octet-stream',
      );

      if (audioUrl != null) {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_chatId)
            .collection('messages')
            .add({
          'senderId': myId,
          'type': 'audio',
          'audioUrl': audioUrl,
          'text': '',
          'seen': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        await _afterSend('🎤 Voice message');
      }
    } catch (e) {
      _showError('Send voice failed: $e');
    }

    if (mounted) setState(() => _isUploading = false);
  }

  // Cancels the current recording without sending
  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.stopRecorder();
    } catch (_) {}
    await _recorderSub?.cancel();
    _recorderSub = null;
    _setActivity(null);
    setState(() => _isRecording = false);
  }

  // Deletes a message (only your own). Long-press a bubble to trigger this.
  Future<void> _deleteMessage(String messageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete message?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This message will be removed for everyone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .doc(messageId)
          .delete();
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  void _viewImage(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(url),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _markMessagesAsSeen(List<QueryDocumentSnapshot> messages) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    final batch = FirebaseFirestore.instance.batch();
    bool hasUnseen = false;

    for (final doc in messages) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['senderId'] == widget.otherUserId && data['seen'] != true) {
        batch.update(doc.reference, {'seen': true});
        hasUnseen = true;
      }
    }

    if (hasUnseen) {
      await batch.commit();
    }
  }

  // Replaces the message box when either side has blocked the other -
  // like Messenger's "You can't reply to this conversation".
  Widget _blockedBanner() {
    final bool iBlocked = _iBlockedThem;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          20, 14, 20, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.block, color: Colors.white38, size: 22),
          const SizedBox(height: 6),
          Text(
            iBlocked
                ? "You blocked this account. You can't message or call them."
                : "You can't reply to this conversation.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          if (iBlocked) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                try {
                  await BlockService.instance.unblock(widget.otherUserId);
                } catch (_) {
                  _showError("Couldn't unblock. Please try again.");
                }
              },
              child: const Text('Unblock',
                  style: TextStyle(
                      color: Color(0xFF3A8DFF), fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _startVideoCall({required bool withCamera}) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    final myProfile =
        await FirebaseFirestore.instance.collection('users').doc(myId).get();
    final myData = myProfile.data();
    final String myName =
        (myData?['displayName'] as String?)?.trim().isNotEmpty == true
            ? myData!['displayName']
            : 'Someone';
    final String myPhoto = (myData?['photoUrl'] as String?) ?? '';

    await FirebaseFirestore.instance.collection('calls').doc(_chatId).set({
      'callerId': myId,
      'callerName': myName,
      'callerPhoto': myPhoto,
      'calleeId': widget.otherUserId,
      'roomName': _chatId,
      'status': 'ringing',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // Also marks this as a chat "activity" (separate from lastMessageAt,
    // which is only for actual text/media messages) so the Chat list can
    // bump this person to the top even if no message was ever sent - see
    // _ChatScreenState's sorting in this same file.
    await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
      'participants': [myId, widget.otherUserId],
      'lastCallAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Best-effort - wakes the other person's phone even if they've
    // closed Fly entirely. The call still works normally without this
    // (via the Firestore listener) if they already have the app open.
    sendCallPush(
      calleeId: widget.otherUserId,
      callerId: myId,
      callerName: myName,
      callerPhoto: myPhoto,
      roomName: _chatId,
      isVideo: withCamera,
    );

    // Registers this side of the call with Android's own Telecom system
    // too, not just the person receiving it - see CallKitService's own
    // comment on why the caller needs this just as much.
    await CallKitService.startOutgoingCall(
      roomName: _chatId,
      otherName: widget.otherUserName,
      otherPhoto: widget.otherUserPhoto,
      isVideo: withCamera,
    );

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoCallScreen(
          roomName: _chatId,
          myName: myId,
          otherName: widget.otherUserName,
          otherPhoto: widget.otherUserPhoto,
          startWithCamera: withCamera,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.grey[850],
              backgroundImage: widget.otherUserPhoto.isNotEmpty
                  ? NetworkImage(widget.otherUserPhoto)
                  : null,
              child: widget.otherUserPhoto.isEmpty
                  ? Text(
                      widget.otherUserName.isNotEmpty
                          ? widget.otherUserName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            // Name + live activity status (typing / recording)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.otherUserName,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                StreamBuilder<DocumentSnapshot>(
                  stream: _activityStream,
                  builder: (context, snap) {
                    final data = snap.data?.data() as Map<String, dynamic>?;
                    final status = data?['status'] as String?;
                    String? label;
                    if (status == 'typing') {
                      label = 'typing...';
                    } else if (status == 'recording') {
                      label = 'recording audio...';
                    }
                    if (label == null) return const SizedBox.shrink();
                    return Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFF24D17E),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (!_blocked) ...[
            IconButton(
              icon: const Icon(Icons.call, color: Colors.white),
              tooltip: 'Voice call',
              onPressed: () => _startVideoCall(withCamera: false),
            ),
            IconButton(
              icon: const Icon(Icons.videocam, color: Colors.white),
              tooltip: 'Video call',
              onPressed: () => _startVideoCall(withCamera: true),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        "Couldn't load messages. Check your connection.",
                        style: TextStyle(color: Colors.grey[600], fontSize: 15),
                      ),
                    );
                  }
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                final messages = snapshot.data?.docs ?? [];

                if (messages.isNotEmpty) {
                  _markMessagesAsSeen(messages);
                }

                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      'Say hi to ${widget.otherUserName} 👋',
                      style: TextStyle(color: Colors.grey[600], fontSize: 15),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index].data() as Map<String, dynamic>;
                    final String messageId = messages[index].id;
                    final bool isMine = msg['senderId'] == myId;
                    // True while this message only exists in the local
                    // offline queue and hasn't reached Firestore's servers
                    // yet - Firestore already queues the write and sends it
                    // the moment the connection comes back on its own; this
                    // just surfaces that queued state in the UI instead of
                    // silently showing "Sent" for a message that hasn't
                    // actually left the phone.
                    final bool isPending =
                        messages[index].metadata.hasPendingWrites;
                    final String type = msg['type'] ?? 'text';
                    final String text = msg['text'] ?? '';
                    final String imageUrl = msg['imageUrl'] ?? '';
                    final String audioUrl = msg['audioUrl'] ?? '';
                    final bool seen = msg['seen'] == true;

                    Widget bubble;
                    if (type == 'image') {
                      bubble = GestureDetector(
                        onTap: () => _viewImage(imageUrl),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.6,
                              maxHeight: 260,
                            ),
                            child: Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              loadingBuilder: (context, child, progress) {
                                if (progress == null) return child;
                                return Container(
                                  width: 160,
                                  height: 160,
                                  color: Colors.grey[900],
                                  child: const Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white24,
                                      strokeWidth: 2,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    } else if (type == 'audio') {
                      bubble = _VoiceBubble(audioUrl: audioUrl, isMine: isMine);
                    } else {
                      // Reply sent from the story viewer (story_screen.dart):
                      // a small preview of the story above the text.
                      final String storyThumb =
                          (msg['storyThumb'] as String?) ?? '';
                      bubble = Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.7,
                        ),
                        decoration: BoxDecoration(
                          gradient: isMine
                              ? const LinearGradient(
                                  colors: [
                                    Color(0xFF3A8DFF),
                                    Color(0xFF1565C0)
                                  ],
                                )
                              : null,
                          color: isMine ? null : Colors.grey[850],
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMine ? 16 : 4),
                            bottomRight: Radius.circular(isMine ? 4 : 16),
                          ),
                        ),
                        child: storyThumb.isEmpty
                            ? Text(
                                text,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    isMine
                                        ? 'You replied to their story'
                                        : 'Replied to your story',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.network(
                                      storyThumb,
                                      width: 90,
                                      height: 140,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        width: 90,
                                        height: 140,
                                        color: Colors.black26,
                                        child: const Icon(
                                            Icons.auto_stories_outlined,
                                            color: Colors.white38),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    text,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 15),
                                  ),
                                ],
                              ),
                      );
                    }

                    return Column(
                      crossAxisAlignment: isMine
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: isMine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: GestureDetector(
                              onLongPress: isMine
                                  ? () => _deleteMessage(messageId)
                                  : null,
                              child: bubble,
                            ),
                          ),
                        ),
                        if (isMine)
                          Padding(
                            padding: const EdgeInsets.only(
                                top: 2, right: 4, bottom: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isPending
                                      ? Icons.access_time_rounded
                                      : seen
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                  size: 14,
                                  color: isPending
                                      ? Colors.grey
                                      : seen
                                          ? const Color(0xFF3A8DFF)
                                          : Colors.grey,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  isPending
                                      ? 'Sending...'
                                      : seen
                                          ? 'Seen'
                                          : 'Sent',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isPending
                                        ? Colors.grey
                                        : seen
                                            ? const Color(0xFF3A8DFF)
                                            : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          if (_isUploading)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              color: Colors.white.withOpacity(0.05),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        color: Colors.white54, strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Sending...',
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
            ),
          if (_isRecording)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: Colors.red.withOpacity(0.15),
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.redAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 34,
                      child: ValueListenableBuilder<List<double>>(
                        valueListenable: _waveBars,
                        builder: (context, bars, _) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: bars.map((level) {
                              return Container(
                                width: 3,
                                height: 34 * level,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 1),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _cancelRecording,
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ),
          if (_blocked)
            _blockedBanner()
          else
            Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 8,
                bottom: 8 + MediaQuery.of(context).padding.bottom + bottomInset,
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _isUploading ? null : _pickAndSendImage,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.image,
                          color: Color(0xFF3A8DFF), size: 24),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white),
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Message...',
                        hintStyle: const TextStyle(color: Colors.grey),
                        filled: true,
                        fillColor: Colors.grey[900],
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onLongPressStart:
                        _hasText ? null : (_) => _startRecording(),
                    onLongPressEnd:
                        _hasText ? null : (_) => _stopAndSendRecording(),
                    onTap: _hasText ? _sendMessage : null,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: _isRecording
                              ? [Colors.red, Colors.redAccent]
                              : [
                                  const Color(0xFF3A8DFF),
                                  const Color(0xFF1565C0)
                                ],
                        ),
                      ),
                      child: Icon(
                        (_isRecording || !_hasText) ? Icons.mic : Icons.send,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// A voice-message bubble with a play/pause button
class _VoiceBubble extends StatefulWidget {
  final String audioUrl;
  final bool isMine;

  const _VoiceBubble({required this.audioUrl, required this.isMine});

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.play(UrlSource(widget.audioUrl));
      setState(() => _isPlaying = true);
    }
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: widget.isMine
            ? const LinearGradient(
                colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
              )
            : null,
        color: widget.isMine ? null : Colors.grey[850],
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Icon(
              _isPlaying ? Icons.pause_circle : Icons.play_circle,
              color: Colors.white,
              size: 34,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.graphic_eq, color: Colors.white70, size: 22),
          const SizedBox(width: 6),
          const Text('Voice',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

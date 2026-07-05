import 'dart:convert';
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

// Cloudinary upload details (unsigned)
const String kCloudinaryImageUrl =
    'https://api.cloudinary.com/v1_1/dwx402gy4/image/upload';
// Voice notes are audio files - Cloudinary stores them under the "video" endpoint
const String kCloudinaryAudioUrl =
    'https://api.cloudinary.com/v1_1/dwx402gy4/video/upload';
const String kCloudinaryPreset = 'fly_unsigned';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
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
              stream:
                  FirebaseFirestore.instance.collection('users').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                var users = (snapshot.data?.docs ?? [])
                    .where((doc) => doc.id != currentUser?.uid)
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

                return ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final userData =
                        users[index].data() as Map<String, dynamic>;
                    final String otherUserId = users[index].id;
                    final String displayName =
                        userData['displayName'] ?? 'User';
                    final String photoUrl = userData['photoUrl'] ?? '';

                    return ListTile(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                PublicProfileScreen(userId: otherUserId),
                          ),
                        );
                      },
                      leading: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
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
                      title: Text(
                        displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing:
                          const Icon(Icons.chevron_right, color: Colors.grey),
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

  @override
  void initState() {
    super.initState();
    _initRecorder();
    _messageController.addListener(() {
      final bool has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) {
        setState(() => _hasText = has);
      }
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

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
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
      final request =
          http.MultipartRequest('POST', Uri.parse(kCloudinaryImageUrl));
      request.fields['upload_preset'] = kCloudinaryPreset;
      request.files.add(await http.MultipartFile.fromPath('file', picked.path));

      final response = await request.send();
      final respStr = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        final String imageUrl = data['secure_url'] as String;

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
      } else {
        _showError('Image upload failed: HTTP ${response.statusCode}');
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
      final request =
          http.MultipartRequest('POST', Uri.parse(kCloudinaryAudioUrl));
      request.fields['upload_preset'] = kCloudinaryPreset;
      request.files.add(await http.MultipartFile.fromPath('file', path));

      final response = await request.send();
      final respStr = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        final String audioUrl = data['secure_url'] as String;

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
      } else {
        _showError('Upload failed ${response.statusCode}: $respStr');
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
    setState(() => _isRecording = false);
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

  Future<void> _startVideoCall() async {
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

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoCallScreen(
          roomName: _chatId,
          myName: myId,
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
            Text(
              widget.otherUserName,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.white),
            onPressed: _startVideoCall,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_chatId)
                  .collection('messages')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
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
                    final bool isMine = msg['senderId'] == myId;
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
                        child: Text(
                          text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15),
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
                            child: bubble,
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
                                  seen
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                  size: 14,
                                  color: seen
                                      ? const Color(0xFF3A8DFF)
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  seen ? 'Seen' : 'Sent',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: seen
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
                  const Text('Recording... release to send',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  GestureDetector(
                    onTap: _cancelRecording,
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ),
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
                  onLongPressStart: _hasText ? null : (_) => _startRecording(),
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

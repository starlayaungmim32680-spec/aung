import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'public_profile_screen.dart';
import 'video_call_screen.dart';

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
          // Search bar to find users by name
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

          // User list
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

  // Builds a stable chat ID from the two user IDs (sorted so both sides match)
  String get _chatId {
    final myId = FirebaseAuth.instance.currentUser!.uid;
    final ids = [myId, widget.otherUserId]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
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
      'text': text,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
      'participants': [myId, widget.otherUserId],
      'lastMessage': text,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastSenderId': myId,
    }, SetOptions(merge: true));

    // Look up my profile, then send a message notification to the other user
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
      'text': text,
      'fromId': myId,
      'fromName': myName,
      'fromPhoto': myPhoto,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Marks all messages sent by the other user as seen (called when I view the chat)
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

  // Starts a video call: creates a call doc so the other user gets an incoming
  // call notification, then joins the room
  Future<void> _startVideoCall() async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    // Look up my name/photo so the callee sees who's calling
    final myProfile =
        await FirebaseFirestore.instance.collection('users').doc(myId).get();
    final myData = myProfile.data();
    final String myName =
        (myData?['displayName'] as String?)?.trim().isNotEmpty == true
            ? myData!['displayName']
            : 'Someone';
    final String myPhoto = (myData?['photoUrl'] as String?) ?? '';

    // Create/overwrite the call doc for this chat (status: ringing)
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

    // Caller joins the room and waits for the other person
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
          // Video call button
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
                    final String text = msg['text'] ?? '';
                    final bool seen = msg['seen'] == true;

                    return Column(
                      crossAxisAlignment: isMine
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Align(
                          alignment: isMine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(top: 4),
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
                          ),
                        ),
                        // Seen indicator - only shown under my own messages
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
          Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 8 + MediaQuery.of(context).padding.bottom + bottomInset,
            ),
            child: Row(
              children: [
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
                  onTap: _sendMessage,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
                      ),
                    ),
                    child:
                        const Icon(Icons.send, color: Colors.white, size: 20),
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

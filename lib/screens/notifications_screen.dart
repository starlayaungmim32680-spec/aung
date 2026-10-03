import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../block_service.dart';
import 'chat_screen.dart';
import 'public_profile_screen.dart';
import 'home_screen.dart' show PostFromNotificationScreen;

// Shows the current user's notifications (reactions, comments, messages,
// follows, friend requests / accepted requests)
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  // Marks all notifications as seen when the screen is opened
  Future<void> _markAllSeen(
      String myId, List<QueryDocumentSnapshot> docs) async {
    final batch = FirebaseFirestore.instance.batch();
    bool hasUnseen = false;
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['seen'] != true) {
        batch.update(doc.reference, {'seen': true});
        hasUnseen = true;
      }
    }
    if (hasUnseen) await batch.commit();
  }

  // Builds the action text shown for each notification type
  String _actionText(Map<String, dynamic> data) {
    final String type = data['type'] ?? '';
    final String text = data['text'] ?? '';
    switch (type) {
      case 'reaction':
        return 'reacted $text to your video';
      case 'comment':
        return 'commented: $text';
      case 'message':
        return 'sent you a message: $text';
      case 'follow':
        return 'started following you';
      case 'friend_request':
        return 'sent you a friend request';
      case 'friend_accept':
        return 'accepted your friend request 🎉';
      default:
        return 'did something';
    }
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'reaction':
        return Icons.favorite;
      case 'comment':
        return Icons.mode_comment;
      case 'message':
        return Icons.send;
      case 'follow':
        return Icons.person_add;
      case 'friend_request':
        return Icons.group_add;
      case 'friend_accept':
        return Icons.people_alt;
      default:
        return Icons.notifications;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'reaction':
        return const Color(0xFFFF4B6E);
      case 'comment':
        return const Color(0xFF3A8DFF);
      case 'message':
        return const Color(0xFF9C4DFF);
      case 'follow':
        return const Color(0xFF24D17E);
      case 'friend_request':
      case 'friend_accept':
        return const Color(0xFFFF4B6E);
      default:
        return Colors.grey;
    }
  }

  // Tapping a row (1 Oct 2026): a message opens that chat, a follow or a
  // friend request / accepted request (4 Oct 2026) opens that person's
  // profile, where the Friend button shows Respond / Friends, a comment/reaction opens that video
  // (PostFromNotificationScreen in home_screen.dart).
  void _openNotification(BuildContext context, Map<String, dynamic> data) {
    final String type = data['type'] ?? '';
    final String fromId = (data['fromId'] as String?) ?? '';
    if (fromId.isEmpty) return;
    if (type == 'message') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            otherUserId: fromId,
            otherUserName: (data['fromName'] as String?) ?? 'User',
            otherUserPhoto: (data['fromPhoto'] as String?) ?? '',
          ),
        ),
      );
    } else if (type == 'comment' || type == 'reaction') {
      final String postId = (data['postId'] as String?) ?? '';
      if (postId.isEmpty) return;
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, __, ___) => PostFromNotificationScreen(
            postId: postId,
            fromId: fromId,
            fromName: (data['fromName'] as String?) ?? 'Someone',
            fromPhoto: (data['fromPhoto'] as String?) ?? '',
            type: type,
            text: (data['text'] as String?) ?? '',
          ),
          // Grows up out of the tapped row's area with a fade.
          transitionsBuilder: (_, animation, __, child) {
            final curved =
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.92, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        ),
      );
    } else if (type == 'follow' ||
        type == 'friend_request' ||
        type == 'friend_accept') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PublicProfileScreen(userId: fromId),
        ),
      );
    }
  }

  // Converts a timestamp into a short "time ago" string
  String _timeAgo(Timestamp? ts) {
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title:
            const Text('Notifications', style: TextStyle(color: Colors.white)),
      ),
      body: myId == null
          ? const Center(
              child:
                  Text('Not logged in', style: TextStyle(color: Colors.grey)),
            )
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(myId)
                  .collection('notifications')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                final allDocs = snapshot.data?.docs ?? [];

                // Mark notifications as seen now that the user is viewing them
                if (allDocs.isNotEmpty) {
                  _markAllSeen(myId, allDocs);
                }

                // Nothing from blocked accounts (either way).
                final docs = allDocs.where((d) {
                  final data = d.data() as Map<String, dynamic>;
                  return !BlockService.instance
                      .isHidden(data['fromId'] as String?);
                }).toList();

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_none,
                            color: Colors.grey[700], size: 64),
                        const SizedBox(height: 12),
                        Text(
                          'No notifications yet',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 15),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final String fromName = data['fromName'] ?? 'Someone';
                    final String fromPhoto = data['fromPhoto'] ?? '';
                    final String type = data['type'] ?? '';
                    final bool seen = data['seen'] == true;

                    return Container(
                      color: seen
                          ? Colors.transparent
                          : Colors.white.withOpacity(0.04),
                      child: ListTile(
                        onTap: () => _openNotification(context, data),
                        leading: Stack(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: Colors.grey[850],
                              backgroundImage: fromPhoto.isNotEmpty
                                  ? NetworkImage(fromPhoto)
                                  : null,
                              child: fromPhoto.isEmpty
                                  ? Text(
                                      fromName.isNotEmpty
                                          ? fromName[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                            // Small colored badge showing the notification type
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: _typeColor(type),
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.black, width: 2),
                                ),
                                child: Icon(_typeIcon(type),
                                    color: Colors.white, size: 12),
                              ),
                            ),
                          ],
                        ),
                        title: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: fromName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              TextSpan(
                                text: ' ${_actionText(data)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        trailing: Text(
                          _timeAgo(data['createdAt'] as Timestamp?),
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

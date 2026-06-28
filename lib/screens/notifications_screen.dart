import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Shows the current user's notifications (reactions, comments, messages, follows)
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
      default:
        return Colors.grey;
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

                final docs = snapshot.data?.docs ?? [];

                // Mark notifications as seen now that the user is viewing them
                if (docs.isNotEmpty) {
                  _markAllSeen(myId, docs);
                }

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

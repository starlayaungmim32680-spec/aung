import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Lists everyone the current user has blocked (public_profile_screen.dart
// and home_screen.dart are what actually write into
// users/{myId}/blocked/{blockedUserId} when someone taps "Block user"),
// with an Unblock button for each - the piece that was missing before.
class BlockedUsersScreen extends StatelessWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Blocked accounts',
            style: TextStyle(color: Colors.white)),
      ),
      body: myId == null
          ? const SizedBox.shrink()
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(myId)
                  .collection('blocked')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return Center(
                    child: Text(
                      "You haven't blocked anyone",
                      style: TextStyle(color: Colors.grey[600], fontSize: 15),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    return _BlockedUserTile(
                      myId: myId,
                      blockedUserId: docs[index].id,
                    );
                  },
                );
              },
            ),
    );
  }
}

class _BlockedUserTile extends StatelessWidget {
  final String myId;
  final String blockedUserId;

  const _BlockedUserTile({
    required this.myId,
    required this.blockedUserId,
  });

  Future<void> _unblock(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Unblock this user?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "They'll be able to see your posts and message you again.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unblock',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('blocked')
          .doc(blockedUserId)
          .delete();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('User unblocked.')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not unblock user. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // A live stream (not a one-off get()) so the name/photo shown here
    // always match their current profile, and so this tile disappears on
    // its own the moment `_unblock` above deletes the blocked doc -
    // without needing a manual setState/list refresh.
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(blockedUserId)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>?;
        final String displayName = data?['displayName'] ?? 'User';
        final String photoUrl = data?['photoUrl'] ?? '';

        return ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: Colors.grey[850],
            backgroundImage:
                photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
            child: photoUrl.isEmpty
                ? Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  )
                : null,
          ),
          title: Text(displayName, style: const TextStyle(color: Colors.white)),
          trailing: OutlinedButton(
            onPressed: () => _unblock(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: const Text('Unblock'),
          ),
        );
      },
    );
  }
}

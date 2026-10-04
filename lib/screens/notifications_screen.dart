import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../block_service.dart';
import '../friend_service.dart';
import 'chat_screen.dart';
import 'public_profile_screen.dart';
import 'friend_requests_screen.dart';
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

  // Tapping a row (1 Oct 2026): a message opens that chat, a follow or an
  // accepted friend request opens that person's profile, a friend request
  // opens Friend Requests (Confirm / Delete there, 4 Oct 2026), a comment/reaction opens that video
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
    } else if (type == 'friend_request') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const FriendRequestsScreen()),
      );
    } else if (type == 'follow' || type == 'friend_accept') {
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

                // Nothing from blocked accounts (either way). Friend
                // requests / accepts show only the NEWEST one per person
                // (4 Oct 2026) - like Facebook, not a stack of repeats
                // every time someone re-sends after a cancel.
                final Set<String> seenFriendKeys = {};
                final docs = allDocs.where((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final String? fromId = data['fromId'] as String?;
                  if (BlockService.instance.isHidden(fromId)) return false;
                  final String type = (data['type'] as String?) ?? '';
                  if (type == 'friend_request' || type == 'friend_accept') {
                    // Newest first, so the first one kept wins.
                    return seenFriendKeys.add('$type|$fromId');
                  }
                  return true;
                }).toList();
                FriendService.instance.start();

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
                        // Facebook-style: answer a friend request right
                        // here, without opening anything (4 Oct 2026).
                        subtitle: type == 'friend_request'
                            ? _InlineFriendActions(
                                fromId: (data['fromId'] as String?) ?? '',
                                fromName: fromName,
                              )
                            : null,
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

// Confirm / Delete right inside a friend-request notification (4 Oct
// 2026). Only while the request is still waiting for me; once answered
// (here, in Friend Requests, on the profile or from the phone
// notification) it turns into a small "Friends ✓" / "Request removed"
// line. Listens to FriendService so every place stays in sync.
class _InlineFriendActions extends StatefulWidget {
  final String fromId;
  final String fromName;

  const _InlineFriendActions({required this.fromId, required this.fromName});

  @override
  State<_InlineFriendActions> createState() => _InlineFriendActionsState();
}

class _InlineFriendActionsState extends State<_InlineFriendActions> {
  bool _busy = false;
  // Set after I delete here, so the row says so instead of just going
  // quiet.
  bool _deleted = false;

  Future<void> _confirm() async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      await FriendService.instance.accept(widget.fromId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF2A2340),
          content: Text('You and ${widget.fromName} are now friends 🎉'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't confirm the request. Try again.")));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      await FriendService.instance.decline(widget.fromId);
      _deleted = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't delete the request. Try again.")));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final svc = FriendService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([svc.incoming, svc.friends]),
      builder: (context, _) {
        final Widget child;
        if (svc.isFriend(widget.fromId)) {
          child = const _StatusLine(
              key: ValueKey('friends'), text: 'Friends ✓', fly: true);
        } else if (svc.hasIncoming(widget.fromId) && !_deleted) {
          child = Padding(
            key: const ValueKey('buttons'),
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: _SmallButton(
                    label: 'Confirm',
                    gradient: true,
                    busy: _busy,
                    onTap: _confirm,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SmallButton(
                    label: 'Delete',
                    gradient: false,
                    busy: false,
                    onTap: _delete,
                  ),
                ),
              ],
            ),
          );
        } else if (_deleted) {
          child = const _StatusLine(
              key: ValueKey('deleted'), text: 'Request removed', fly: false);
        } else {
          // Answered some other time (or cancelled by them) - nothing to
          // do here any more.
          child = const SizedBox.shrink(key: ValueKey('none'));
        }
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: child,
          ),
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  final String text;
  final bool fly;
  const _StatusLine({super.key, required this.text, required this.fly});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TextStyle(
          color: fly ? const Color(0xFFFF7A95) : Colors.grey[500],
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// Compact Confirm / Delete with a spring press.
class _SmallButton extends StatefulWidget {
  final String label;
  final bool gradient;
  final bool busy;
  final VoidCallback onTap;

  const _SmallButton({
    required this.label,
    required this.gradient,
    required this.busy,
    required this.onTap,
  });

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.busy ? null : widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: widget.gradient ? null : const Color(0xFF3A3B3C),
            gradient: widget.gradient
                ? const LinearGradient(colors: [
                    Color(0xFFFF4B6E),
                    Color(0xFF9C4DFF),
                    Color(0xFF3A8DFF),
                  ])
                : null,
          ),
          child: widget.busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  widget.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
        ),
      ),
    );
  }
}

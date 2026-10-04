// Friend Requests (4 Oct 2026, Friends step 2) - everyone who sent ME a
// friend request, newest first, with Confirm / Delete right on the row
// (no need to open each profile). Opened from the people icon (with a
// count badge) at the top of Messages - see chat_screen.dart.
//
// Reads users/{me}/friendRequests (see friend_service.dart) and each
// sender's users/{uid} doc once for their name + photo. Blocked accounts
// (either way) are hidden.
//
// Fly touches: Fly-gradient Confirm button with a spring press + haptic,
// rows that shrink-and-fade away when handled, a "You're now friends 🎉"
// toast, and a friendly empty state instead of a blank page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../block_service.dart';
import '../friend_service.dart';
import 'presence_badge.dart';
import 'public_profile_screen.dart';

class FriendRequestsScreen extends StatefulWidget {
  const FriendRequestsScreen({super.key});

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen> {
  // Built once (Fly stream rule: never inside build()).
  Stream<QuerySnapshot>? _requestsStream;

  // One profile read per sender, kept for the life of the screen so rows
  // don't flicker or re-read on every rebuild.
  final Map<String, Future<DocumentSnapshot>> _profiles = {};

  // Rows the user just confirmed/deleted - hidden right away (with an
  // animation) instead of waiting for Firestore to report the delete.
  final Set<String> _handled = {};

  @override
  void initState() {
    super.initState();
    FriendService.instance.start();
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      _requestsStream = FirebaseFirestore.instance
          .collection('users')
          .doc(myId)
          .collection('friendRequests')
          .orderBy('createdAt', descending: true)
          .snapshots();
    }
    BlockService.instance.hidden.addListener(_onBlockedChanged);
  }

  void _onBlockedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
    super.dispose();
  }

  Future<DocumentSnapshot> _profileOf(String uid) => _profiles.putIfAbsent(
        uid,
        () => FirebaseFirestore.instance.collection('users').doc(uid).get(),
      );

  // Removes a request whose sender's account no longer exists (once).
  final Set<String> _dropped = {};
  void _dropStale(String uid) {
    if (!_dropped.add(uid)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _handled.add(uid));
      FriendService.instance.decline(uid).catchError((_) {});
    });
  }

  Future<void> _confirm(String uid, String name) async {
    setState(() => _handled.add(uid));
    try {
      await FriendService.instance.accept(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF2A2340),
          content: Text("You and $name are now friends 🎉"),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _handled.remove(uid));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't confirm the request. Try again.")),
      );
    }
  }

  Future<void> _delete(String uid) async {
    setState(() => _handled.add(uid));
    try {
      await FriendService.instance.decline(uid);
    } catch (_) {
      if (!mounted) return;
      setState(() => _handled.remove(uid));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't delete the request. Try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Friend Requests',
            style: TextStyle(color: Colors.white)),
      ),
      body: _requestsStream == null
          ? const Center(
              child:
                  Text('Not logged in', style: TextStyle(color: Colors.grey)),
            )
          : StreamBuilder<QuerySnapshot>(
              stream: _requestsStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  if (snapshot.hasError) {
                    return const _EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: "Couldn't load requests",
                      subtitle: 'Check your connection and try again.',
                    );
                  }
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF4B6E)),
                  );
                }

                final docs = snapshot.data!.docs
                    .where((d) => !BlockService.instance.isHidden(d.id))
                    .toList();
                // Forget rows Firestore has now really removed.
                final Set<String> live = docs.map((d) => d.id).toSet();
                _handled.removeWhere((id) => !live.contains(id));

                final int pending =
                    docs.where((d) => !_handled.contains(d.id)).length;
                if (pending == 0) {
                  return const _EmptyState(
                    icon: Icons.people_alt_rounded,
                    title: 'No friend requests',
                    subtitle:
                        "When someone sends you a friend request, it'll show up here.",
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.only(top: 6, bottom: 24),
                  itemCount: docs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text(
                          pending == 1 ? '1 request' : '$pending requests',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }
                    final doc = docs[index - 1];
                    final String uid = doc.id;
                    final Timestamp? at = (doc.data()
                        as Map<String, dynamic>?)?['createdAt'] as Timestamp?;
                    final bool gone = _handled.contains(uid);

                    return AnimatedSize(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: gone
                          ? const SizedBox(width: double.infinity, height: 0)
                          : FutureBuilder<DocumentSnapshot>(
                              future: _profileOf(uid),
                              builder: (context, profileSnap) {
                                // The sender deleted their account: clear
                                // the leftover request (I'm allowed to)
                                // instead of showing a ghost "User" row.
                                if (profileSnap.hasData &&
                                    !profileSnap.data!.exists) {
                                  _dropStale(uid);
                                  return const SizedBox.shrink();
                                }
                                final data = profileSnap.data?.data()
                                    as Map<String, dynamic>?;
                                final String rawName =
                                    ((data?['displayName'] as String?) ?? '')
                                        .trim();
                                final String name =
                                    rawName.isEmpty ? 'User' : rawName;
                                final String photo =
                                    (data?['photoUrl'] as String?) ?? '';
                                return _RequestRow(
                                  name: name,
                                  photoUrl: photo,
                                  isOnline: isUserOnline(data),
                                  timeAgo: _timeAgo(at),
                                  onOpenProfile: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          PublicProfileScreen(userId: uid),
                                    ),
                                  ),
                                  onConfirm: () => _confirm(uid, name),
                                  onDelete: () => _delete(uid),
                                );
                              },
                            ),
                    );
                  },
                );
              },
            ),
    );
  }

  String _timeAgo(Timestamp? ts) {
    if (ts == null) return 'now';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }
}

// One request: avatar (gradient ring + sparkle when online), name, how
// long ago, and Confirm / Delete underneath - Facebook's layout.
class _RequestRow extends StatelessWidget {
  final String name;
  final String photoUrl;
  final bool isOnline;
  final String timeAgo;
  final VoidCallback onOpenProfile;
  final VoidCallback onConfirm;
  final VoidCallback onDelete;

  const _RequestRow({
    required this.name,
    required this.photoUrl,
    required this.isOnline,
    required this.timeAgo,
    required this.onOpenProfile,
    required this.onConfirm,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onOpenProfile,
            child: Stack(
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
                    radius: 30,
                    backgroundColor: Colors.grey[850],
                    backgroundImage:
                        photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                    child: photoUrl.isEmpty
                        ? Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
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
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: onOpenProfile,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      timeAgo,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SpringButton(
                        label: 'Confirm',
                        gradient: true,
                        onTap: onConfirm,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SpringButton(
                        label: 'Delete',
                        gradient: false,
                        onTap: onDelete,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// A button that springs in on press, with a light haptic tap.
class _SpringButton extends StatefulWidget {
  final String label;
  final bool gradient;
  final VoidCallback onTap;

  const _SpringButton({
    required this.label,
    required this.gradient,
    required this.onTap,
  });

  @override
  State<_SpringButton> createState() => _SpringButtonState();
}

class _SpringButtonState extends State<_SpringButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: () {
        if (widget.gradient) {
          HapticFeedback.mediumImpact();
        } else {
          HapticFeedback.lightImpact();
        }
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: Container(
          height: 36,
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
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

// Friendly empty / error state: a soft gradient bubble with an icon.
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFFF4B6E).withValues(alpha: 0.25),
                    const Color(0xFF9C4DFF).withValues(alpha: 0.25),
                    const Color(0xFF3A8DFF).withValues(alpha: 0.25),
                  ],
                ),
              ),
              child: Icon(icon, color: Colors.white70, size: 44),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

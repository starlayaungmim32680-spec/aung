import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../friend_service.dart';
import 'friend_requests_screen.dart';
import '../notification_service.dart';
import 'presence_badge.dart';
import 'worker_auth.dart';

// Chat photos and voice notes go to Bunny Storage through the Worker's
// /upload-image pass-through (1 Oct 2026) - the same path story images and
// profile photos use. They used to go to Cloudinary, whose account is
// disabled, so sending a photo or voice note failed.
const String _bunnyChatCdnHostname = 'fly-images-aungdev756617.b-cdn.net';

// Messenger's six quick reactions (1 Oct 2026). Stored per message as
// `reactions: {<uid>: emoji}` - each person has at most one, and the
// Firestore rules only let you change your own.
const List<String> _kMessageReactions = ['👍', '❤️', '😆', '😮', '😢', '😡'];

// The chat thread currently on screen (its chatId), or null. Message
// alerts for that conversation are skipped while you're already looking
// at it (main_navigation_screen.dart), like Messenger.
String? currentOpenChatId;

// Messages list (rewritten 4 Oct 2026 - Friends step 4 / scale-proofing a).
//
// Before: streamed the WHOLE `users` collection (every user in Fly, on
// every heartbeat) and listed all of them. Now, like Messenger:
//   - only chats I'm in (`chats` where participants array-contains me),
//     newest activity (message or call) first, with a last-message
//     preview + time; tap -> the thread, tap the avatar -> the profile;
//   - "Online now" strip = my FRIENDS who are online (first 60 checked);
//   - "Suggested" = friends I've never chatted with (max 20) with a
//     "Say hi" button - so a brand-new account isn't staring at nothing;
//   - search filters my chats + suggestions by name.
// Profiles are read per person through _ProfileCache: one live listener
// per uid, started only when that row/avatar is actually needed, each
// exposed as a ValueNotifier so a presence heartbeat rebuilds just that
// row (no list flicker). Blocked people (either way) never show.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

// How many friends are watched for the "Online now" strip, and how many
// "Suggested" people are shown - keeps listeners bounded when someone has
// hundreds of friends.
const int _kOnlineCheckLimit = 60;
const int _kSuggestedLimit = 20;

// One chat in the list, already worked out from its `chats` doc.
class _ChatEntry {
  final String chatId;
  final String otherId;
  final String lastMessage;
  final String lastSenderId;
  final bool lastWasCall;
  final DateTime at;
  // Messages from them I haven't read yet (chats/{id}.unread.<me>,
  // 4 Oct 2026) - 0 for old chats without the field.
  final int unread;

  const _ChatEntry({
    required this.chatId,
    required this.otherId,
    required this.lastMessage,
    required this.lastSenderId,
    required this.lastWasCall,
    required this.at,
    this.unread = 0,
  });
}

// Live user docs, one listener per uid, kept for the life of the Messages
// screen. Each person is a ValueNotifier of their profile map (null until
// it arrives), so widgets listen to exactly the people they show.
class _ProfileCache {
  final Map<String, ValueNotifier<Map<String, dynamic>?>> _notifiers = {};
  final Map<String, StreamSubscription<DocumentSnapshot>> _subs = {};

  ValueNotifier<Map<String, dynamic>?> of(String uid) {
    final existing = _notifiers[uid];
    if (existing != null) return existing;
    final n = ValueNotifier<Map<String, dynamic>?>(null);
    _notifiers[uid] = n;
    _subs[uid] = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(
          (snap) => n.value = snap.data() as Map<String, dynamic>?,
          onError: (_) {},
        );
    return n;
  }

  /// Display name if this person's profile has arrived, else null.
  String? nameIfLoaded(String uid) {
    final data = _notifiers[uid]?.value;
    if (data == null) return null;
    final String name = ((data['displayName'] as String?) ?? '').trim();
    return name.isEmpty ? 'User' : name;
  }

  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final n in _notifiers.values) {
      n.dispose();
    }
    _subs.clear();
    _notifiers.clear();
  }
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Built ONCE here, never inside build() (Fly stream rule, 1 Oct 2026).
  Stream<QuerySnapshot>? _chatsStream;
  final _ProfileCache _profiles = _ProfileCache();
  late final String? _myId;

  @override
  void initState() {
    super.initState();
    _myId = FirebaseAuth.instance.currentUser?.uid;
    if (_myId != null) {
      _chatsStream = FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: _myId)
          .snapshots();
    }
    BlockService.instance.hidden.addListener(_onListsChanged);
    // Friend requests badge (step 2) + online strip / suggestions (step 4).
    FriendService.instance.start();
    FriendService.instance.friends.addListener(_onListsChanged);
  }

  void _onListsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    BlockService.instance.hidden.removeListener(_onListsChanged);
    FriendService.instance.friends.removeListener(_onListsChanged);
    _profiles.dispose();
    super.dispose();
  }

  // Turns the `chats` docs into list entries, newest activity first.
  List<_ChatEntry> _entriesFrom(List<QueryDocumentSnapshot> docs) {
    final List<_ChatEntry> out = [];
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final participants =
          (data['participants'] as List?)?.cast<String>() ?? const <String>[];
      final String otherId = participants.firstWhere(
        (id) => id != _myId,
        orElse: () => '',
      );
      if (otherId.isEmpty || BlockService.instance.isHidden(otherId)) {
        continue;
      }
      final DateTime? msgAt = (data['lastMessageAt'] as Timestamp?)?.toDate();
      final DateTime? callAt = (data['lastCallAt'] as Timestamp?)?.toDate();
      final String lastMessage = (data['lastMessage'] as String?) ?? '';
      DateTime? latest = msgAt;
      bool wasCall = false;
      if (callAt != null && (latest == null || callAt.isAfter(latest))) {
        latest = callAt;
        wasCall = true;
      }
      // A write still on its way to the server has no timestamp yet - it
      // is, by definition, the newest thing.
      latest ??= doc.metadata.hasPendingWrites ? DateTime.now() : null;
      if (latest == null) continue;
      out.add(_ChatEntry(
        chatId: doc.id,
        otherId: otherId,
        lastMessage: lastMessage,
        lastSenderId: (data['lastSenderId'] as String?) ?? '',
        lastWasCall: wasCall || lastMessage.isEmpty,
        at: latest,
        unread: ((data['unread'] as Map?)?[_myId] as num?)?.toInt() ?? 0,
      ));
    }
    out.sort((a, b) {
      final int c = b.at.compareTo(a.at);
      return c != 0 ? c : a.chatId.compareTo(b.chatId);
    });
    return out;
  }

  // Search: match by name once that person's profile has loaded (rows
  // that are still loading stay, so nothing jumps around mid-typing).
  bool _matches(String uid) {
    if (_searchQuery.isEmpty) return true;
    final String? name = _profiles.nameIfLoaded(uid);
    if (name == null) return true;
    return name.toLowerCase().contains(_searchQuery);
  }

  void _openThread(String uid) {
    HapticFeedback.selectionClick();
    final data = _profiles.of(uid).value;
    final String name = _profiles.nameIfLoaded(uid) ?? 'User';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          otherUserId: uid,
          otherUserName: name,
          otherUserPhoto: (data?['photoUrl'] as String?) ?? '',
        ),
      ),
    );
  }

  void _openProfile(String uid) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PublicProfileScreen(userId: uid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Messages', style: TextStyle(color: Colors.white)),
        actions: const [_FriendRequestsAction()],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                setState(() => _searchQuery = value.trim().toLowerCase());
              },
              decoration: InputDecoration(
                hintText: 'Search chats',
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
            child: _chatsStream == null
                ? const SizedBox.shrink()
                : StreamBuilder<QuerySnapshot>(
                    stream: _chatsStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        if (snapshot.hasError) {
                          return const _MessagesEmptyState(
                            icon: Icons.wifi_off_rounded,
                            title: "Couldn't load chats",
                            subtitle: 'Check your connection and try again.',
                          );
                        }
                        return const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFFFF4B6E)),
                        );
                      }
                      return _buildList(_entriesFrom(snapshot.data!.docs));
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<_ChatEntry> allChats) {
    final Set<String> chatted = allChats.map((c) => c.otherId).toSet();
    final List<String> friends = FriendService.instance.friends.value
        .where((id) => id != _myId && !BlockService.instance.isHidden(id))
        .toList()
      ..sort();

    final List<_ChatEntry> chats =
        allChats.where((c) => _matches(c.otherId)).toList();
    final List<String> suggested = friends
        .where((id) => !chatted.contains(id))
        .take(_kSuggestedLimit)
        .where(_matches)
        .toList();
    final List<String> onlineCandidates = _searchQuery.isNotEmpty
        ? const <String>[]
        : friends.take(_kOnlineCheckLimit).toList();

    if (chats.isEmpty && suggested.isEmpty) {
      if (_searchQuery.isNotEmpty) {
        return const _MessagesEmptyState(
          icon: Icons.search_off_rounded,
          title: 'No matches',
          subtitle: 'Try a different name.',
        );
      }
      return Column(
        children: [
          if (onlineCandidates.isNotEmpty)
            _OnlineNowStrip(
              candidates: onlineCandidates,
              profiles: _profiles,
              onTap: _openThread,
            ),
          const Expanded(
            child: _MessagesEmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'No chats yet',
              subtitle:
                  'Add friends to start chatting 💬\nOnly friends can message and call each other.',
            ),
          ),
        ],
      );
    }

    // Header (online strip) + chats + "Suggested" header + suggestions.
    final int chatCount = chats.length;
    final bool hasSuggested = suggested.isNotEmpty;
    final int itemCount =
        1 + chatCount + (hasSuggested ? 1 + suggested.length : 0);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return onlineCandidates.isEmpty
              ? const SizedBox.shrink()
              : _OnlineNowStrip(
                  candidates: onlineCandidates,
                  profiles: _profiles,
                  onTap: _openThread,
                );
        }
        final int i = index - 1;
        if (i < chatCount) {
          final c = chats[i];
          return _ChatRow(
            key: ValueKey('chat_${c.chatId}'),
            entry: c,
            myId: _myId ?? '',
            profile: _profiles.of(c.otherId),
            onTap: () => _openThread(c.otherId),
            onAvatarTap: () => _openProfile(c.otherId),
          );
        }
        if (i == chatCount) {
          return const _SectionHeader(title: 'Suggested');
        }
        final String uid = suggested[i - chatCount - 1];
        return _SuggestedRow(
          key: ValueKey('suggest_$uid'),
          profile: _profiles.of(uid),
          onSayHi: () => _openThread(uid),
          onAvatarTap: () => _openProfile(uid),
        );
      },
    );
  }
}

// People icon at the top of Messages that opens Friend Requests, with a
// red count badge that pops in (Friends step 2, 4 Oct 2026). Listens only
// to FriendService.incoming, so a new request never rebuilds the list.
class _FriendRequestsAction extends StatelessWidget {
  const _FriendRequestsAction();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: FriendService.instance.incoming,
      builder: (context, incoming, _) {
        final int count =
            incoming.where((id) => !BlockService.instance.isHidden(id)).length;
        return IconButton(
          tooltip: 'Friend requests',
          onPressed: () {
            HapticFeedback.lightImpact();
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FriendRequestsScreen()),
            );
          },
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.people_alt_rounded, color: Colors.white),
              Positioned(
                right: -8,
                top: -6,
                child: AnimatedScale(
                  scale: count > 0 ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.elasticOut,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                      ),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: Colors.black, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
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

// Short Messenger-style time: "now", "5m", "14:32" (today), "Yesterday",
// "Mon" (this week), else "4/10".
String _chatTime(DateTime at) {
  final DateTime now = DateTime.now();
  final Duration diff = now.difference(at);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(at.year, at.month, at.day);
  final int daysAgo = today.difference(day).inDays;
  if (daysAgo == 0) {
    final String h = at.hour.toString().padLeft(2, '0');
    final String m = at.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[at.weekday - 1];
  }
  return '${at.day}/${at.month}';
}

String _nameOf(Map<String, dynamic>? data) {
  final String name = ((data?['displayName'] as String?) ?? '').trim();
  return name.isEmpty ? 'User' : name;
}

// Avatar with the Fly gradient ring and the sparkle star when online.
class _ChatAvatar extends StatelessWidget {
  final Map<String, dynamic>? data;
  final double radius;

  const _ChatAvatar({required this.data, this.radius = 26});

  @override
  Widget build(BuildContext context) {
    final String photoUrl = (data?['photoUrl'] as String?) ?? '';
    final String name = data == null ? '' : _nameOf(data);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF), Color(0xFF3A8DFF)],
            ),
          ),
          child: CircleAvatar(
            radius: radius,
            backgroundColor: Colors.grey[850],
            backgroundImage:
                photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
            child: photoUrl.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: radius * 0.7,
                    ),
                  )
                : null,
          ),
        ),
        if (isUserOnline(data))
          const Positioned(
            right: -2,
            bottom: -2,
            child: SparkleStarBadge(),
          ),
      ],
    );
  }
}

// Shrinks a touch while pressed - Fly's spring feel on list rows.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _PressScale({required this.child, required this.onTap});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

// One conversation: avatar, name, "You: ..." / last message / "📞 Call",
// and the time. Listens only to this person's profile.
class _ChatRow extends StatelessWidget {
  final _ChatEntry entry;
  final String myId;
  final ValueNotifier<Map<String, dynamic>?> profile;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;

  const _ChatRow({
    super.key,
    required this.entry,
    required this.myId,
    required this.profile,
    required this.onTap,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool mine = entry.lastSenderId == myId;
    final String preview = entry.lastWasCall
        ? '📞 Call'
        : (mine ? 'You: ${entry.lastMessage}' : entry.lastMessage);
    // Messenger-style unread: bold white name + preview + a count pill.
    final bool unread = entry.unread > 0 && !mine;

    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: profile,
      builder: (context, data, _) {
        return _PressScale(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onAvatarTap,
                  child: _ChatAvatar(data: data),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data == null ? ' ' : _nameOf(data),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight:
                              unread ? FontWeight.w800 : FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: unread ? Colors.white : Colors.grey[500],
                                fontSize: 13,
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          Text(
                            '  ·  ${_chatTime(entry.at)}',
                            style: TextStyle(
                              color: unread
                                  ? const Color(0xFFFF7A95)
                                  : Colors.grey[600],
                              fontSize: 12,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Fly gradient count pill that pops in (Messenger shows a
                // plain blue dot).
                AnimatedScale(
                  scale: unread ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.elasticOut,
                  child: Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    constraints:
                        const BoxConstraints(minWidth: 22, minHeight: 22),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      gradient: const LinearGradient(colors: [
                        Color(0xFFFF4B6E),
                        Color(0xFF9C4DFF),
                        Color(0xFF3A8DFF),
                      ]),
                    ),
                    child: Text(
                      entry.unread > 9 ? '9+' : '${entry.unread}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// A friend you haven't chatted with yet, with a gradient "Say hi" chip.
class _SuggestedRow extends StatelessWidget {
  final ValueNotifier<Map<String, dynamic>?> profile;
  final VoidCallback onSayHi;
  final VoidCallback onAvatarTap;

  const _SuggestedRow({
    super.key,
    required this.profile,
    required this.onSayHi,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: profile,
      builder: (context, data, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              GestureDetector(
                onTap: onAvatarTap,
                child: _ChatAvatar(data: data, radius: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data == null ? ' ' : _nameOf(data),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Friends on Fly',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
              _PressScale(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onSayHi();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(colors: [
                      Color(0xFFFF4B6E),
                      Color(0xFF9C4DFF),
                      Color(0xFF3A8DFF),
                    ]),
                  ),
                  child: const Text(
                    'Say hi 👋',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
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

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.grey[400],
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// Friendly empty / error state for Messages: soft gradient bubble + icon.
class _MessagesEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _MessagesEmptyState({
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

// "Online now" - my friends who are online right now, Fly's take on
// Messenger's "Active now" row (sparkle star instead of a green dot).
// Listens to just the candidates' profiles; hides itself when nobody is
// online. Tapping someone opens the chat with them.
class _OnlineNowStrip extends StatelessWidget {
  final List<String> candidates;
  final _ProfileCache profiles;
  final void Function(String uid) onTap;

  const _OnlineNowStrip({
    required this.candidates,
    required this.profiles,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final notifiers = {for (final id in candidates) id: profiles.of(id)};
    return ListenableBuilder(
      listenable: Listenable.merge(notifiers.values.toList()),
      builder: (context, _) {
        final online = notifiers.entries
            .where((e) => isUserOnline(e.value.value))
            .toList();
        if (online.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: online.length,
            itemBuilder: (context, index) {
              final String uid = online[index].key;
              final data = online[index].value.value;
              final String name = _nameOf(data);
              return _PressScale(
                onTap: () => onTap(uid),
                child: Container(
                  width: 68,
                  margin: const EdgeInsets.only(right: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ChatAvatar(data: data),
                      const SizedBox(height: 4),
                      Text(
                        name.split(' ').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
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

  // Friends only (Friends step 3, 4 Oct 2026, friend_service.dart): a
  // non-friend can still READ an old conversation, but the message box is
  // replaced by an "Add friend to keep chatting" banner and the call
  // buttons are hidden. The Firestore rules refuse it too (areFriends()).
  bool get _isFriend => FriendService.instance.isFriend(widget.otherUserId);
  bool get _friendsKnown => FriendService.instance.loaded.value;
  bool get _canTalk => !_blocked && _isFriend;
  // My own pending request to them (for the banner's button), built once.
  late final Stream<bool> _sentRequestStream;
  bool _friendBusy = false;
  bool get _iBlockedThem =>
      BlockService.instance.blockedByMe.value.contains(widget.otherUserId);

  void _onBlockedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    currentOpenChatId = _chatId;
    // Opening the chat clears its notification from the tray.
    NotificationService.cancelChatNotification(_chatId);
    final chatDoc = FirebaseFirestore.instance.collection('chats').doc(_chatId);
    _messagesStream = chatDoc
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();
    _activityStream =
        chatDoc.collection('activity').doc(widget.otherUserId).snapshots();
    BlockService.instance.hidden.addListener(_onBlockedChanged);
    FriendService.instance.start();
    _sentRequestStream =
        FriendService.instance.watchSentRequest(widget.otherUserId);
    FriendService.instance.friends.addListener(_onBlockedChanged);
    FriendService.instance.incoming.addListener(_onBlockedChanged);
    FriendService.instance.loaded.addListener(_onBlockedChanged);
    // Opening the chat = I've read it (Messages list stops being bold).
    _markChatRead();
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
    if (currentOpenChatId == _chatId) currentOpenChatId = null;
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
    FriendService.instance.friends.removeListener(_onBlockedChanged);
    FriendService.instance.incoming.removeListener(_onBlockedChanged);
    FriendService.instance.loaded.removeListener(_onBlockedChanged);
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
      // One more unread for them (Messages list bold + count, 4 Oct 2026).
      'unread': {widget.otherUserId: FieldValue.increment(1)},
    }, SetOptions(merge: true));

    await _notifyOther(previewText);
  }

  // Adds an in-app notification for the other person (new message, or a
  // reaction to one of their messages) and pushes it to their phone, so it
  // shows up - and turns "Delivered" - even when Fly is closed there.
  Future<void> _notifyOther(String text) async {
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

    unawaited(sendChatPush(
      receiverId: widget.otherUserId,
      chatId: _chatId,
      senderName: myName,
      senderPhoto: myPhoto,
      text: text,
    ));

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
      'delivered': false,
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
          'delivered': false,
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
          'delivered': false,
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

  // Sets my reaction on a message, or removes it when I pick the same one
  // again (like Messenger).
  Future<void> _setReaction(
    String messageId,
    String emoji, {
    required String? current,
    required bool messageIsMine,
  }) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .doc(messageId);
    try {
      if (current == emoji) {
        await ref.update({'reactions.$myId': FieldValue.delete()});
      } else {
        await ref.update({'reactions.$myId': emoji});
        if (!messageIsMine) {
          unawaited(_notifyOther('Reacted $emoji to your message')
              .catchError((_) {}));
        }
      }
    } catch (_) {
      _showError("Couldn't react. Please try again.");
    }
  }

  // Long-press menu: the reaction bar on top, then Copy / Unsend.
  Future<void> _showMessageActions({
    required String messageId,
    required Map<String, dynamic> msg,
    required bool isMine,
  }) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    HapticFeedback.mediumImpact();
    final Map<String, dynamic> reactions =
        (msg['reactions'] as Map?)?.cast<String, dynamic>() ?? const {};
    final String? current = reactions[myId] as String?;
    final String type = msg['type'] ?? 'text';
    final String text = msg['text'] ?? '';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_blocked)
                  _ReactionBar(
                    selected: current,
                    onPick: (emoji) {
                      Navigator.pop(sheetContext);
                      _setReaction(messageId, emoji,
                          current: current, messageIsMine: isMine);
                    },
                  ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (type == 'text' && text.isNotEmpty)
                        ListTile(
                          leading:
                              const Icon(Icons.copy, color: Colors.white70),
                          title: const Text('Copy',
                              style: TextStyle(color: Colors.white)),
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: text));
                            Navigator.pop(sheetContext);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Copied'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      if (isMine)
                        ListTile(
                          leading: const Icon(Icons.delete_outline,
                              color: Colors.redAccent),
                          title: const Text('Unsend',
                              style: TextStyle(color: Colors.redAccent)),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _deleteMessage(messageId);
                          },
                        ),
                      ListTile(
                        leading: const Icon(Icons.close, color: Colors.white54),
                        title: const Text('Cancel',
                            style: TextStyle(color: Colors.white70)),
                        onTap: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Who reacted with what; tapping my own row removes my reaction.
  void _showReactionDetails({
    required String messageId,
    required Map<String, dynamic> reactions,
    required bool isMine,
  }) {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final entries = reactions.entries
            .where((e) => e.value is String)
            .toList()
          ..sort((a, b) => a.key == myId ? -1 : (b.key == myId ? 1 : 0));
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Reactions',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              for (final e in entries)
                ListTile(
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.grey[850],
                    backgroundImage:
                        e.key != myId && widget.otherUserPhoto.isNotEmpty
                            ? NetworkImage(widget.otherUserPhoto)
                            : null,
                    child: e.key == myId || widget.otherUserPhoto.isEmpty
                        ? Text(
                            e.key == myId
                                ? 'Y'
                                : (widget.otherUserName.isNotEmpty
                                    ? widget.otherUserName[0].toUpperCase()
                                    : '?'),
                            style: const TextStyle(color: Colors.white),
                          )
                        : null,
                  ),
                  title: Text(
                    e.key == myId ? 'You' : widget.otherUserName,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: e.key == myId
                      ? const Text('Tap to remove',
                          style: TextStyle(color: Colors.white38, fontSize: 12))
                      : null,
                  trailing: Text(e.value as String,
                      style: const TextStyle(fontSize: 24)),
                  onTap: e.key == myId
                      ? () {
                          Navigator.pop(sheetContext);
                          _setReaction(messageId, e.value as String,
                              current: e.value as String,
                              messageIsMine: isMine);
                        }
                      : null,
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
        // Seen always implies delivered.
        batch.update(doc.reference, {'seen': true, 'delivered': true});
        hasUnseen = true;
      }
    }

    if (hasUnseen) {
      await batch.commit();
      _markChatRead();
    }
  }

  // Sets MY unread count for this chat back to 0 (chats/{id}.unread.<me>).
  // The rules allow exactly this even after unfriending, so old threads
  // don't stay bold forever. Skipped when it's already 0.
  Future<void> _markChatRead() async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    final ref = FirebaseFirestore.instance.collection('chats').doc(_chatId);
    try {
      final snap = await ref.get();
      final num? count = (snap.data()?['unread'] as Map?)?[myId] as num?;
      if (count == null || count == 0) return;
      await ref.update({'unread.$myId': 0});
    } catch (_) {}
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

  // Replaces the message box when we aren't friends (Friends step 3): a
  // friendly glass card with the same Add Friend / Requested / Respond
  // states as the profile button, so you can fix it right here.
  Widget _notFriendsBanner() {
    final String name = widget.otherUserName.trim().isEmpty
        ? 'them'
        : widget.otherUserName.trim();
    return StreamBuilder<bool>(
      stream: _sentRequestStream,
      builder: (context, snap) {
        final bool sent = snap.data ?? false;
        final bool incoming =
            FriendService.instance.hasIncoming(widget.otherUserId);

        final String text;
        final String buttonLabel;
        final bool gradient;
        if (incoming) {
          text = '$name sent you a friend request. Confirm it to chat.';
          buttonLabel = 'Confirm';
          gradient = true;
        } else if (sent) {
          text = "Friend request sent ✨ You can chat once $name accepts.";
          buttonLabel = 'Cancel request';
          gradient = false;
        } else {
          text = 'Add $name as a friend to keep chatting.';
          buttonLabel = 'Add Friend';
          gradient = true;
        }

        Future<void> onPressed() async {
          if (_friendBusy) return;
          HapticFeedback.mediumImpact();
          setState(() => _friendBusy = true);
          final svc = FriendService.instance;
          try {
            if (incoming) {
              await svc.accept(widget.otherUserId);
            } else if (sent) {
              await svc.cancelRequest(widget.otherUserId);
            } else {
              await svc.sendRequest(widget.otherUserId);
            }
          } catch (_) {
            _showError("Something went wrong. Please try again.");
          }
          if (mounted) setState(() => _friendBusy = false);
        }

        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
              20, 14, 20, 14 + MediaQuery.of(context).padding.bottom),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFFFF4B6E).withValues(alpha: 0.12),
                const Color(0xFF9C4DFF).withValues(alpha: 0.12),
                const Color(0xFF3A8DFF).withValues(alpha: 0.12),
              ],
            ),
            border: const Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.people_alt_rounded,
                  color: Colors.white70, size: 22),
              const SizedBox(height: 6),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _friendBusy ? null : onPressed,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: gradient ? null : const Color(0xFF3A3B3C),
                    gradient: gradient
                        ? const LinearGradient(colors: [
                            Color(0xFFFF4B6E),
                            Color(0xFF9C4DFF),
                            Color(0xFF3A8DFF),
                          ])
                        : null,
                  ),
                  child: _friendBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          buttonLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
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

  Future<void> _startVideoCall({required bool withCamera}) async {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null || !_canTalk) return;

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
          if (_canTalk) ...[
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

                // Like Messenger, the Sent/Delivered/Seen row shows only
                // under my newest message (plus any still sending).
                final int newestMineIndex = messages.indexWhere((d) =>
                    (d.data() as Map<String, dynamic>)['senderId'] == myId);

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
                    final bool delivered = seen || msg['delivered'] == true;
                    final Map<String, dynamic> reactions =
                        (msg['reactions'] as Map?)?.cast<String, dynamic>() ??
                            const {};
                    final bool showStatus =
                        isMine && (isPending || index == newestMineIndex);

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
                              onLongPress: () => _showMessageActions(
                                messageId: messageId,
                                msg: msg,
                                isMine: isMine,
                              ),
                              child: _ReactedBubble(
                                bubble: bubble,
                                reactions: reactions,
                                isMine: isMine,
                                onTapReactions: () => _showReactionDetails(
                                  messageId: messageId,
                                  reactions: reactions,
                                  isMine: isMine,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (showStatus)
                          Padding(
                            padding: const EdgeInsets.only(
                                top: 2, right: 4, bottom: 2),
                            child: _DeliveryStatus(
                              isPending: isPending,
                              delivered: delivered,
                              seen: seen,
                              otherPhoto: widget.otherUserPhoto,
                              otherName: widget.otherUserName,
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
          else if (!_friendsKnown)
            // Friends list not loaded yet (usually a split second, from
            // the cache) - don't flash the "not friends" banner.
            SizedBox(height: 64 + MediaQuery.of(context).padding.bottom)
          else if (!_isFriend)
            _notFriendsBanner()
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

// Messenger-style status under my newest message:
//   Sending...  - still only on my phone (offline queue)
//   Sent        - reached Fly's server, not their phone yet (hollow tick)
//   Delivered   - reached their phone (filled tick)
//   Seen        - they opened the chat (their tiny photo)
class _DeliveryStatus extends StatelessWidget {
  final bool isPending;
  final bool delivered;
  final bool seen;
  final String otherPhoto;
  final String otherName;

  const _DeliveryStatus({
    required this.isPending,
    required this.delivered,
    required this.seen,
    required this.otherPhoto,
    required this.otherName,
  });

  @override
  Widget build(BuildContext context) {
    const Color blue = Color(0xFF3A8DFF);
    Widget icon;
    String label;
    Color color = Colors.grey;

    if (isPending) {
      icon = const Icon(Icons.radio_button_unchecked,
          size: 13, color: Colors.grey);
      label = 'Sending...';
    } else if (seen) {
      icon = CircleAvatar(
        radius: 7,
        backgroundColor: Colors.grey[800],
        backgroundImage:
            otherPhoto.isNotEmpty ? NetworkImage(otherPhoto) : null,
        child: otherPhoto.isEmpty
            ? Text(
                otherName.isNotEmpty ? otherName[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 8),
              )
            : null,
      );
      label = 'Seen';
      color = blue;
    } else if (delivered) {
      icon = const Icon(Icons.check_circle, size: 13, color: blue);
      label = 'Delivered';
    } else {
      icon =
          const Icon(Icons.check_circle_outline, size: 13, color: Colors.grey);
      label = 'Sent';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

// A message bubble with its reactions pill hanging off the bottom corner.
class _ReactedBubble extends StatelessWidget {
  final Widget bubble;
  final Map<String, dynamic> reactions;
  final bool isMine;
  final VoidCallback onTapReactions;

  const _ReactedBubble({
    required this.bubble,
    required this.reactions,
    required this.isMine,
    required this.onTapReactions,
  });

  @override
  Widget build(BuildContext context) {
    final List<String> emojis = reactions.values.whereType<String>().toList();
    if (emojis.isEmpty) return bubble;
    // Most-used first, each shown once.
    final Map<String, int> counts = {};
    for (final e in emojis) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final List<String> unique = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: bubble,
        ),
        Positioned(
          bottom: 0,
          right: isMine ? null : 6,
          left: isMine ? 6 : null,
          child: GestureDetector(
            onTap: onTapReactions,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(emojis.join()),
              tween: Tween(begin: 0.6, end: 1),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(unique.take(3).join(),
                        style: const TextStyle(fontSize: 13)),
                    if (emojis.length > 1) ...[
                      const SizedBox(width: 3),
                      Text('${emojis.length}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// The row of six reactions shown on long-press; each pops in one after
// another and the one I already picked is highlighted.
class _ReactionBar extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onPick;

  const _ReactionBar({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(32),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < _kMessageReactions.length; i++)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 220 + i * 45),
              curve: Curves.easeOutBack,
              builder: (context, t, child) => Transform.scale(
                scale: t.clamp(0.0, 1.2),
                child: child,
              ),
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onPick(_kMessageReactions[i]);
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected == _kMessageReactions[i]
                        ? Colors.white24
                        : Colors.transparent,
                  ),
                  child: Text(_kMessageReactions[i],
                      style: const TextStyle(fontSize: 30)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

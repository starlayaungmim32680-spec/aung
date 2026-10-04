import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import '../notification_service.dart';
import '../call_kit_service.dart';
import '../active_call.dart';
import '../network_service.dart';
import '../block_service.dart';
import '../chat_delivery_service.dart';
import 'video_call_screen.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'upload_screen.dart';
import 'profile_screen.dart';
import 'live_screen.dart';
import 'gifting.dart';
import 'onboarding_screen.dart';
import 'friend_requests_screen.dart';
import '../friend_service.dart';
import '../search_service.dart';
import 'public_profile_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;

  // Home/Chat are swipeable as a horizontal group (Home first, swipe left
  // for Chat) - Upload/Profile stay tap-only via the bottom bar, not part
  // of this swipe group. The standalone Shorts/Reels tab was removed -
  // videos only live on Home now.
  late final PageController _swipePageController;
  static const List<int> _localToCurrentIndex = [0, 1]; // Home, Chat
  // One-time onboarding hint teaching people they can swipe from Home to
  // Chat, since that gesture isn't discoverable on its own - shown once
  // ever per account, then never again.
  bool _showSwipeHint = false;

  late AnimationController _rotationController;

  StreamSubscription<QuerySnapshot>? _chatSubscription;
  bool _firstSnapshot = true;
  // chatId -> lastMessageAt already alerted. A chat doc also changes when
  // someone CALLS (lastCallAt), which used to re-alert the old message.
  final Map<String, Timestamp> _alertedMessageAt = {};

  // Incoming call listener
  StreamSubscription<QuerySnapshot>? _callSubscription;
  bool _firstCallSnapshot = true;
  bool _isShowingIncomingCall = false;

  // Message notification sound (generated in code, no audio file)
  final AudioPlayer _dingPlayer = AudioPlayer();
  Uint8List? _dingBytes;

  // Online-status ("is this user online right now") for the sparkle-star
  // badge on Chat/Profile. Fly only uses Firestore (no Realtime Database),
  // so there's no true onDisconnect hook - instead this refreshes
  // `lastActive` every 20s, and keeps running through backgrounding/
  // screen-lock too, via PresenceForegroundService.kt (started below).
  // The badge still treats a user as online only if `lastActive` is
  // within the last 60s (see chat_screen.dart/public_profile_screen.dart)
  // rather than trusting `isOnline` alone, so a force-killed/crashed app,
  // or a device where the foreground service still gets killed by an
  // aggressive OEM despite everything, naturally goes stale instead of
  // staying stuck "online" forever.
  Timer? _presenceHeartbeatTimer;

  // Total unread chat messages for the badge on the bottom-bar Chat icon
  // (4 Oct 2026): the sum of chats/{id}.unread.<me>, from the chats
  // listener that's already running (_listenForNewMessages) - no extra
  // reads. A ValueNotifier so only the badge rebuilds, never the screen.
  final ValueNotifier<int> _unreadTotal = ValueNotifier<int>(0);
  List<QueryDocumentSnapshot> _lastChatDocs = const [];

  final List<Widget> _screens = const [
    HomeScreen(),
    ChatScreen(),
    UploadScreen(),
    ProfileScreen(),
  ];

  final List<Map<String, dynamic>> _menuItems = const [
    {
      'icon': Icons.home_rounded,
      'label': 'Home',
      'colors': [Color(0xFFFF4B6E), Color(0xFFD32F4F)],
    },
    {
      'icon': Icons.chat_bubble_rounded,
      'label': 'Chat',
      'colors': [Color(0xFF3A8DFF), Color(0xFF1565C0)],
    },
    {
      'icon': Icons.add_rounded,
      'label': 'Upload',
      'colors': [Color(0xFF24D17E), Color(0xFF0E9F5E)],
    },
    {
      'icon': Icons.person_rounded,
      'label': 'Profile',
      'colors': [Color(0xFF9C4DFF), Color(0xFF6A1B9A)],
    },
    {
      'icon': Icons.podcasts_rounded,
      'label': 'Live',
      'colors': [Color(0xFFFF3B30), Color(0xFFB71C1C)],
      'action': 'live',
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Who's blocked (either way) - read by the feed, stories, chat,
    // search and profiles to hide those accounts everywhere.
    BlockService.instance.start();
    // Blocked people's chats don't count towards the unread badge.
    BlockService.instance.hidden.addListener(_recomputeUnread);
    // Keep my name findable in search (Cloudflare D1, see
    // search_service.dart). Once per app run, best-effort.
    SearchService.syncMe();
    // Marks messages sent to me as "Delivered" once they reach this phone.
    ChatDeliveryService.instance.start();
    _setOnlineStatus(true);
    _presenceHeartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _setOnlineStatus(true);
    });
    // Keeps Fly's process alive (screen off/locked included) via a real
    // Android foreground service, so the heartbeat above doesn't get
    // suspended by the OS the moment the screen locks - see
    // PresenceForegroundService.kt for why this is needed and what the
    // person sees (a persistent, silent "You're online" notification -
    // unavoidable by Android's own rule for any foreground service).
    kBackgroundChannel.invokeMethod('startPresenceService').catchError((_) {});
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _swipePageController = PageController(initialPage: 0); // start on Home
    _maybeShowOnboardingOnce();
    _listenForNewMessages();
    _listenForIncomingCalls();
    // Tapping a message notification opens that chat.
    NotificationService.pendingChat.addListener(_openPendingChat);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingChat());
    // Tapping a friend notification opens Friend Requests / the profile.
    NotificationService.pendingFriend.addListener(_onPendingFriend);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingFriend());
    CoinService.instance.awardDailyLogin();
    navigateToHomeSignal.addListener(_onNavigateToHomeSignal);
    // Call-reliability permissions (battery optimization, overlay,
    // full-screen intent, autostart) are intentionally NOT requested here
    // - they're only requested when a call actually starts, from
    // video_call_screen.dart, so opening the app never triggers a
    // permission prompt on its own. See call_permissions.dart.
  }

  // Called when UploadScreen pings navigateToHomeSignal right after a post
  // finishes uploading - jumps from Upload straight to the Home tab, at
  // the newest video, instead of leaving the person on the Upload screen.
  void _onNavigateToHomeSignal() {
    if (!mounted) return;
    setState(() => _currentIndex = 0);
    if (_swipePageController.hasClients) {
      _swipePageController.jumpToPage(0); // Home's page in the swipe group
    }
    // The feed orders newest first, so the just-uploaded video is the
    // very first item - scroll straight to it.
    homeFeedScrollToTopSignal.value++;
  }

  // Builds a short "ding" notification sound as a WAV byte buffer
  Uint8List _generateDingWav() {
    const int sampleRate = 44100;
    // Two short ascending tones for a pleasant notification chime
    final segments = <List<double>>[
      [784.0, 0.09], // G5
      [1046.5, 0.20], // C6
    ];
    int totalSamples = 0;
    for (final s in segments) {
      totalSamples += (sampleRate * s[1]).round();
    }
    final int dataSize = totalSamples * 2;

    final ByteData data = ByteData(44 + dataSize);
    int offset = 0;

    void writeString(String s) {
      for (int i = 0; i < s.length; i++) {
        data.setUint8(offset++, s.codeUnitAt(i));
      }
    }

    void writeUint32(int v) {
      data.setUint32(offset, v, Endian.little);
      offset += 4;
    }

    void writeUint16(int v) {
      data.setUint16(offset, v, Endian.little);
      offset += 2;
    }

    writeString('RIFF');
    writeUint32(36 + dataSize);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1);
    writeUint16(1);
    writeUint32(sampleRate);
    writeUint32(sampleRate * 2);
    writeUint16(2);
    writeUint16(16);
    writeString('data');
    writeUint32(dataSize);

    for (final s in segments) {
      final double freq = s[0];
      final double dur = s[1];
      final int n = (sampleRate * dur).round();
      for (int i = 0; i < n; i++) {
        final double t = i / sampleRate;
        double amp = 0.5;
        const double fade = 0.012;
        if (t < fade) amp *= t / fade;
        if (t > dur - fade) amp *= (dur - t) / fade;
        int v = (sin(2 * pi * freq * t) * amp * 32767).round();
        if (v > 32767) v = 32767;
        if (v < -32768) v = -32768;
        data.setInt16(offset, v, Endian.little);
        offset += 2;
      }
    }

    return data.buffer.asUint8List();
  }

  // Plays the notification ding
  Future<void> _playDing() async {
    try {
      _dingBytes ??= _generateDingWav();
      await _dingPlayer.stop();
      await _dingPlayer.play(BytesSource(_dingBytes!));
    } catch (_) {}
  }

  // Watches all chats and shows a notification + sound when a new
  // message arrives from someone else
  // Adds up my unread counts across chats (skipping blocked people).
  void _recomputeUnread() {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;
    int total = 0;
    for (final doc in _lastChatDocs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;
      final List participants = (data['participants'] as List?) ?? const [];
      final String other = participants
          .map((e) => e.toString())
          .firstWhere((id) => id != myId, orElse: () => '');
      if (other.isEmpty || BlockService.instance.isHidden(other)) continue;
      final num? n = (data['unread'] as Map?)?[myId] as num?;
      if (n != null && n > 0) total += n.toInt();
    }
    if (_unreadTotal.value != total) _unreadTotal.value = total;
  }

  void _listenForNewMessages() {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    _chatSubscription = FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: myId)
        .snapshots()
        .listen((snapshot) async {
      _lastChatDocs = snapshot.docs;
      _recomputeUnread();
      if (_firstSnapshot) {
        _firstSnapshot = false;
        for (final doc in snapshot.docs) {
          final Timestamp? at = (doc.data()
              as Map<String, dynamic>?)?['lastMessageAt'] as Timestamp?;
          if (at != null) _alertedMessageAt[doc.id] = at;
        }
        return;
      }

      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.removed) continue;
        final data = change.doc.data() as Map<String, dynamic>?;
        if (data == null) continue;

        final String chatId = change.doc.id;
        final String lastSenderId = data['lastSenderId'] ?? '';
        final String lastMessage = data['lastMessage'] ?? '';
        final Timestamp? at = data['lastMessageAt'] as Timestamp?;

        // Only a genuinely NEW message - not a call, not the same one again.
        if (at == null || _alertedMessageAt[chatId] == at) continue;
        _alertedMessageAt[chatId] = at;
        if (lastSenderId.isEmpty || lastSenderId == myId) continue;
        if (BlockService.instance.isHidden(lastSenderId)) continue;
        // Already reading this conversation.
        if (currentOpenChatId == chatId) continue;

        final bool inForeground =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (inForeground) {
          // Play the in-app notification sound
          _playDing();
        } else {
          // In the background the chat push (main.dart) shows it. Wait a
          // moment and only step in if it didn't (no token, push failed),
          // so the person never gets the same alert twice.
          await Future.delayed(const Duration(seconds: 4));
          if (await NotificationService.isChatNotificationShowing(chatId)) {
            continue;
          }
        }

        final senderDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(lastSenderId)
            .get();
        final senderName =
            (senderDoc.data()?['displayName'] as String?) ?? 'New message';
        final String senderPhoto =
            (senderDoc.data()?['photoUrl'] as String?) ?? '';

        await NotificationService.showMessageNotification(
          title: senderName,
          body: lastMessage,
          chatId: chatId,
          senderId: lastSenderId,
          senderPhoto: senderPhoto,
        );
      }
    });
  }

  // Watches for incoming calls where I'm the callee and status is ringing
  void _listenForIncomingCalls() {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    _callSubscription = FirebaseFirestore.instance
        .collection('calls')
        .where('calleeId', isEqualTo: myId)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      if (_firstCallSnapshot) {
        _firstCallSnapshot = false;
        // On a normal warm start, skip re-showing a call that was
        // already ringing before this screen even loaded (e.g. it was
        // just missed/expired) - but NOT on a cold start triggered by
        // the incoming-call push itself (see
        // notification_service.dart's background handler), where the
        // call is still genuinely ringing and this is exactly the
        // snapshot meant to pick it back up. A recency check tells
        // the two apart: only truly stale calls get skipped here.
        final bool anyStillFresh = snapshot.docs.any((doc) {
          final Timestamp? ts = doc.data()['createdAt'] as Timestamp?;
          if (ts == null) return false;
          return DateTime.now().difference(ts.toDate()) <
              const Duration(seconds: 45);
        });
        if (!anyStillFresh) return;
      }

      // A call leaving this query ("removed") means its status is no
      // longer 'ringing'. Handled before the _isShowingIncomingCall
      // early-return below so a cancel is never skipped just because the
      // ringing screen is still being set up.
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.removed) {
          _handleCallLeftRinging(change.doc.reference);
        }
      }

      if (_isShowingIncomingCall) return;

      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added ||
            change.type == DocumentChangeType.modified) {
          final data = change.doc.data() as Map<String, dynamic>?;
          if (data == null) continue;
          if (data['status'] != 'ringing') continue;

          _showIncomingCall(
            callerName: data['callerName'] ?? 'Someone',
            callerPhoto: data['callerPhoto'] ?? '',
            roomName: data['roomName'] ?? '',
            myId: myId,
            callRef: change.doc.reference,
          );
          break;
        }
      }
    });
  }

  // Called when a call I was being rung for stops being 'ringing'. That
  // happens for three different reasons, and only one of them should stop
  // the ringing screen:
  //   - 'ended'    -> the caller hung up (or their 45s no-answer timer
  //                   fired) before I answered: dismiss the ringing screen.
  //   - 'accepted' -> I just tapped Accept: must NOT be touched, or the
  //                   call I'm answering would be killed.
  //   - 'declined' -> I tapped Decline: the ringing screen is already gone.
  // The doc inside a "removed" change can still hold the OLD data (status
  // 'ringing'), so the current status is read again instead. A plain get()
  // asks the server first and only falls back to the local cache when
  // offline - a stale cached 'ringing' simply means nothing is done, and
  // the ringing screen still closes on its own after its 45s duration.
  // (GetOptions(source: Source.server) is not used on purpose: this file
  // also imports audioplayers, which has its own `Source` class, and the
  // two names clash.)
  Future<void> _handleCallLeftRinging(DocumentReference callRef) async {
    try {
      DocumentSnapshot doc;
      try {
        doc = await callRef.get();
      } catch (_) {
        return;
      }
      final data = doc.data() as Map<String, dynamic>?;
      final String? status = data?['status'] as String?;
      final bool callerCancelled = !doc.exists || status == 'ended';
      if (!callerCancelled) return;

      final String roomName = (data?['roomName'] as String?) ?? callRef.id;
      await CallKitService.dismissIncomingCall(roomName);
    } catch (_) {
      // Best-effort - the 45s ring duration remains the fallback.
    }
  }

  Future<void> _showIncomingCall({
    required String callerName,
    required String callerPhoto,
    required String roomName,
    required String myId,
    required DocumentReference callRef,
  }) async {
    _isShowingIncomingCall = true;
    // Shows Android's real native call screen (see call_kit_service.dart)
    // instead of a plain notification - Accept/Decline are handled by
    // CallKitService's own app-wide listener (registered once in
    // main.dart), which is what actually navigates to VideoCallScreen, so
    // there's nothing further to push here.
    await CallKitService.showIncomingCall(
      roomName: roomName,
      callerName: callerName,
      callerPhoto: callerPhoto,
      isVideo: false,
    );
    _isShowingIncomingCall = false;
  }

  // Writes this device's online status + a fresh `lastActive` timestamp to
  // the current user's Firestore doc, so the sparkle-star badge can show
  // live status for other users (see chat_screen.dart/
  // public_profile_screen.dart). Best-effort: a failure here (e.g.
  // offline) just means the badge is briefly stale for other users, not a
  // crash.
  void _setOnlineStatus(bool online) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'isOnline': online,
      'lastActive': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // The heartbeat Timer (started once in initState) now keeps running
    // through backgrounding/screen-lock too, since
    // PresenceForegroundService.kt keeps the process alive for exactly
    // that reason - there's nothing to stop/restart here for it. This
    // resumed call is just an extra correctness nudge (e.g. after a
    // brief OS freeze that a real device might still impose despite the
    // foreground service).
    if (state == AppLifecycleState.resumed) {
      _setOnlineStatus(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceHeartbeatTimer?.cancel();
    kBackgroundChannel.invokeMethod('stopPresenceService').catchError((_) {});
    _rotationController.dispose();
    _swipePageController.dispose();
    _chatSubscription?.cancel();
    BlockService.instance.hidden.removeListener(_recomputeUnread);
    _unreadTotal.dispose();
    _callSubscription?.cancel();
    _dingPlayer.dispose();
    navigateToHomeSignal.removeListener(_onNavigateToHomeSignal);
    NotificationService.pendingChat.removeListener(_openPendingChat);
    NotificationService.pendingFriend.removeListener(_onPendingFriend);
    super.dispose();
  }

  void _onPendingFriend() => _openPendingFriend();

  // Opens what a tapped friend notification points at (4 Oct 2026): a new
  // request -> Friend Requests; an accepted one -> the new friend's
  // profile. If its Confirm / Delete BUTTON was pressed, that is done
  // right away instead (then Confirm shows their profile).
  Future<void> _openPendingFriend() async {
    final Map<String, String>? info = NotificationService.pendingFriend.value;
    if (info == null || !mounted) return;
    NotificationService.pendingFriend.value = null;
    final String userId = info['userId'] ?? '';
    if (userId.isEmpty || BlockService.instance.isHidden(userId)) return;
    final String action = info['action'] ?? '';
    final String name = info['name'] ?? 'Someone';
    if (action == 'confirm' || action == 'delete') {
      final messenger = ScaffoldMessenger.of(context);
      try {
        if (action == 'confirm') {
          await FriendService.instance.accept(userId);
        } else {
          await FriendService.instance.decline(userId);
        }
        messenger.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF2A2340),
          content: Text(action == 'confirm'
              ? 'You and $name are now friends 🎉'
              : 'Friend request deleted'),
        ));
      } catch (_) {
        // Already answered / cancelled by them - the rules refuse it.
        messenger.showSnackBar(const SnackBar(
            content: Text('This friend request is no longer available.')));
        return;
      }
      if (action == 'delete' || !mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PublicProfileScreen(userId: userId)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => info['kind'] == 'friend_request'
            ? const FriendRequestsScreen()
            : PublicProfileScreen(userId: userId),
      ),
    );
  }

  // Opens the chat whose notification was tapped (see NotificationService).
  void _openPendingChat() {
    final Map<String, String>? chat = NotificationService.pendingChat.value;
    if (chat == null || !mounted) return;
    NotificationService.pendingChat.value = null;
    final String userId = chat['userId'] ?? '';
    if (userId.isEmpty || BlockService.instance.isHidden(userId)) return;
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId != null) {
      final List<String> ids = [myId, userId]..sort();
      // Already looking at it - nothing to do.
      if (currentOpenChatId == '${ids[0]}_${ids[1]}') return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          otherUserId: userId,
          otherUserName: chat['name'] ?? 'User',
          otherUserPhoto: chat['photo'] ?? '',
        ),
      ),
    );
  }

  // Shows Flyla's onboarding tour to a brand-new user exactly once (same
  // "remember on the user's doc" pattern as _maybeShowSwipeHintOnce below)
  // before the swipe hint gets its turn - chained rather than fired at
  // the same time, so the swipe hint doesn't silently burn its own
  // one-time flag while the onboarding screen is covering it.
  Future<void> _maybeShowOnboardingOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final docRef =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      try {
        final doc = await docRef.get();
        final bool alreadyShown =
            (doc.data()?['hasSeenOnboarding'] as bool?) ?? false;
        if (!alreadyShown && mounted) {
          await docRef
              .set({'hasSeenOnboarding': true}, SetOptions(merge: true));
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const OnboardingScreen()),
          );
        }
      } catch (_) {
        // Non-critical - worst case onboarding just doesn't show once.
      }
    }
    if (mounted) _maybeShowSwipeHintOnce();
  }

  Future<void> _maybeShowSwipeHintOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    try {
      final doc = await docRef.get();
      final bool alreadyShown = (doc.data()?['sawSwipeHint'] as bool?) ?? false;
      if (alreadyShown || !mounted) return;
      setState(() => _showSwipeHint = true);
      await docRef.set({'sawSwipeHint': true}, SetOptions(merge: true));
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _showSwipeHint = false);
      });
    } catch (_) {
      // Non-critical - worst case the hint just doesn't show once.
    }
  }

  void _selectTab(int index) {
    if (index == 0 && _currentIndex == 0) {
      // Already on Home - tapping Home again scrolls the feed back to the
      // top, the same behavior as the phone's Back button.
      homeFeedScrollToTopSignal.value++;
      return;
    }
    setState(() {
      _currentIndex = index;
    });
    // Keep the swipeable Home/Chat group in sync when one of them is
    // picked from the orbit menu instead of swiped to directly.
    if (index <= 1 && _swipePageController.hasClients) {
      _swipePageController.animateToPage(
        index, // Home=0, Chat=1 - same order in both the menu and the swipe group
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // Prompts for an optional stream title, then opens the go-live screen
  Future<void> _startLiveFlow() async {
    final TextEditingController controller = TextEditingController();
    final String? title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Go Live', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLength: 60,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Give your stream a title... (optional)',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.redAccent),
            ),
            counterStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Go Live',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (title == null) return; // Cancelled
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GoLiveScreen(title: title)),
    );
  }

  // Scales button/icon/text sizes to the screen width so the bottom bar
  // feels right-sized on small phones and large phones alike (baseline
  // ~390dp, clamped so nothing gets comically tiny or huge).
  double _uiScale(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    return (width / 390).clamp(0.85, 1.2);
  }

  // Menu item button. Size stays constant whether active or not — only the
  // color/gradient changes, so selecting a tab never makes the button grow
  // into a bigger box.
  Widget _buildMenuItem(int i) {
    final item = _menuItems[i];
    final bool isActive = _currentIndex == i;
    final List<Color> colors = (item['colors'] as List).cast<Color>();
    final double scale = _uiScale(context);

    return GestureDetector(
      onTap: () {
        if (item['action'] == 'live') {
          _startLiveFlow();
        } else {
          _selectTab(i);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: 14 * scale,
          vertical: 12 * scale,
        ),
        // No background box behind the active icon (so the screen behind
        // the menu row stays visible) - instead, Fly's own take on an
        // "active" indicator: a small satellite dot continuously orbiting
        // the icon, echoing the big orbit button's own theme, rather than
        // the plain highlighted-background pill every other app uses.
        child: SizedBox(
          width: 26 * scale,
          height: 26 * scale,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => (isActive
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: colors,
                          )
                        : const LinearGradient(
                            colors: [Colors.white, Colors.white],
                          ))
                    .createShader(bounds),
                child: Icon(
                  item['icon'],
                  color: Colors.white,
                  size: 26 * scale,
                  shadows: isActive
                      ? [
                          Shadow(
                              color: colors.first.withOpacity(0.7),
                              blurRadius: 12),
                          const Shadow(color: Colors.black54, blurRadius: 6),
                        ]
                      : const [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
              // Unread messages badge on the Chat tab (Fly gradient, pops
              // in/out, "99+" cap) - its own ValueListenableBuilder so a
              // new message never rebuilds the whole bottom bar.
              if (item['label'] == 'Chat')
                Positioned(
                  right: -10 * scale,
                  top: -8 * scale,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _unreadTotal,
                    builder: (context, count, _) => AnimatedScale(
                      scale: count > 0 ? 1 : 0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.elasticOut,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 5 * scale, vertical: 1.5 * scale),
                        constraints: BoxConstraints(
                            minWidth: 18 * scale, minHeight: 18 * scale),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10 * scale),
                          gradient: const LinearGradient(colors: [
                            Color(0xFFFF4B6E),
                            Color(0xFF9C4DFF),
                          ]),
                          border: Border.all(color: Colors.black, width: 1.5),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10 * scale,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (isActive)
                AnimatedBuilder(
                  animation: _rotationController,
                  builder: (context, child) {
                    final double angle = _rotationController.value * 2 * pi;
                    final double orbitRadius = 21 * scale;
                    return Transform.translate(
                      offset: Offset(
                        orbitRadius * cos(angle),
                        orbitRadius * sin(angle),
                      ),
                      child: child,
                    );
                  },
                  child: Container(
                    width: 6 * scale,
                    height: 6 * scale,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.last,
                      boxShadow: [
                        BoxShadow(
                          color: colors.last.withOpacity(0.8),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Handles the phone's system Back button/gesture app-wide, Facebook-style:
  // - Off Home: jump back to Home first instead of exiting.
  // - On Home, feed scrolled down: scroll the feed back to its first video.
  // - On Home, already at the first video: let the app actually exit.
  Future<void> _handleBackPress() async {
    if (_currentIndex != 0) {
      if (_currentIndex <= 1) {
        // Home lives inside the Home/Chat swipe group as local page 0 -
        // animate back to it rather than a hard jump.
        _swipePageController.animateToPage(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      } else {
        // Upload/Profile sit outside the swipe group.
        setState(() => _currentIndex = 0);
      }
      return;
    }

    if (!homeFeedAtTop.value) {
      // Feed is scrolled down - scroll back to the first video and
      // consume this Back press instead of exiting.
      homeFeedScrollToTopSignal.value++;
      return;
    }

    // Already on Home and already at the first video - exit the app.
    //
    // If a call is minimized right now (ActiveCall.hasActiveCall), that
    // exit must not go through SystemNavigator.pop() - that calls
    // Activity.finish() natively, and MainActivity doesn't cache its
    // FlutterEngine, so finishing it destroys the whole Dart isolate:
    // LiveKit's Room, the WebRTC audio pipeline, everything. Pressing
    // Home never hits this at all (Home only pauses/stops the Activity,
    // it doesn't finish it), which is why backing all the way out used
    // to silently kill an in-progress call's audio while its foreground
    // notification and CallKit's own native call notification kept
    // showing right through it - both of those are separate native
    // Android components that don't depend on the engine being alive.
    // moveToBackground (the same method channel call the in-call
    // minimize button already uses) backgrounds the task exactly like
    // Home does, leaving the engine - and the call - untouched.
    if (ActiveCall.hasActiveCall) {
      kBackgroundChannel.invokeMethod('moveToBackground');
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _uiScale(context);
    final double bottomSafe = MediaQuery.of(context).padding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Home/Chat swipe as one continuous horizontal group, Home first
            // - swipe left from Home for Chat, and back again the other way.
            // Upload and Profile stay outside this group (tap-only from the
            // orbit menu below), shown directly instead of via the PageView.
            // The standalone Shorts/Reels tab was removed - videos only live
            // on Home now.
            //
            // NOTE: unlike the old "only the active tab is built" setup, a
            // real swipeable PageView needs its neighbor page already built
            // underneath your finger as you drag.
            _currentIndex <= 1
                ? PageView(
                    controller: _swipePageController,
                    onPageChanged: (localIndex) {
                      setState(() {
                        _currentIndex = _localToCurrentIndex[localIndex];
                      });
                    },
                    children: const [
                      HomeScreen(),
                      ChatScreen(),
                    ],
                  )
                : _screens[_currentIndex],
            // One-time hint teaching people the Home -> Chat swipe exists -
            // a pulsing arrow at the screen edge plus a short caption,
            // auto-dismissing on its own after a few seconds.
            if (_showSwipeHint)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showSwipeHint ? 1 : 0,
                  duration: const Duration(milliseconds: 400),
                  child: Stack(
                    children: [
                      // Only a right-edge hint now - Home is the first page
                      // in the swipe group (no page to its left anymore).
                      Positioned(
                        right: 8,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeInOut,
                            builder: (context, t, child) => Transform.translate(
                              offset:
                                  Offset(6 - 6 * (1 - (2 * t - 1).abs()), 0),
                              child: child,
                            ),
                            child: const Icon(Icons.chevron_right,
                                color: Colors.white70, size: 34),
                          ),
                        ),
                      ),
                      Align(
                        alignment: const Alignment(0, 0.72),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Swipe left for Chat',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Facebook-style bottom navigation bar: Home/Chat/Upload/
            // Profile/Live always visible in a fixed row at the very
            // bottom, evenly spaced - no button to tap to reveal them.
            // While on Home, it tucks away as soon as you swipe down to
            // later videos (immersive view), and slides back the moment you
            // swipe back up - it always stays visible on every other tab.
            ValueListenableBuilder<bool>(
              valueListenable: homeFeedScrollingDown,
              builder: (context, scrollingDown, child) {
                final bool visible = _currentIndex != 0 || !scrollingDown;
                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedSlide(
                      offset: visible ? Offset.zero : const Offset(0, 1),
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOut,
                      child: AnimatedOpacity(
                        opacity: visible ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
              child: Container(
                padding: EdgeInsets.only(bottom: bottomSafe, top: 6 * scale),
                decoration: const BoxDecoration(
                  color: Color(0xFF0B0B0B),
                  border: Border(
                    top: BorderSide(color: Colors.white12, width: 0.5),
                  ),
                ),
                child: SizedBox(
                  height: 52 * scale,
                  child: Row(
                    children: List.generate(
                      _menuItems.length,
                      (i) => Expanded(child: Center(child: _buildMenuItem(i))),
                    ),
                  ),
                ),
              ),
            ),

            // Network-status banner (only visible when weak/offline) and a
            // minimized call, if there is one - stacked in that order so
            // neither ever overlaps the other when both show at once.
            const _TopBars(),
          ],
        ),
      ),
    );
  }
}

// Stacks the network-status banner above the minimized-call bar at the
// very top of the screen. A single Positioned wraps both so they always
// move together and never overlap each other.
class _TopBars extends StatelessWidget {
  const _TopBars();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _NetworkStatusBanner(),
          _MinimizedCallBar(),
        ],
      ),
    );
  }
}

// Thin banner shown at the very top of the app whenever the connection is
// offline or too slow to be reliable - hidden entirely when the
// connection is good, so it adds no visual noise on a normal day.
class _NetworkStatusBanner extends StatelessWidget {
  const _NetworkStatusBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NetworkStatus>(
      valueListenable: NetworkService.instance.status,
      builder: (context, status, child) {
        if (status == NetworkStatus.good) return const SizedBox.shrink();
        final bool offline = status == NetworkStatus.offline;
        return SafeArea(
          bottom: false,
          child: Container(
            color: offline ? const Color(0xFFB71C1C) : const Color(0xFFB8860B),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  offline
                      ? Icons.wifi_off_rounded
                      : Icons
                          .signal_wifi_statusbar_connected_no_internet_4_rounded,
                  color: Colors.white,
                  size: 15,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    offline
                        ? 'No internet connection'
                        : 'Weak connection - some things may load slowly',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
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

// Shown across every tab whenever a call has been minimized (see
// active_call.dart) - lets the person keep browsing Fly and still see,
// at a glance, that they're on a call, with one tap back into it.
class _MinimizedCallBar extends StatefulWidget {
  const _MinimizedCallBar();

  @override
  State<_MinimizedCallBar> createState() => _MinimizedCallBarState();
}

class _MinimizedCallBarState extends State<_MinimizedCallBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Cheap once-a-second rebuild so the elapsed-time text stays live -
    // ActiveCall itself doesn't need to be a ChangeNotifier for just this.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _formatElapsed(DateTime since) {
    final int totalSeconds = DateTime.now().difference(since).inSeconds;
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!ActiveCall.hasActiveCall) return const SizedBox.shrink();
    final String name = ActiveCall.otherName ?? 'Ongoing call';
    final DateTime since = ActiveCall.connectedAt ?? DateTime.now();

    // No outer Positioned here anymore - the parent _TopBars already
    // positions this (and the network banner above it) together.
    return SafeArea(
      bottom: false,
      child: Material(
        color: const Color(0xFF24D17E),
        child: InkWell(
          onTap: () {
            final String? roomName = ActiveCall.roomName;
            final myId = FirebaseAuth.instance.currentUser?.uid;
            if (roomName == null || myId == null) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => VideoCallScreen(
                  roomName: roomName,
                  myName: myId,
                  otherName: ActiveCall.otherName,
                  otherPhoto: ActiveCall.otherPhoto,
                  startWithCamera: ActiveCall.startWithCamera,
                  fromIncomingCall: ActiveCall.fromIncomingCall,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.call, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'On call with $name',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatElapsed(since),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.keyboard_arrow_up,
                    color: Colors.white, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

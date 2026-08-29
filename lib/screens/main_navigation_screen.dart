import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import '../notification_service.dart';
import '../call_kit_service.dart';
import '../active_call.dart';
import 'video_call_screen.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'upload_screen.dart';
import 'profile_screen.dart';
import 'live_screen.dart';
import 'gifting.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isMenuOpen = false;

  double _buttonRight = 24;
  // Home/Chat are swipeable as a horizontal group (Home first, swipe left
  // for Chat) - Upload/Profile stay tap-only via the orbit menu, not part
  // of this swipe group. The standalone Shorts/Reels tab was removed -
  // videos only live on Home now.
  late final PageController _swipePageController;
  static const List<int> _localToCurrentIndex = [0, 1]; // Home, Chat
  // One-time onboarding hint teaching people they can swipe from Home to
  // Chat, since that gesture isn't discoverable on its own - shown once
  // ever per account, then never again.
  bool _showSwipeHint = false;
  double _buttonBottom = 90;
  double _dragDistance = 0;

  late AnimationController _rotationController;

  StreamSubscription<QuerySnapshot>? _chatSubscription;
  bool _firstSnapshot = true;

  // Incoming call listener
  StreamSubscription<QuerySnapshot>? _callSubscription;
  bool _firstCallSnapshot = true;
  bool _isShowingIncomingCall = false;

  // Message notification sound (generated in code, no audio file)
  final AudioPlayer _dingPlayer = AudioPlayer();
  Uint8List? _dingBytes;

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
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _swipePageController = PageController(initialPage: 0); // start on Home
    _maybeShowSwipeHintOnce();
    _listenForNewMessages();
    _listenForIncomingCalls();
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
  void _listenForNewMessages() {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    _chatSubscription = FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: myId)
        .snapshots()
        .listen((snapshot) async {
      if (_firstSnapshot) {
        _firstSnapshot = false;
        return;
      }

      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.modified) {
          final data = change.doc.data() as Map<String, dynamic>?;
          if (data == null) continue;

          final String lastSenderId = data['lastSenderId'] ?? '';
          final String lastMessage = data['lastMessage'] ?? '';

          if (lastSenderId.isNotEmpty && lastSenderId != myId) {
            // Play the in-app notification sound
            _playDing();

            final senderDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(lastSenderId)
                .get();
            final senderName =
                (senderDoc.data()?['displayName'] as String?) ?? 'New message';

            await NotificationService.showMessageNotification(
              title: senderName,
              body: lastMessage,
            );
          }
        }
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

  @override
  void dispose() {
    _rotationController.dispose();
    _swipePageController.dispose();
    _chatSubscription?.cancel();
    _callSubscription?.cancel();
    _dingPlayer.dispose();
    navigateToHomeSignal.removeListener(_onNavigateToHomeSignal);
    super.dispose();
  }

  void _toggleMenu() {
    setState(() {
      _isMenuOpen = !_isMenuOpen;
    });
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

  // Scales button/icon/text sizes to the screen width so the menu feels
  // right-sized on small phones and large phones alike (baseline ~390dp,
  // clamped so nothing gets comically tiny or huge).
  double _uiScale(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    return (width / 390).clamp(0.85, 1.2);
  }

  void _onPanStart(DragStartDetails details) {
    _dragDistance = 0;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _buttonRight -= details.delta.dx;
      _buttonBottom -= details.delta.dy;
      _dragDistance += details.delta.distance;

      final screenSize = MediaQuery.of(context).size;
      final safePadding = MediaQuery.of(context).padding;
      final double buttonSize = 56 * _uiScale(context);

      // Free to move anywhere on screen (including over the video), only
      // kept clear of the notch/status bar and system nav bar.
      final double minRight = safePadding.left;
      const double minBottom = 0;
      final double maxRight = screenSize.width - buttonSize - safePadding.right;
      final double maxBottom =
          screenSize.height - buttonSize - safePadding.top - safePadding.bottom;

      if (_buttonRight < minRight) _buttonRight = minRight;
      if (_buttonBottom < minBottom) _buttonBottom = minBottom;
      if (_buttonRight > maxRight) _buttonRight = maxRight;
      if (_buttonBottom > maxBottom) _buttonBottom = maxBottom;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragDistance < 5) {
      _toggleMenu();
    }
  }

  // Accent color for the glowing glass button (teal/cyan)
  static const Color _glowColor = Color(0xFF2EF2C7);

  Widget _buildMainButton(BuildContext context) {
    final double scale = _uiScale(context);
    final double size = 56 * scale;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Dark frosted-glass look
        color: const Color(0xFF1B1F22).withOpacity(0.85),
        border: Border.all(
          color: _glowColor.withOpacity(0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: _glowColor.withOpacity(0.35),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child:
                  _isMenuOpen ? _buildCloseIcon(scale) : _buildOrbitIcon(scale),
            ),
          ),
        ),
      ),
    );
  }

  // Glowing close (X) icon shown when the menu is open
  Widget _buildCloseIcon(double scale) {
    return Icon(
      Icons.close_rounded,
      key: const ValueKey('close'),
      color: _glowColor,
      size: 26 * scale,
      shadows: [
        Shadow(color: _glowColor.withOpacity(0.9), blurRadius: 14),
      ],
    );
  }

  // Rotating orbit rings with a sparkle in the center, shown when the menu
  // is closed
  Widget _buildOrbitIcon(double scale) {
    return SizedBox(
      key: const ValueKey('orbit'),
      width: 30 * scale,
      height: 30 * scale,
      child: AnimatedBuilder(
        animation: _rotationController,
        builder: (context, child) {
          final double t = _rotationController.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              _orbitRing(angle: t * 2 * pi, squeeze: 1.0, scale: scale),
              _orbitRing(
                  angle: -t * 2 * pi + pi / 3, squeeze: 0.45, scale: scale),
              Icon(
                Icons.auto_awesome_rounded,
                color: _glowColor,
                size: 13 * scale,
                shadows: [
                  Shadow(color: _glowColor.withOpacity(0.9), blurRadius: 10),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  // A single elliptical orbit ring: a circle rotated and squeezed on one
  // axis so it reads as an ellipse crossing the center
  Widget _orbitRing(
      {required double angle, required double squeeze, required double scale}) {
    return Transform.rotate(
      angle: angle,
      child: Transform.scale(
        scaleX: squeeze,
        child: Container(
          width: 28 * scale,
          height: 28 * scale,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _glowColor.withOpacity(0.9),
              width: 1.6,
            ),
          ),
        ),
      ),
    );
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
            // Small menu pills (Home/Chat/Upload/Profile/Live) - always
            // fixed at the very bottom, regardless of where the big button is.
            if (_isMenuOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8 + bottomSafe,
                child: SizedBox(
                  height: 64 * scale,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: List.generate(
                      _menuItems.length,
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: _buildMenuItem(i),
                      ),
                    ),
                  ),
                ),
              ),
            // Big orbit button - free to be dragged anywhere on screen,
            // including up over the video.
            Positioned(
              right: _buttonRight,
              bottom: _buttonBottom + bottomSafe,
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: _buildMainButton(context),
              ),
            ),

            // A minimized call, if there is one - tap to jump straight back
            // into VideoCallScreen, which reclaims the still-running Room
            // (see active_call.dart) instead of reconnecting.
            const _MinimizedCallBar(),
          ],
        ),
      ),
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

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
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
      ),
    );
  }
}

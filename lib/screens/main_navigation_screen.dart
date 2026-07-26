import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import '../notification_service.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'upload_screen.dart';
import 'profile_screen.dart';
import 'incoming_call_screen.dart';
import 'live_screen.dart';

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
    ShortsScreen(),
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
      'icon': Icons.theaters_rounded,
      'label': 'Reels',
      'colors': [Color(0xFFFF7A3D), Color(0xFFE64A19)],
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
    _listenForNewMessages();
    _listenForIncomingCalls();
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
        return;
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => IncomingCallScreen(
          callerName: callerName,
          callerPhoto: callerPhoto,
          roomName: roomName,
          myId: myId,
          callRef: callRef,
        ),
      ),
    );
    _isShowingIncomingCall = false;
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _chatSubscription?.cancel();
    _callSubscription?.cancel();
    _dingPlayer.dispose();
    super.dispose();
  }

  void _toggleMenu() {
    setState(() {
      _isMenuOpen = !_isMenuOpen;
    });
  }

  void _selectTab(int index) {
    setState(() {
      _currentIndex = index;
    });
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
          horizontal: (isActive ? 18 : 14) * scale,
          vertical: 12 * scale,
        ),
        decoration: BoxDecoration(
          gradient: isActive
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                )
              : null,
          borderRadius: BorderRadius.circular(20),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: colors.first.withOpacity(0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item['icon'],
              color: Colors.white,
              size: 26 * scale,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: isActive
                  ? Padding(
                      padding: EdgeInsets.only(left: 8 * scale),
                      child: Text(
                        item['label'],
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14 * scale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _uiScale(context);
    final double bottomSafe = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Only the active tab is built. An IndexedStack would keep the
          // video tabs alive in the background, so their audio kept
          // playing after switching to Chat/Upload/Profile.
          _screens[_currentIndex],
          // Small menu pills (Home/Reels/Chat/Upload/Profile/Live) - always
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
        ],
      ),
    );
  }
}

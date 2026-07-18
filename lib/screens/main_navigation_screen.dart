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
  double _buttonBottom = 24;
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

  void _onPanStart(DragStartDetails details) {
    _dragDistance = 0;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _buttonRight -= details.delta.dx;
      _buttonBottom -= details.delta.dy;
      _dragDistance += details.delta.distance;

      final screenSize = MediaQuery.of(context).size;
      if (_buttonRight < 0) _buttonRight = 0;
      if (_buttonBottom < 0) _buttonBottom = 0;
      if (_buttonRight > screenSize.width - 56) {
        _buttonRight = screenSize.width - 56;
      }
      if (_buttonBottom > screenSize.height - 56) {
        _buttonBottom = screenSize.height - 56;
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragDistance < 5) {
      _toggleMenu();
    }
  }

  // Accent color for the glowing glass button (teal/cyan)
  static const Color _glowColor = Color(0xFF2EF2C7);

  Widget _buildMainButton() {
    return Container(
      width: 56,
      height: 56,
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
              child: _isMenuOpen ? _buildCloseIcon() : _buildOrbitIcon(),
            ),
          ),
        ),
      ),
    );
  }

  // Glowing close (X) icon shown when the menu is open
  Widget _buildCloseIcon() {
    return Icon(
      Icons.close_rounded,
      key: const ValueKey('close'),
      color: _glowColor,
      size: 26,
      shadows: [
        Shadow(color: _glowColor.withOpacity(0.9), blurRadius: 14),
      ],
    );
  }

  // Rotating orbit rings with a sparkle in the center, shown when the menu
  // is closed
  Widget _buildOrbitIcon() {
    return SizedBox(
      key: const ValueKey('orbit'),
      width: 30,
      height: 30,
      child: AnimatedBuilder(
        animation: _rotationController,
        builder: (context, child) {
          final double t = _rotationController.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              _orbitRing(angle: t * 2 * pi, squeeze: 1.0),
              _orbitRing(angle: -t * 2 * pi + pi / 3, squeeze: 0.45),
              Icon(
                Icons.auto_awesome_rounded,
                color: _glowColor,
                size: 13,
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
  Widget _orbitRing({required double angle, required double squeeze}) {
    return Transform.rotate(
      angle: angle,
      child: Transform.scale(
        scaleX: squeeze,
        child: Container(
          width: 28,
          height: 28,
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

    return GestureDetector(
      onTap: () => _selectTab(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 18 : 14,
          vertical: 12,
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
              size: 26,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        item['label'],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: _screens,
          ),
          if (_isMenuOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.15),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
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
                ),
              ),
            ),
          Positioned(
            right: _buttonRight,
            bottom: _buttonBottom,
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: _buildMainButton(),
            ),
          ),
        ],
      ),
    );
  }
}

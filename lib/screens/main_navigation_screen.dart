import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import '../notification_service.dart';
import '../call_kit_service.dart';
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
    CoinService.instance.awardDailyLogin();
    // Runs after the first frame so the dialog has a ready context - not
    // urgent enough to block anything on screen.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeAskForBackgroundRunPermission());
  }

  // Same problem WhatsApp/Messenger solve with their own "let X run in the
  // background" onboarding step: on Xiaomi/Oppo/Vivo/etc, Android's own
  // battery saver can suspend Fly the moment it's not on screen, which
  // silently breaks incoming-call pushes and message notifications - no
  // amount of app-side code can override this, only the user granting the
  // OS-level exemption can. This shows a plain-language explanation first
  // (so the system permission dialog that follows doesn't feel random),
  // then triggers Android's own permission prompt.
  Future<void> _maybeAskForBackgroundRunPermission() async {
    try {
      final PermissionStatus status =
          await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) return;
      if (!mounted) return;

      final bool? proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            'Keep calls and messages reliable',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            "Some phones pause apps running in the background to save "
            "battery. So incoming calls and notifications always reach "
            "you - even when Fly isn't open - please allow Fly to run "
            "in the background.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Not now', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow',
                  style: TextStyle(
                      color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (proceed == true) {
        // Opens Android's own system dialog for this specific permission -
        // same one-tap flow WhatsApp uses, no manual Settings navigation.
        await Permission.ignoreBatteryOptimizations.request();
      }

      // A third, separate permission ("draw over other apps" - MIUI calls
      // it "Display pop-up windows while running in the background") that
      // some phones require before a full-screen incoming-call notice can
      // actually pop up over the lock screen / other apps, even once
      // battery optimization and autostart are already sorted. Without
      // it, the push still arrives and the app still runs in the
      // background, but the call screen itself never becomes visible.
      await _maybeAskForOverlayPermission();

      // Android 14+ specifically: full-screen incoming-call notices need
      // their own separate permission here too - it's granted by default
      // only to apps the OS recognizes as calling/alarm apps, which a
      // sideloaded app like Fly isn't automatically classified as. This
      // is on top of, not instead of, the overlay permission above - both
      // are needed for the call screen to actually appear.
      await _maybeAskForFullScreenIntentPermission();

      // Standard Android battery optimization covers most phones, but
      // Xiaomi/Oppo/Vivo/Huawei add their own separate "Autostart" /
      // "Auto-launch" toggle on top of it, outside the standard Android
      // permission system entirely - there's no unified API for this
      // across manufacturers, which is why even WhatsApp/Messenger link
      // straight to each brand's own settings screen for it instead of
      // trying to request it like a normal permission.
      await _maybeOfferAutostartSettings();
    } catch (_) {
      // Non-critical - worst case, the user just doesn't get asked and
      // can still turn it on manually from the phone's Settings.
    }
  }

  // "Draw over other apps" (SYSTEM_ALERT_WINDOW) - the permission that
  // actually lets a full-screen incoming-call notice pop up over the lock
  // screen / whatever else is on screen. On plain Android this is usually
  // pre-granted for apps installed normally, but MIUI in particular ships
  // it off by default under the name "Display pop-up windows while
  // running in the background", which silently blocks the call screen
  // from appearing at all even once battery optimization and autostart
  // are both already sorted.
  Future<void> _maybeAskForOverlayPermission() async {
    final PermissionStatus status = await Permission.systemAlertWindow.status;
    if (status.isGranted) return;
    if (!mounted) return;

    final bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'One more permission for incoming calls',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "So the incoming-call screen can actually pop up over your "
          "lock screen (some phones call this \"display pop-up windows "
          "while running in the background\"), please allow it on the "
          "next screen.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (proceed == true) {
      await Permission.systemAlertWindow.request();
    }
  }

  // Android 14 (API 34) made full-screen call/alarm notifications a
  // "special app access" permission that's off by default for any app
  // the OS doesn't already recognize as a phone/dialer or alarm app -
  // which a sideloaded app like Fly never is. There's no in-app system
  // dialog for this one (unlike battery optimization) - it can only be
  // granted from its own Settings page, which this opens directly via
  // Android's own intent for it.
  Future<void> _maybeAskForFullScreenIntentPermission() async {
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt < 34) return; // only exists on Android 14+
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Allow full-screen incoming calls',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "Your phone's version of Android added a setting specifically "
          "for apps showing a full-screen call notice. On the next "
          'screen, please turn this on for Fly so incoming calls can '
          'appear over your lock screen.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      final intent = AndroidIntent(
        action: 'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT',
        data: 'package:com.example.fly',
      );
      await intent.launch();
    } catch (_) {
      // Older/unusual builds of Android 14 that don't expose this exact
      // settings page - nothing more to do automatically.
    }
  }

  // Deep-links straight to the manufacturer's own autostart/background
  // permission screen, on the handful of Android skins known to need one -
  // Xiaomi (MIUI), Oppo (ColorOS), Vivo (FuntouchOS), and Huawei/Honor
  // (EMUI/MagicUI). Every entry is a native activity component that
  // varies by ROM version, so this is best-effort by nature: on models/
  // versions where the component doesn't match, the launch just silently
  // fails and the user can still find the same toggle manually.
  Future<void> _maybeOfferAutostartSettings() async {
    late String manufacturer;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      manufacturer = info.manufacturer.toLowerCase();
    } catch (_) {
      return;
    }

    const Map<String, Map<String, String>> kAutostartActivities = {
      'xiaomi': {
        'pkg': 'com.miui.securitycenter',
        'cls': 'com.miui.permcenter.autostart.AutoStartManagementActivity',
      },
      'redmi': {
        'pkg': 'com.miui.securitycenter',
        'cls': 'com.miui.permcenter.autostart.AutoStartManagementActivity',
      },
      'oppo': {
        'pkg': 'com.coloros.safecenter',
        'cls':
            'com.coloros.safecenter.permission.startup.StartupAppListActivity',
      },
      'vivo': {
        'pkg': 'com.vivo.permissionmanager',
        'cls': 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
      },
      'huawei': {
        'pkg': 'com.huawei.systemmanager',
        'cls':
            'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
      },
      'honor': {
        'pkg': 'com.huawei.systemmanager',
        'cls':
            'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
      },
    };

    String? matchedBrand;
    for (final brand in kAutostartActivities.keys) {
      if (manufacturer.contains(brand)) {
        matchedBrand = brand;
        break;
      }
    }
    if (matchedBrand == null) return;
    if (!mounted) return;

    final String displayName =
        matchedBrand[0].toUpperCase() + matchedBrand.substring(1);
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          'One more step for $displayName phones',
          style:
              const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          "$displayName phones have their own separate \"Autostart\" "
          "switch. Please turn it on for Fly on the next screen, so "
          "calls keep coming through even when the app isn't open.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      final info = kAutostartActivities[matchedBrand]!;
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: info['pkg'],
        componentName: info['cls'],
      );
      await intent.launch();
    } catch (_) {
      // This exact screen isn't reachable on this ROM version - nothing
      // more can be done automatically.
    }
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
        child: Icon(
          item['icon'],
          color: Colors.white,
          size: 26 * scale,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
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

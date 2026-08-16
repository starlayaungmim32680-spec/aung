import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import '../notification_service.dart';
import 'video_call_screen.dart';

// Full-screen "incoming call" UI, shown when someone is calling you
class IncomingCallScreen extends StatefulWidget {
  final String callerName;
  final String callerPhoto;
  final String roomName;
  final String myId;
  final DocumentReference callRef;

  const IncomingCallScreen({
    super.key,
    required this.callerName,
    required this.callerPhoto,
    required this.roomName,
    required this.myId,
    required this.callRef,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  Timer? _vibrateTimer;
  final AudioPlayer _ringPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _startVibrating();
    _startRingtone();
  }

  void _startVibrating() {
    HapticFeedback.heavyImpact();
    _vibrateTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      HapticFeedback.heavyImpact();
    });
  }

  void _stopVibrating() {
    _vibrateTimer?.cancel();
    _vibrateTimer = null;
  }

  Future<void> _startRingtone() async {
    try {
      final bytes = _generateRingtoneWav();
      await _ringPlayer.setReleaseMode(ReleaseMode.loop);
      await _ringPlayer.play(BytesSource(bytes));
    } catch (_) {}
  }

  Future<void> _stopRingtone() async {
    try {
      await _ringPlayer.stop();
    } catch (_) {}
  }

  Uint8List _generateRingtoneWav() {
    const int sampleRate = 44100;
    const double ringDur = 1.2;
    const double silenceDur = 1.4;
    final int ringSamples = (sampleRate * ringDur).round();
    final int silenceSamples = (sampleRate * silenceDur).round();
    final int totalSamples = ringSamples + silenceSamples;
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

    for (int i = 0; i < ringSamples; i++) {
      final double t = i / sampleRate;
      final bool high = ((t * 25).floor() % 2) == 0;
      final double freq = high ? 480.0 : 620.0;
      double amp = 0.6;
      const double fade = 0.02;
      if (t < fade) amp *= t / fade;
      if (t > ringDur - fade) amp *= (ringDur - t) / fade;
      int s = (sin(2 * pi * freq * t) * amp * 32767).round();
      if (s > 32767) s = 32767;
      if (s < -32768) s = -32768;
      data.setInt16(offset, s, Endian.little);
      offset += 2;
    }
    for (int i = 0; i < silenceSamples; i++) {
      data.setInt16(offset, 0, Endian.little);
      offset += 2;
    }

    return data.buffer.asUint8List();
  }

  Future<void> _accept() async {
    _stopVibrating();
    await _stopRingtone();
    await NotificationService.cancelIncomingCallNotification();
    try {
      await widget.callRef.update({'status': 'accepted'});
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => VideoCallScreen(
          roomName: widget.roomName,
          myName: widget.myId,
          otherName: widget.callerName,
          otherPhoto: widget.callerPhoto,
        ),
      ),
    );
  }

  Future<void> _decline() async {
    _stopVibrating();
    await _stopRingtone();
    await NotificationService.cancelIncomingCallNotification();
    try {
      await widget.callRef.update({'status': 'declined'});
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _stopVibrating();
    _ringPlayer.dispose();
    // Fallback: make sure the notification never gets stuck if this screen
    // is dismissed some other way (e.g. system back gesture).
    NotificationService.cancelIncomingCallNotification();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasPhoto = widget.callerPhoto.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // WhatsApp/Messenger-style full-bleed background: the caller's
          // own photo, blurred and darkened, instead of a small avatar on
          // a plain background. Falls back to the app's gradient when
          // there's no photo to show.
          if (hasPhoto)
            Image.network(
              widget.callerPhoto,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const _FallbackGradient(),
            )
          else
            const _FallbackGradient(),
          if (hasPhoto)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 35, sigmaY: 35),
              child: Image.network(
                widget.callerPhoto,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            ),
          // Darken top-to-bottom so the name/buttons stay readable over
          // any photo.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.55),
                  Colors.black.withOpacity(0.25),
                  Colors.black.withOpacity(0.75),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 56,
                    backgroundColor: Colors.grey[850],
                    backgroundImage:
                        hasPhoto ? NetworkImage(widget.callerPhoto) : null,
                    child: !hasPhoto
                        ? Text(
                            widget.callerName.isNotEmpty
                                ? widget.callerName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 42,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.callerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 12)],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Incoming call...',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                  ),
                ),
                const Spacer(flex: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 44),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CallActionButton(
                        onTap: _decline,
                        color: const Color(0xFFE53E3E),
                        icon: Icons.call_end,
                        label: 'Decline',
                      ),
                      _CallActionButton(
                        onTap: _accept,
                        color: const Color(0xFF24D17E),
                        icon: Icons.call,
                        label: 'Accept',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 36),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A0E3D), Color(0xFF0E0E0E)],
        ),
      ),
    );
  }
}

// A call-action circle (decline/accept) with a soft shadow and its label
// underneath - sized and spaced to match WhatsApp/Messenger's incoming
// call buttons.
class _CallActionButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color color;
  final IconData icon;
  final String label;

  const _CallActionButton({
    required this.onTap,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.5),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
          ),
        ),
      ],
    );
  }
}

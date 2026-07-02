import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
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

  // Plays a looping ringtone generated in code (no audio file needed)
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

  // Builds a WAV byte buffer for one ring cycle: a warble tone then silence.
  // Played on loop, this sounds like a classic phone ring.
  Uint8List _generateRingtoneWav() {
    const int sampleRate = 44100;
    const double ringDur = 1.2; // seconds of ringing
    const double silenceDur = 1.4; // seconds of gap
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

    // WAV header (16-bit mono PCM)
    writeString('RIFF');
    writeUint32(36 + dataSize);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(1); // mono
    writeUint32(sampleRate);
    writeUint32(sampleRate * 2); // byte rate
    writeUint16(2); // block align
    writeUint16(16); // bits per sample
    writeString('data');
    writeUint32(dataSize);

    // Ring: warble between two tones for a phone-ring feel
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
    // Silence gap
    for (int i = 0; i < silenceSamples; i++) {
      data.setInt16(offset, 0, Endian.little);
      offset += 2;
    }

    return data.buffer.asUint8List();
  }

  Future<void> _accept() async {
    _stopVibrating();
    await _stopRingtone();
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
        ),
      ),
    );
  }

  Future<void> _decline() async {
    _stopVibrating();
    await _stopRingtone();
    try {
      await widget.callRef.update({'status': 'declined'});
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _stopVibrating();
    _ringPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
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
                radius: 60,
                backgroundColor: Colors.grey[850],
                backgroundImage: widget.callerPhoto.isNotEmpty
                    ? NetworkImage(widget.callerPhoto)
                    : null,
                child: widget.callerPhoto.isEmpty
                    ? Text(
                        widget.callerName.isNotEmpty
                            ? widget.callerName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              widget.callerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Incoming video call...',
              style: TextStyle(color: Colors.white60, fontSize: 15),
            ),
            const Spacer(flex: 3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 50),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _decline,
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.call_end,
                              color: Colors.white, size: 32),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Decline',
                          style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _accept,
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: const BoxDecoration(
                            color: Color(0xFF24D17E),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.videocam,
                              color: Colors.white, size: 32),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Accept',
                          style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(flex: 1),
          ],
        ),
      ),
    );
  }
}
// 20 Nov 2026 - "View history": see who viewed your videos.
//
// Opt-in and fair, like the big apps do it:
//   - OFF by default; turned on in Settings after confirming the person
//     is 16 or older (Fly does not keep the date of birth, so this is a
//     confirmation, saved as users/{uid}.viewHistory = true).
//   - It works both ways: you see who viewed your videos only while yours
//     is on, and you are shown on other people's lists only while yours
//     is on. Turning it off hides you from every list at once.
//   - Only views from the last 30 days.
// The list itself comes from the Worker (POST /post-viewers), which
// checks all of this on the server - the app never reads the raw
// posts/{postId}/views list.

import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../block_service.dart';
import 'public_profile_screen.dart';
import 'video_call_screen.dart' show kTokenServerUrl;
import 'worker_auth.dart';

class ViewHistory {
  ViewHistory._();

  static DocumentReference<Map<String, dynamic>>? _myDoc() {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid);
  }

  /// Is MY view history on? (live)
  static Stream<bool> myStream() {
    final DocumentReference<Map<String, dynamic>>? doc = _myDoc();
    if (doc == null) return Stream<bool>.value(false);
    return doc
        .snapshots()
        .map((d) => (d.data()?['viewHistory'] as bool?) ?? false);
  }

  /// Asks first (what it means + 16 or older), then turns it on.
  /// Returns true when it is on afterwards.
  static Future<bool> turnOn(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Turn on view history?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Point(
                icon: Icons.visibility_outlined,
                text: 'See who viewed your videos in the last 30 days.'),
            _Point(
                icon: Icons.swap_horiz_rounded,
                text: 'It works both ways: people who also have it on will '
                    'see when you view their videos.'),
            _Point(
                icon: Icons.toggle_off_outlined,
                text: 'Turn it off any time in Settings - then you are not '
                    'shown to anyone.'),
            _Point(
                icon: Icons.cake_outlined,
                text: 'Only for people aged 16 and over.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now', style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("I'm 16 or older - turn on"),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    return _set(true);
  }

  static Future<bool> turnOff() async {
    await _set(false);
    return false;
  }

  static Future<bool> _set(bool on) async {
    final DocumentReference<Map<String, dynamic>>? doc = _myDoc();
    if (doc == null) return false;
    try {
      await doc.set({
        'viewHistory': on,
        'viewHistoryChangedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return on;
    } catch (_) {
      return !on;
    }
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13.5, height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// The switch for the Settings screen.
class ViewHistorySettingTile extends StatelessWidget {
  const ViewHistorySettingTile({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: ViewHistory.myStream(),
      builder: (context, snap) {
        final bool on = snap.data ?? false;
        return SwitchListTile(
          secondary: const Icon(Icons.visibility_outlined, color: Colors.white),
          title:
              const Text('View history', style: TextStyle(color: Colors.white)),
          subtitle: const Text(
              'See who viewed your videos - both sides must turn it on',
              style: TextStyle(color: Colors.white54, fontSize: 12.5)),
          value: on,
          activeTrackColor: const Color(0xFF9C4DFF),
          onChanged: (v) {
            if (v) {
              ViewHistory.turnOn(context);
            } else {
              ViewHistory.turnOff();
            }
          },
        );
      },
    );
  }
}

/// Owner only: the "Viewers" sheet of one of my videos.
Future<void> showPostViewersSheet(BuildContext context, String postId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121216),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ViewersSheet(postId: postId),
  );
}

class _Viewer {
  final String uid;
  final String name;
  final String photo;
  final DateTime? at;
  const _Viewer(this.uid, this.name, this.photo, this.at);
}

class _ViewersResult {
  final bool needSetting;
  final List<_Viewer> viewers;
  const _ViewersResult(this.needSetting, this.viewers);
}

class _ViewersSheet extends StatefulWidget {
  final String postId;
  const _ViewersSheet({required this.postId});

  @override
  State<_ViewersSheet> createState() => _ViewersSheetState();
}

class _ViewersSheetState extends State<_ViewersSheet> {
  late Future<_ViewersResult> _future = _load();

  Future<_ViewersResult> _load() async {
    final http.Response res = await http
        .post(
          Uri.parse('$kTokenServerUrl/post-viewers'),
          headers: {
            ...await workerAuthHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'postId': widget.postId}),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('post-viewers ${res.statusCode}');
    }
    final Map<String, dynamic> data =
        jsonDecode(res.body) as Map<String, dynamic>;
    final List<_Viewer> list = [];
    for (final Object? v in (data['viewers'] as List?) ?? const []) {
      if (v is! Map) continue;
      final String uid = (v['uid'] as String?) ?? '';
      if (uid.isEmpty || BlockService.instance.isHidden(uid)) continue;
      final int at = (v['at'] as num?)?.toInt() ?? 0;
      list.add(_Viewer(
        uid,
        (v['name'] as String?) ?? '',
        (v['photo'] as String?) ?? '',
        at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      ));
    }
    return _ViewersResult(data['needSetting'] == true, list);
  }

  void _reload() => setState(() => _future = _load());

  static String _ago(DateTime? t) {
    if (t == null) return '';
    final Duration d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _message(IconData icon, String title, String text,
      {String? button, VoidCallback? onTap}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white38, size: 40),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFF9A9AA6), fontSize: 13, height: 1.4)),
            if (button != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                onPressed: onTap,
                child: Text(button),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Viewers',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'Last 30 days · only people with view history on',
              style: TextStyle(color: Color(0xFF9A9AA6), fontSize: 12),
            ),
            const SizedBox(height: 10),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: FutureBuilder<_ViewersResult>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  if (snap.hasError || !snap.hasData) {
                    return _message(
                        Icons.wifi_off_rounded,
                        "Couldn't load viewers",
                        'Check your connection and try again.',
                        button: 'Try again',
                        onTap: _reload);
                  }
                  final _ViewersResult r = snap.data!;
                  if (r.needSetting) {
                    return _message(
                      Icons.visibility_outlined,
                      'See who viewed your video',
                      'Turn on view history. People who also have it on '
                          'will see when you view their videos too.',
                      button: 'Turn on view history',
                      onTap: () async {
                        final bool on = await ViewHistory.turnOn(context);
                        if (on && mounted) _reload();
                      },
                    );
                  }
                  if (r.viewers.isEmpty) {
                    return _message(
                        Icons.people_outline_rounded,
                        'No one to show yet',
                        'Viewers appear here when they also have view '
                            'history on.');
                  }
                  return ListView.builder(
                    itemCount: r.viewers.length,
                    itemBuilder: (context, i) {
                      final _Viewer v = r.viewers[i];
                      final String name =
                          v.name.trim().isNotEmpty ? v.name.trim() : 'Fly user';
                      return ListTile(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PublicProfileScreen(userId: v.uid),
                          ),
                        ),
                        leading: CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.grey[850],
                          backgroundImage: v.photo.isNotEmpty
                              ? CachedNetworkImageProvider(v.photo)
                              : null,
                          child: v.photo.isEmpty
                              ? Text(name[0].toUpperCase(),
                                  style: const TextStyle(color: Colors.white))
                              : null,
                        ),
                        title: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(_ago(v.at),
                            style: const TextStyle(
                                color: Color(0xFF9A9AA6), fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: Colors.white38),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Report a post, comment / reply or user (25 Oct 2026, Report system
// step 1).
//
// One shared sheet for every "Report" button. The report goes to the
// Worker (POST /report in cloudflare/livekit_token_worker.js), not straight
// into Firestore, because the Worker decides what happens:
//   - one report per person per target (accounts younger than 24 h
//     don't count);
//   - the number of reports never hides anything by itself (26 Oct 2026,
//     against groups ganging up on a good video): the AI checks it on
//     the first report, and again more strictly when 3 people report the
//     same reason - hidden only if the AI agrees; otherwise a public post
//     just leaves For You / Search and Ko reviews it;
//   - users are never hidden automatically.
// Who reported is never shown to anyone. Older app builds still write
// `reports` directly (kept by firestore.rules), but those don't count.
//
// 27 Oct 2026 (step 2): like Facebook / TikTok, a video I reported is
// covered for ME right away ("You won't see this video again"), whatever
// the Worker decides - [ReportedPosts], kept on this phone.
//
// 30 Oct 2026: the big feeds (Home For You / Following, Shorts) also LEAVE
// OUT videos I reported - not at once (that would make the feed jump under
// my finger), but the next time the feed is loaded: app start / sign-in
// ([ReportedPosts.loaded]), switching For You <-> Following, Back to the
// top, or opening Shorts. Until then the cover shows.
//
// 29 Oct 2026: [sendReport] returns a [ReportResult] instead of a bool, so
// the snackbar says what really happened (my own content, already gone,
// no connection) instead of one generic "Could not send the report".
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../app_config.dart';
import 'worker_auth.dart';

/// The posts I reported, per account, on this phone (newest last, max
/// [_max]). 27 Oct 2026 fix: kept per signed-in account - before, a second
/// account on the same phone also saw the cover.
class ReportedPosts {
  ReportedPosts._() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid != _uid) _load(user?.uid);
    });
    _load(FirebaseAuth.instance.currentUser?.uid);
  }
  static final ReportedPosts instance = ReportedPosts._();

  static const String _prefsKeyBase = 'reported_posts_v2_';
  static const int _max = 500;

  final ValueNotifier<Set<String>> ids = ValueNotifier<Set<String>>(<String>{});

  /// Fires once this account's list has been read from the phone (app
  /// start, sign-in, account switch) - the feeds then take a fresh copy of
  /// [ids] to leave out. Reporting a video does NOT change it (30 Oct 2026).
  final ValueNotifier<int> loaded = ValueNotifier<int>(0);
  String? _uid;

  bool contains(String? postId) =>
      postId != null && postId.isNotEmpty && ids.value.contains(postId);

  Future<void> _load(String? uid) async {
    _uid = uid;
    ids.value = <String>{};
    if (uid == null) {
      loaded.value++;
      return;
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> saved =
          prefs.getStringList('$_prefsKeyBase$uid') ?? const [];
      if (_uid == uid && saved.isNotEmpty) ids.value = {...ids.value, ...saved};
    } catch (_) {}
    if (_uid == uid) loaded.value++;
  }

  Future<void> add(String postId) async {
    final String? uid = _uid;
    if (uid == null || postId.isEmpty || ids.value.contains(postId)) return;
    final List<String> list = [...ids.value, postId];
    final List<String> kept =
        list.length > _max ? list.sublist(list.length - _max) : list;
    ids.value = kept.toSet();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('$_prefsKeyBase$uid', kept);
    } catch (_) {}
  }
}

enum ReportTargetType { post, comment, user }

/// The reasons, as [key, label]. The keys are what the Worker expects.
const List<List<String>> kReportReasons = [
  ['sexual', 'Nudity or sexual content'],
  ['child_safety', 'Child safety (involves a minor)'],
  ['hate', 'Hate speech or harassment'],
  ['violence', 'Violence or dangerous content'],
  ['self_harm', 'Suicide, self-harm or danger to life'],
  ['spam', 'Spam or scam'],
  ['other', 'Something else'],
];

/// Shows the reason picker, then sends the report.
/// [targetId]: the post id or the user's uid. [targetPath]: for a comment
/// or reply, its full Firestore path (DocumentReference.path).
Future<void> showReportSheet(
  BuildContext context, {
  required ReportTargetType type,
  String? targetId,
  String? targetPath,
}) async {
  final String title = switch (type) {
    ReportTargetType.post => 'Why are you reporting this video?',
    ReportTargetType.comment => 'Report this comment',
    ReportTargetType.user => 'Report this account',
  };
  final String? reason = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Your report is anonymous - the person won't know it was you.",
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
          ),
          for (final List<String> r in kReportReasons)
            ListTile(
              title: Text(r[1], style: const TextStyle(color: Colors.white70)),
              trailing: const Icon(Icons.chevron_right, color: Colors.white24),
              onTap: () => Navigator.pop(sheetContext, r[0]),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (reason == null || !context.mounted) return;
  HapticFeedback.lightImpact();
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final ReportResult result = await sendReport(
    type: type,
    targetId: targetId,
    targetPath: targetPath,
    reason: reason,
  );
  if (result == ReportResult.sent &&
      type == ReportTargetType.post &&
      targetId != null) {
    ReportedPosts.instance.add(targetId);
  }
  final String noun = switch (type) {
    ReportTargetType.post => 'video',
    ReportTargetType.comment => 'comment',
    ReportTargetType.user => 'account',
  };
  final String message = switch (result) {
    ReportResult.sent => "Thanks for reporting. We'll review it.",
    ReportResult.ownContent => type == ReportTargetType.user
        ? "You can't report your own account."
        : "You can't report your own $noun.",
    ReportResult.gone => 'This $noun was already removed. Thanks!',
    ReportResult.failed =>
      'Could not send the report. Check your connection and try again.',
  };
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// What happened to a report.
enum ReportResult {
  /// The Worker received it.
  sent,

  /// It is my own post / comment / account (Worker: 400 "own content").
  ownContent,

  /// The post / comment no longer exists (Worker: {ok: true, gone: true}).
  gone,

  /// No connection, timeout, or any other Worker answer.
  failed,
}

/// Sends one report to the Worker (POST /report).
Future<ReportResult> sendReport({
  required ReportTargetType type,
  String? targetId,
  String? targetPath,
  required String reason,
}) async {
  try {
    final http.Response res = await http
        .post(
          Uri.parse('${AppConfig.workerUrl}/report'),
          headers: {
            ...await workerAuthHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'targetType': type.name,
            'targetId': targetId,
            'targetPath': targetPath,
            'reason': reason,
          }),
        )
        .timeout(const Duration(seconds: 30));
    Map<String, dynamic> body = const {};
    try {
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // Not JSON (e.g. "Unauthorized") - handled by the status code below.
    }
    if (res.statusCode == 200) {
      return body['gone'] == true ? ReportResult.gone : ReportResult.sent;
    }
    debugPrint('report: HTTP ${res.statusCode} ${res.body}');
    if (res.statusCode == 400 && body['error'] == 'own content') {
      return ReportResult.ownContent;
    }
    return ReportResult.failed;
  } catch (e) {
    debugPrint('report: failed ($e)');
    return ReportResult.failed;
  }
}

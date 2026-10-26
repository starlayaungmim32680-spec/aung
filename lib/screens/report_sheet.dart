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
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../app_config.dart';
import 'worker_auth.dart';

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
  final bool ok = await sendReport(
    type: type,
    targetId: targetId,
    targetPath: targetPath,
    reason: reason,
  );
  messenger.showSnackBar(SnackBar(
    content: Text(ok
        ? "Thanks for reporting. We'll review it."
        : 'Could not send the report. Please try again.'),
  ));
}

/// Sends one report to the Worker. True when it was received.
Future<bool> sendReport({
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
    if (res.statusCode != 200) {
      debugPrint('report: HTTP ${res.statusCode} ${res.body}');
      return false;
    }
    return true;
  } catch (e) {
    debugPrint('report: failed ($e)');
    return false;
  }
}

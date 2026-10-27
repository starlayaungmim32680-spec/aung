// Report system step 2 (27 Oct 2026): what the OWNER of a reported video
// sees, and the cover a REPORTER sees.
//
// Owner: a post the Worker hid (hiddenByReports - audience became
// 'only_me') or limited (limitedByReports - audience became 'followers',
// so it left For You / Search) shows an orange "Under review" chip instead
// of the "Only me" / "Followers & Friends" chip. Tapping it, or the "Fly"
// notification the Worker sends, opens [showReviewSheet]: what happened,
// the reason people gave (never who), and one Appeal (Worker
// POST /appeal -> Ko's review queue). Nobody is told who reported.
//
// Reporter: [ReportedCover] covers a video I reported, on my phone only,
// right away (ReportedPosts in report_sheet.dart).
import 'dart:convert';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../app_config.dart';
import 'report_sheet.dart';
import 'terms_consent.dart';
import 'worker_auth.dart';

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

/// True when reports hid or limited this post.
bool isUnderReview(Map<String, dynamic>? post) =>
    post != null &&
    (post['hiddenByReports'] == true || post['limitedByReports'] == true);

String _reasonLabel(String? key) {
  for (final List<String> r in kReportReasons) {
    if (r[0] == key) return r[1];
  }
  return 'Something else';
}

/// The orange "Under review" chip on my own video. Tappable.
class ReviewBadge extends StatelessWidget {
  final String postId;

  const ReviewBadge({super.key, required this.postId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        showReviewSheet(context, postId);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFF9F1C).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 8),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, color: Colors.white, size: 14),
            SizedBox(width: 5),
            Text(
              'Under review',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, color: Colors.white, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Explains why my video is hidden / limited, with one Appeal.
Future<void> showReviewSheet(BuildContext context, String postId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF151419),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ReviewSheet(postId: postId),
  );
}

class _ReviewSheet extends StatefulWidget {
  final String postId;

  const _ReviewSheet({required this.postId});

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _postStream =
      FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .snapshots();
  final TextEditingController _message = TextEditingController();
  final ValueNotifier<bool> _sending = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _message.dispose();
    _sending.dispose();
    super.dispose();
  }

  Future<void> _appeal() async {
    HapticFeedback.mediumImpact();
    _sending.value = true;
    bool ok = false;
    try {
      final http.Response res = await http
          .post(
            Uri.parse('${AppConfig.workerUrl}/appeal'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'postId': widget.postId,
              'message': _message.text.trim(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      ok = res.statusCode == 200;
      if (!ok) debugPrint('appeal: HTTP ${res.statusCode} ${res.body}');
    } catch (e) {
      debugPrint('appeal: failed ($e)');
    }
    if (!mounted) return;
    _sending.value = false;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not send your appeal. Please try again.'),
      ));
    }
    // On success the post's appealStatus changes and the sheet updates.
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _postStream,
          builder: (context, snap) {
            final Map<String, dynamic>? post = snap.data?.data();
            if (snap.connectionState == ConnectionState.waiting &&
                post == null) {
              return const SizedBox(
                height: 220,
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: _content(post),
            );
          },
        ),
      ),
    );
  }

  Widget _content(Map<String, dynamic>? post) {
    final bool hidden = post?['hiddenByReports'] == true;
    final bool limited = post?['limitedByReports'] == true;
    final bool appealed =
        (post?['appealStatus'] as String?)?.isNotEmpty == true;
    final String reasonKey = hidden ? 'hiddenReason' : 'limitedReason';
    final String reason = _reasonLabel(post?[reasonKey] as String?);

    final String title;
    final String body;
    if (hidden) {
      title = 'Your video is hidden';
      body = 'Our automatic check found that it may break our Community '
          'Guidelines, so only you can see it for now. It has not been '
          'deleted.';
    } else if (limited) {
      title = 'Your video is only shown to your followers';
      body = 'Some people reported it. Our automatic check did not find a '
          'problem, so it is still up - your followers and friends can watch '
          'it - but it is out of For You and Search until a person from the '
          'Fly team looks at it.';
    } else {
      title = 'Your video is not under review';
      body = 'Everything is back to normal. Thanks for your patience!';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (hidden || limited)
                    ? const Color(0xFFFF9F1C).withValues(alpha: 0.18)
                    : const Color(0xFF24D17E).withValues(alpha: 0.18),
              ),
              child: Icon(
                (hidden || limited)
                    ? Icons.shield_outlined
                    : Icons.check_circle_outline,
                color: (hidden || limited)
                    ? const Color(0xFFFF9F1C)
                    : const Color(0xFF24D17E),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(body,
            style: const TextStyle(
                color: Colors.white70, fontSize: 14, height: 1.4)),
        if (hidden || limited) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(
                  text: 'Reported for: ',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                TextSpan(
                  text: reason,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => openFlyWebPage(context, kCommunityGuidelinesUrl),
            child: const Text('Read the Community Guidelines',
                style: TextStyle(color: Color(0xFF8AB4FF))),
          ),
          const SizedBox(height: 4),
          if (appealed)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF24D17E).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                "✅ Appeal sent. A person from the Fly team will look at your "
                "video and you'll get a notification.",
                style: TextStyle(color: Colors.white, fontSize: 13.5),
              ),
            )
          else ...[
            const Text(
              'Think this is a mistake?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _message,
              maxLength: 300,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Tell us why (optional)',
                hintStyle: const TextStyle(color: Colors.white38),
                counterStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<bool>(
              valueListenable: _sending,
              builder: (context, sending, _) => GestureDetector(
                onTap: sending ? null : _appeal,
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(colors: _flyGradient),
                  ),
                  child: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white),
                        )
                      : const Text(
                          'Appeal',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Covers a video I reported (only on my phone). [onNext] skips to the
/// next video.
class ReportedCover extends StatelessWidget {
  final VoidCallback onNext;

  const ReportedCover({super.key, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          color: Colors.black.withValues(alpha: 0.72),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.85, end: 1.0),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutBack,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: _flyGradient),
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 36),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Thanks for reporting',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "You won't see this video again. We'll review it - the "
                  "person won't know it was you.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 22),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onNext();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 26, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white38),
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    child: const Text(
                      'Next video',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

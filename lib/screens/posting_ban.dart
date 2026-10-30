// Strikes, step B (30 Oct 2026): what I see while posting is paused.
//
// The Worker (POST /admin-api Remove, see cloudflare/livekit_token_worker.js)
// gives a strike each time Ko removes my video / comment. Each strike
// counts for 90 days: 1 = warning, 2 = no new videos or stories for 7
// days, 3+ or child safety = 30 days. It writes:
//   moderationStrikes/{me}          { strikes, postBanUntil, lastReason, ... }
//   moderationStrikes/{me}/items/*  { reason, createdAt, expiresAt, ... }
// firestore.rules let ONLY me read them (nobody can write). While
// postBanUntil is in the future, the Worker's /upload-video and the rules
// for posts / stories refuse - so this file just explains it nicely,
// BEFORE I spend time recording or editing:
//   - [PostingBanGate] wraps the Upload screen: a full "Posting is
//     paused" panel with a live countdown instead of the camera.
//   - [ensureCanPost] for one-tap flows (Create story): a sheet.
//   - [postingBanShortText] / [postingBanLabelIfBanned] turn a refused
//     upload into one clear sentence instead of a raw error.
// Watching, likes, comments and chat keep working.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'report_sheet.dart' show kReportReasons;
import 'terms_consent.dart' show kCommunityGuidelinesUrl, openFlyWebPage;

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

/// Same as the Worker's ladder (for the meter only).
const int kStrikeLimit = 3;
const int kStrikeDays = 90;

/// Why posting is paused, and until when.
class PostingBanInfo {
  final DateTime until;
  final int activeStrikes;
  final String lastReason;

  const PostingBanInfo({
    required this.until,
    required this.activeStrikes,
    required this.lastReason,
  });

  bool get isActive => until.isAfter(DateTime.now());
}

DocumentReference<Map<String, dynamic>>? _summaryRef() {
  final String? uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return null;
  return FirebaseFirestore.instance.collection('moderationStrikes').doc(uid);
}

int _countActive(QuerySnapshot<Map<String, dynamic>>? items) {
  if (items == null) return 0;
  final DateTime now = DateTime.now();
  return items.docs.where((d) {
    final Object? v = d.data()['expiresAt'];
    return v is Timestamp && v.toDate().isAfter(now);
  }).length;
}

PostingBanInfo? _infoFrom(
  Map<String, dynamic>? summary,
  QuerySnapshot<Map<String, dynamic>>? items,
) {
  final Object? until = summary?['postBanUntil'];
  if (until is! Timestamp) return null;
  final PostingBanInfo info = PostingBanInfo(
    until: until.toDate(),
    activeStrikes: _countActive(items),
    lastReason: (summary?['lastReason'] as String?) ?? '',
  );
  return info.isActive ? info : null;
}

/// My current posting pause, or null (also null on any read error -
/// the Worker and the rules still refuse a post if there really is one).
Future<PostingBanInfo?> currentPostingBan() async {
  final DocumentReference<Map<String, dynamic>>? ref = _summaryRef();
  if (ref == null) return null;
  try {
    final DocumentSnapshot<Map<String, dynamic>> snap =
        await ref.get(const GetOptions(source: Source.server));
    final Object? until = snap.data()?['postBanUntil'];
    if (until is! Timestamp || !until.toDate().isAfter(DateTime.now())) {
      return null;
    }
    QuerySnapshot<Map<String, dynamic>>? items;
    try {
      items = await ref.collection('items').get();
    } catch (_) {}
    return _infoFrom(snap.data(), items);
  } catch (_) {
    return null;
  }
}

/// True when I may post. Otherwise shows the "Posting is paused" sheet
/// and returns false.
Future<bool> ensureCanPost(BuildContext context) async {
  final PostingBanInfo? ban = await currentPostingBan();
  if (ban == null) return true;
  if (context.mounted) await showPostingBanSheet(context, ban);
  return false;
}

// ---------------------------------------------------------------------
// Text helpers (no intl package - plain English, phone's local time)
// ---------------------------------------------------------------------
const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun'
];

/// "Fri, 6 Nov · 9:41 PM"
String postingBanWhen(DateTime until) {
  final DateTime t = until.toLocal();
  final int h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final String mm = t.minute.toString().padLeft(2, '0');
  final String ampm = t.hour < 12 ? 'AM' : 'PM';
  return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} · $h12:$mm $ampm';
}

/// "6 days 4 hours" / "5 hours 12 minutes" / "3 minutes"
String postingBanLeft(DateTime until) {
  Duration d = until.difference(DateTime.now());
  if (d.isNegative) d = Duration.zero;
  final int days = d.inDays;
  final int hours = d.inHours % 24;
  final int minutes = d.inMinutes % 60;
  String unit(int n, String w) => '$n $w${n == 1 ? '' : 's'}';
  if (days > 0) return '${unit(days, 'day')} ${unit(hours, 'hour')}';
  if (hours > 0) return '${unit(hours, 'hour')} ${unit(minutes, 'minute')}';
  return unit(minutes < 1 ? 1 : minutes, 'minute');
}

String _reasonLabel(String key) {
  for (final List<String> r in kReportReasons) {
    if (r[0] == key) return r[1];
  }
  return 'Breaking our Community Guidelines';
}

/// One sentence for small places (the "Posting..." pill, a snackbar).
String postingBanShortText(DateTime until) =>
    "Posting is paused until ${postingBanWhen(until)} because of "
    'Community Guidelines strikes.';

/// After a refused write (permission-denied): the sentence above if a
/// posting pause is the reason, else null.
Future<String?> postingBanLabelIfBanned() async {
  final PostingBanInfo? ban = await currentPostingBan();
  return ban == null ? null : postingBanShortText(ban.until);
}

// ---------------------------------------------------------------------
// The sheet (Create story) and the full panel (Upload screen)
// ---------------------------------------------------------------------
Future<void> showPostingBanSheet(BuildContext context, PostingBanInfo ban) {
  HapticFeedback.mediumImpact();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF15121C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            _PostingBanBody(ban: ban),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: _GradientButton(
                label: 'Got it',
                onTap: () => Navigator.pop(sheetContext),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shows [child] normally, or the "Posting is paused" panel while my
/// posting pause lasts. Listens live, and lifts by itself when the time
/// is up (checked every 30 s).
class PostingBanGate extends StatefulWidget {
  final Widget child;
  const PostingBanGate({super.key, required this.child});

  @override
  State<PostingBanGate> createState() => _PostingBanGateState();
}

class _PostingBanGateState extends State<PostingBanGate> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _summarySub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _itemsSub;
  Map<String, dynamic>? _summary;
  QuerySnapshot<Map<String, dynamic>>? _items;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final DocumentReference<Map<String, dynamic>>? ref = _summaryRef();
    if (ref != null) {
      // Errors (e.g. rules not published yet) = no pause shown.
      _summarySub = ref.snapshots().listen(
            (s) => _set(() => _summary = s.data()),
            onError: (_) {},
          );
      _itemsSub = ref.collection('items').snapshots().listen(
            (s) => _set(() => _items = s),
            onError: (_) {},
          );
    }
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _set(() {}));
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  void dispose() {
    _summarySub?.cancel();
    _itemsSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PostingBanInfo? ban = _infoFrom(_summary, _items);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: ban == null
          ? KeyedSubtree(key: const ValueKey('free'), child: widget.child)
          : Scaffold(
              key: const ValueKey('paused'),
              backgroundColor: Colors.black,
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                    child: _PostingBanBody(ban: ban, large: true),
                  ),
                ),
              ),
            ),
    );
  }
}

class _PostingBanBody extends StatelessWidget {
  final PostingBanInfo ban;
  final bool large;
  const _PostingBanBody({required this.ban, this.large = false});

  @override
  Widget build(BuildContext context) {
    final int filled = ban.activeStrikes.clamp(0, kStrikeLimit);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Soft pulsing shield in the Fly gradient.
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.8, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutBack,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Container(
            width: large ? 86 : 68,
            height: large ? 86 : 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: _flyGradient),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF9C4DFF).withValues(alpha: 0.45),
                  blurRadius: 28,
                ),
              ],
            ),
            child:
                Icon(Icons.shield, color: Colors.white, size: large ? 44 : 36),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Posting is paused',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: large ? 24 : 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        ShaderMask(
          shaderCallback: (r) =>
              const LinearGradient(colors: _flyGradient).createShader(r),
          child: Text(
            '${postingBanLeft(ban.until)} left',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: large ? 28 : 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'You can post videos and stories again on\n${postingBanWhen(ban.until)}',
          textAlign: TextAlign.center,
          style:
              const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 18),
        _InfoCard(
          icon: Icons.flag,
          color: const Color(0xFFFF9F1C),
          title: 'Why',
          body: ban.lastReason.isEmpty
              ? 'Some of your posts were removed because they broke our '
                  'Community Guidelines.'
              : 'Your last removed post was for: ${_reasonLabel(ban.lastReason)}.',
        ),
        const SizedBox(height: 10),
        _InfoCard(
          icon: Icons.timelapse,
          color: const Color(0xFF3A8DFF),
          title: 'Strikes',
          bodyWidget: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (int i = 0; i < kStrikeLimit; i++)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      width: 26,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: i < filled
                            ? const LinearGradient(colors: _flyGradient)
                            : null,
                        color: i < filled ? null : Colors.white12,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    '${ban.activeStrikes} in the last $kStrikeDays days',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Each strike goes away by itself $kStrikeDays days after it was given.',
                style: TextStyle(color: Colors.white60, fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const _InfoCard(
          icon: Icons.favorite,
          color: Color(0xFF24D17E),
          title: 'You can still',
          body: 'Watch videos, like, comment, chat and call your friends.',
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => openFlyWebPage(context, kCommunityGuidelinesUrl),
          child: const Text('Read the Community Guidelines',
              style: TextStyle(color: Color(0xFF8AB4FF))),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? body;
  final Widget? bodyWidget;

  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    this.body,
    this.bodyWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                bodyWidget ??
                    Text(body ?? '',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _GradientButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(colors: _flyGradient),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}

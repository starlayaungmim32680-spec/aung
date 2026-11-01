// Strikes, step C (1 Nov 2026): "Account status" - Settings -> Account
// status (and "See account status" on the Posting is paused panel).
//
// Like TikTok's Account status page, but clearer: one look tells me
//   - how my account is doing (good standing / warning / posting paused,
//     with a live countdown),
//   - every strike that still counts: why, when it was given, the exact
//     day it goes away, and a bar showing how much of its 90 days is
//     left,
//   - past (expired) strikes, greyed out,
//   - how the ladder works (1 = warning, 2 = 7 days, 3+ = 30 days, child
//     safety = 30 days at once) - the same rules the Worker uses.
// Reads ONLY my own moderationStrikes/{me} + items (firestore.rules allow
// the owner to read them; nobody can write). Who reported me is never
// stored there, so it can never show.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'posting_ban.dart'
    show kStrikeDays, kStrikeLimit, postingBanLeft, postingBanWhen;
import 'report_sheet.dart' show kReportReasons;
import 'terms_consent.dart' show kCommunityGuidelinesUrl, openFlyWebPage;

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];
const Color _green = Color(0xFF24D17E);
const Color _orange = Color(0xFFFF9F1C);
const Color _red = Color(0xFFFF4757);

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

/// "31 Oct 2026" in phone time.
String _day(DateTime d) {
  final DateTime t = d.toLocal();
  return '${t.day} ${_months[t.month - 1]} ${t.year}';
}

String _reasonLabel(String key) {
  for (final List<String> r in kReportReasons) {
    if (r[0] == key) return r[1];
  }
  return 'Breaking our Community Guidelines';
}

/// One strike as stored by the Worker.
class _Strike {
  final String reason;
  final String kind; // 'post' | 'comment'
  final DateTime given;
  final DateTime expires;
  final bool severe;

  _Strike({
    required this.reason,
    required this.kind,
    required this.given,
    required this.expires,
    required this.severe,
  });

  bool get active => expires.isAfter(DateTime.now());

  /// 1.0 = just given, 0.0 = gone.
  double get leftFraction {
    final int total = expires.difference(given).inSeconds;
    if (total <= 0) return 0;
    final int left = expires.difference(DateTime.now()).inSeconds;
    return (left / total).clamp(0.0, 1.0);
  }

  static _Strike? from(Map<String, dynamic> d) {
    final Object? c = d['createdAt'];
    final Object? e = d['expiresAt'];
    if (c is! Timestamp || e is! Timestamp) return null;
    return _Strike(
      reason: (d['reason'] as String?) ?? '',
      kind: (d['kind'] as String?) ?? 'post',
      given: c.toDate(),
      expires: e.toDate(),
      severe: d['severe'] == true,
    );
  }
}

class AccountStatusScreen extends StatefulWidget {
  const AccountStatusScreen({super.key});

  @override
  State<AccountStatusScreen> createState() => _AccountStatusScreenState();
}

class _AccountStatusScreenState extends State<AccountStatusScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _summarySub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _itemsSub;
  Map<String, dynamic>? _summary;
  List<_Strike> _strikes = const [];
  bool _loaded = false;
  // 1 Nov 2026: a read that failed (no internet, rules) must never look
  // like "good standing" - it shows a "Couldn't load" card with Try again.
  bool _failed = false;
  bool _showPast = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _listen();
    // Keeps the countdown and the "days left" bars fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _set(() {}));
  }

  // (Re)starts the two listeners - here and from "Try again" only, never
  // inside build() (Fly stream rule).
  void _listen() {
    _summarySub?.cancel();
    _itemsSub?.cancel();
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _loaded = true;
      _failed = true;
      return;
    }
    final DocumentReference<Map<String, dynamic>> ref =
        FirebaseFirestore.instance.collection('moderationStrikes').doc(uid);
    _summarySub = ref.snapshots().listen(
          (s) => _set(() => _summary = s.data()),
          onError: (_) => _set(() {
            _loaded = true;
            _failed = true;
          }),
        );
    // includeMetadataChanges: so the server's answer arrives even when it
    // is the same (empty) list the cache already gave.
    _itemsSub =
        ref.collection('items').snapshots(includeMetadataChanges: true).listen(
      (s) {
        // A snapshot from the phone's cache while offline could be empty
        // only because nothing was downloaded yet - wait for the server.
        if (s.metadata.isFromCache && s.docs.isEmpty && !_loaded) return;
        final List<_Strike> list = s.docs
            .map((d) => _Strike.from(d.data()))
            .whereType<_Strike>()
            .toList()
          ..sort((a, b) => b.given.compareTo(a.given));
        _set(() {
          _strikes = list;
          _loaded = true;
          _failed = false;
        });
      },
      onError: (_) => _set(() {
        _loaded = true;
        _failed = true;
      }),
    );
    // Offline with nothing cached: don't spin forever.
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && !_loaded) {
        _set(() {
          _loaded = true;
          _failed = true;
        });
      }
    });
  }

  void _retry() {
    setState(() {
      _loaded = false;
      _failed = false;
    });
    _listen();
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

  DateTime? get _pauseUntil {
    final Object? v = _summary?['postBanUntil'];
    if (v is! Timestamp) return null;
    final DateTime t = v.toDate();
    return t.isAfter(DateTime.now()) ? t : null;
  }

  @override
  Widget build(BuildContext context) {
    final List<_Strike> active = _strikes.where((s) => s.active).toList();
    final List<_Strike> past = _strikes.where((s) => !s.active).toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title:
            const Text('Account status', style: TextStyle(color: Colors.white)),
      ),
      body: !_loaded
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54))
          : _failed
              ? _LoadFailed(onRetry: _retry)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _StatusHero(active: active.length, pauseUntil: _pauseUntil),
                    const SizedBox(height: 20),
                    if (active.isNotEmpty) ...[
                      const _SectionTitle('Strikes that still count'),
                      for (final _Strike s in active) _StrikeCard(strike: s),
                      const SizedBox(height: 12),
                    ],
                    if (past.isNotEmpty) ...[
                      GestureDetector(
                        onTap: () => setState(() => _showPast = !_showPast),
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          children: [
                            _SectionTitle('Past strikes (${past.length})'),
                            const Spacer(),
                            Icon(
                              _showPast
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              color: Colors.white54,
                            ),
                          ],
                        ),
                      ),
                      if (_showPast)
                        for (final _Strike s in past) _StrikeCard(strike: s),
                      const SizedBox(height: 12),
                    ],
                    const _SectionTitle('How strikes work'),
                    const _HowItWorks(),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: () =>
                            openFlyWebPage(context, kCommunityGuidelinesUrl),
                        child: const Text('Read the Community Guidelines',
                            style: TextStyle(color: Color(0xFF8AB4FF))),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// Shown when the status couldn't be read - never a false "good standing".
class _LoadFailed extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadFailed({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📡', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 14),
            const Text("Couldn't load your account status",
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 14)),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: const LinearGradient(colors: _flyGradient),
                ),
                child: const Text('Try again',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The big card at the top: good standing / warning / posting paused.
class _StatusHero extends StatelessWidget {
  final int active;
  final DateTime? pauseUntil;

  const _StatusHero({required this.active, required this.pauseUntil});

  @override
  Widget build(BuildContext context) {
    final bool paused = pauseUntil != null;
    final Color tone = paused
        ? _red
        : active == 0
            ? _green
            : _orange;
    final String emoji = paused
        ? '⏸️'
        : active == 0
            ? '🐦'
            : '⚠️';
    final String title = paused
        ? 'Posting is paused'
        : active == 0
            ? 'Your account is in good standing'
            : 'Your account has a warning';
    final String body = paused
        ? 'You can post videos and stories again on ${postingBanWhen(pauseUntil!)}.'
        : active == 0
            ? 'No strikes - thanks for keeping Fly a kind place! 🎉'
            : active == 1
                ? 'One more strike within $kStrikeDays days means 7 days without posting.'
                : 'Another strike within $kStrikeDays days means 30 days without posting.';
    final int filled = active.clamp(0, kStrikeLimit);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tone.withValues(alpha: 0.28),
            const Color(0xFF17121F),
          ],
        ),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.7, end: 1),
            duration: const Duration(milliseconds: 560),
            curve: Curves.easeOutBack,
            builder: (context, s, child) =>
                Transform.scale(scale: s, child: child),
            child: Container(
              width: 76,
              height: 76,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tone.withValues(alpha: 0.18),
                border:
                    Border.all(color: tone.withValues(alpha: 0.6), width: 2),
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 36)),
            ),
          ),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
          if (paused) ...[
            const SizedBox(height: 8),
            ShaderMask(
              shaderCallback: (r) =>
                  const LinearGradient(colors: _flyGradient).createShader(r),
              child: Text('${postingBanLeft(pauseUntil!)} left',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900)),
            ),
          ],
          const SizedBox(height: 8),
          Text(body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14, height: 1.4)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < kStrikeLimit; i++)
                AnimatedContainer(
                  duration: Duration(milliseconds: 300 + i * 120),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 44,
                  height: 9,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    gradient: i < filled
                        ? const LinearGradient(colors: _flyGradient)
                        : null,
                    color: i < filled ? null : Colors.white12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$active of $kStrikeLimit strikes in the last $kStrikeDays days',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

class _StrikeCard extends StatelessWidget {
  final _Strike strike;
  const _StrikeCard({required this.strike});

  @override
  Widget build(BuildContext context) {
    final bool active = strike.active;
    final int daysLeft =
        active ? strike.expires.difference(DateTime.now()).inDays + 1 : 0;
    final Color tone = strike.severe ? _red : _orange;
    return Opacity(
      opacity: active ? 1 : 0.5,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                      strike.kind == 'comment'
                          ? Icons.mode_comment_outlined
                          : Icons.videocam_outlined,
                      color: tone,
                      size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_reasonLabel(strike.reason),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        '${strike.kind == 'comment' ? 'Comment' : 'Video'} removed · ${_day(strike.given)}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (active ? tone : Colors.white24)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    active
                        ? '$daysLeft day${daysLeft == 1 ? '' : 's'} left'
                        : 'Expired',
                    style: TextStyle(
                        color: active ? tone : Colors.white54,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (active) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: strike.leftFraction,
                  minHeight: 6,
                  backgroundColor: Colors.white10,
                  valueColor: AlwaysStoppedAnimation<Color>(tone),
                ),
              ),
              const SizedBox(height: 6),
              Text('Goes away on ${_day(strike.expires)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            if (strike.severe) ...[
              const SizedBox(height: 6),
              const Text(
                'Child safety - posting was paused for 30 days at once.',
                style: TextStyle(color: _red, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  Widget _row(String emoji, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Text(emoji, style: const TextStyle(fontSize: 18)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 13, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          _row('📋', 'A person checks first',
              'Reports alone never remove anything. Strikes only come when the Fly team removes something that breaks our Community Guidelines.'),
          _row('⚠️', '1 strike = a warning', 'Nothing is limited yet.'),
          _row('⏸️', '2 strikes = 7 days',
              'No new videos or stories for 7 days.'),
          _row('⛔', '3 strikes = 30 days',
              'No new videos or stories for 30 days, and the team looks at the account.'),
          _row('🛡️', 'Child safety = 30 days at once',
              'Anything that puts children at risk pauses posting right away.'),
          _row('⏳', 'Strikes go away',
              'Each strike stops counting $kStrikeDays days after it was given. Watching, likes, comments and chat always keep working.'),
        ],
      ),
    );
  }
}

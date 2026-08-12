// Cosmetic-only virtual gifting for live streams.
//
// IMPORTANT: this is deliberately NOT a real-money system. Coins are only
// ever earned for free (daily login, watching videos, sharing, following),
// never purchased, and can never be cashed out by a streamer. That keeps
// this feature free of payment-processor fees, App/Play Store commission,
// money-transmitter licensing, and fraud/chargeback risk - all of which a
// real cash-in/cash-out gifting system would require. If real-money
// gifting is wanted later, that's a separate, much bigger project needing
// legal advice first.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class GiftItem {
  final String id;
  final String emoji;
  final String name;
  final int cost;
  const GiftItem({
    required this.id,
    required this.emoji,
    required this.name,
    required this.cost,
  });
}

const List<GiftItem> kGiftCatalog = [
  GiftItem(id: 'heart', emoji: '❤️', name: 'Heart', cost: 1),
  GiftItem(id: 'rose', emoji: '🌹', name: 'Rose', cost: 5),
  GiftItem(id: 'star', emoji: '⭐', name: 'Star', cost: 10),
  GiftItem(id: 'fire', emoji: '🔥', name: 'Fire', cost: 20),
  GiftItem(id: 'crown', emoji: '👑', name: 'Crown', cost: 50),
  GiftItem(id: 'rocket', emoji: '🚀', name: 'Rocket', cost: 100),
];

class CoinService {
  CoinService._();
  static final CoinService instance = CoinService._();

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid);

  String get _todayKey {
    final DateTime now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  // Call once per app session (e.g. when MainNavigationScreen first
  // loads) - awards a small bonus, once per calendar day.
  Future<void> awardDailyLogin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = _userDoc(user.uid);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(doc);
        final String? lastReward =
            snap.data()?['lastLoginRewardDate'] as String?;
        if (lastReward == _todayKey) return; // already rewarded today
        tx.set(
          doc,
          {'coins': FieldValue.increment(10), 'lastLoginRewardDate': _todayKey},
          SetOptions(merge: true),
        );
      });
    } catch (_) {
      // Non-critical - never block app startup over this.
    }
  }

  // Reward for sharing a video. Capped per day so re-sharing the same
  // video over and over isn't a way to farm unlimited coins.
  Future<void> awardShare() =>
      _awardCapped(reward: 2, counterField: 'shareRewardCount', maxPerDay: 10);

  // Reward for watching a video to completion. Capped per day.
  Future<void> awardWatchComplete() =>
      _awardCapped(reward: 1, counterField: 'watchRewardCount', maxPerDay: 20);

  // Reward for following someone, but only the first time - unfollowing
  // and re-following the same person doesn't pay out again.
  Future<void> awardFollow(String followedUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final markerDoc = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('followRewards')
        .doc(followedUid);
    try {
      final existing = await markerDoc.get();
      if (existing.exists) return;
      await markerDoc.set({'createdAt': FieldValue.serverTimestamp()});
      await _userDoc(user.uid)
          .set({'coins': FieldValue.increment(3)}, SetOptions(merge: true));
    } catch (_) {
      // Non-critical.
    }
  }

  Future<void> _awardCapped({
    required int reward,
    required String counterField,
    required int maxPerDay,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = _userDoc(user.uid);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(doc);
        final data = snap.data();
        final String? countedDate = data?['${counterField}Date'] as String?;
        final int countToday =
            countedDate == _todayKey ? (data?[counterField] as int? ?? 0) : 0;
        if (countToday >= maxPerDay) return; // hit today's cap
        tx.set(
          doc,
          {
            'coins': FieldValue.increment(reward),
            counterField: countToday + 1,
            '${counterField}Date': _todayKey,
          },
          SetOptions(merge: true),
        );
      });
    } catch (_) {
      // Non-critical.
    }
  }

  // Spends [gift.cost] coins sending [gift] to [hostId]'s live stream.
  // Returns false (and spends nothing) if the balance is too low.
  Future<bool> sendGift(
      {required String hostId, required GiftItem gift}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final senderDoc = _userDoc(user.uid);

    bool deducted;
    try {
      deducted = await firestore.runTransaction<bool>((tx) async {
        final snap = await tx.get(senderDoc);
        final int balance = (snap.data()?['coins'] as num?)?.toInt() ?? 0;
        if (balance < gift.cost) return false;
        tx.set(senderDoc, {'coins': FieldValue.increment(-gift.cost)},
            SetOptions(merge: true));
        return true;
      });
    } catch (_) {
      return false;
    }
    if (!deducted) return false;

    // From here on, the coins are already spent - everything below is
    // best-effort (drives the flying-gift animation + leaderboard, but a
    // failure here shouldn't look like a lost charge, since it isn't
    // one).
    String senderName = 'Someone';
    try {
      final myProfile = await firestore.collection('users').doc(user.uid).get();
      final String? n = myProfile.data()?['displayName'] as String?;
      if (n != null && n.trim().isNotEmpty) senderName = n;
    } catch (_) {
      // Keep fallback name.
    }

    try {
      await firestore
          .collection('liveStreams')
          .doc(hostId)
          .collection('gifts')
          .add({
        'giftId': gift.id,
        'emoji': gift.emoji,
        'giftName': gift.name,
        'coins': gift.cost,
        'senderId': user.uid,
        'senderName': senderName,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await firestore
          .collection('users')
          .doc(hostId)
          .collection('supporters')
          .doc(user.uid)
          .set({
        'name': senderName,
        'totalCoins': FieldValue.increment(gift.cost),
        'lastGiftAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Best-effort, as noted above.
    }

    return true;
  }
}

// Small pill showing the signed-in user's live coin balance. Drop it
// anywhere - it keeps itself up to date via a Firestore stream.
class CoinBalanceBadge extends StatelessWidget {
  const CoinBalanceBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snap) {
        final int coins = (snap.data?.data()?['coins'] as num?)?.toInt() ?? 0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🪙', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Text('$coins',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        );
      },
    );
  }
}

// Bottom sheet for picking and sending a gift on [hostId]'s live stream.
class GiftPickerSheet extends StatefulWidget {
  final String hostId;
  const GiftPickerSheet({super.key, required this.hostId});

  @override
  State<GiftPickerSheet> createState() => _GiftPickerSheetState();
}

class _GiftPickerSheetState extends State<GiftPickerSheet> {
  bool _sending = false;

  Future<void> _send(GiftItem gift) async {
    if (_sending) return;
    setState(() => _sending = true);
    final bool ok =
        await CoinService.instance.sendGift(hostId: widget.hostId, gift: gift);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      return;
    }
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Not enough coins - watch videos, share, and log in daily to earn more'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Send a gift',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                CoinBalanceBadge(),
              ],
            ),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95,
              children: kGiftCatalog.map((gift) {
                return GestureDetector(
                  onTap: _sending ? null : () => _send(gift),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(gift.emoji, style: const TextStyle(fontSize: 28)),
                        const SizedBox(height: 4),
                        Text(gift.name,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('🪙', style: TextStyle(fontSize: 10)),
                            const SizedBox(width: 2),
                            Text('${gift.cost}',
                                style: const TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

// Leaderboard of everyone who has sent [hostId] gifts, most coins first.
class TopSupportersSheet extends StatelessWidget {
  final String hostId;
  const TopSupportersSheet({super.key, required this.hostId});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Top supporters',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const SizedBox(height: 12),
            SizedBox(
              height: 320,
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(hostId)
                    .collection('supporters')
                    .orderBy('totalCoins', descending: true)
                    .limit(20)
                    .snapshots(),
                builder: (context, snap) {
                  final docs = snap.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text('No supporters yet',
                          style: TextStyle(color: Colors.grey)),
                    );
                  }
                  return ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data = docs[index].data() as Map<String, dynamic>;
                      final int rank = index + 1;
                      final String medal = rank == 1
                          ? '🥇'
                          : rank == 2
                              ? '🥈'
                              : rank == 3
                                  ? '🥉'
                                  : '#$rank';
                      return ListTile(
                        leading:
                            Text(medal, style: const TextStyle(fontSize: 16)),
                        title: Text(data['name'] as String? ?? 'Someone',
                            style: const TextStyle(color: Colors.white)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🪙', style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 4),
                            Text('${data['totalCoins'] ?? 0}',
                                style: const TextStyle(
                                    color: Colors.amberAccent,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
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

class LiveFlyingGift {
  final int id;
  final String emoji;
  final String giftName;
  final String senderName;

  LiveFlyingGift({
    required this.id,
    required this.emoji,
    required this.giftName,
    required this.senderName,
  });
}

// A gift announcement banner that slides in, holds, then fades out -
// bigger and more attention-grabbing than the plain flying-emoji
// reactions, since a gift represents someone actually spending coins.
class LiveFlyingGiftWidget extends StatefulWidget {
  final LiveFlyingGift data;
  final VoidCallback onComplete;

  const LiveFlyingGiftWidget(
      {super.key, required this.data, required this.onComplete});

  @override
  State<LiveFlyingGiftWidget> createState() => _LiveFlyingGiftWidgetState();
}

class _LiveFlyingGiftWidgetState extends State<LiveFlyingGiftWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600));
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onComplete();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value;
        double slideIn;
        double opacity;
        if (t < 0.15) {
          slideIn = (1 - t / 0.15) * 60;
          opacity = t / 0.15;
        } else if (t < 0.75) {
          slideIn = 0;
          opacity = 1.0;
        } else {
          slideIn = 0;
          opacity = 1.0 - (t - 0.75) / 0.25;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(slideIn, 0), child: child),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFFFFD54F), Color(0xFFFF6F00)]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.orange.withOpacity(0.6), blurRadius: 10),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.data.emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.data.senderName,
                    style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
                Text('sent ${widget.data.giftName}',
                    style:
                        const TextStyle(color: Colors.black87, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

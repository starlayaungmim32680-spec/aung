// A home for everything coin/gift related: the user's current balance,
// how they can earn more (all free - see gifting.dart's header comment),
// and a running history of gifts they've received while live streaming.
//
// The "Withdraw" section is deliberately disabled for now - see
// gifting.dart: cashing out to real money is a bigger project (payment
// gateway, possibly money-transmitter licensing) that's intentionally
// out of scope until there's a real plan for it. It's built into this
// screen now, greyed out, so turning it on later is just enabling a
// button - the earning/balance/history side doesn't need to change.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'gifting.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Wallet', style: TextStyle(color: Colors.white)),
      ),
      body: user == null
          ? const Center(
              child: Text('Sign in to see your wallet',
                  style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _BalanceCard(uid: user.uid),
                const SizedBox(height: 20),
                _HowToEarnCard(),
                const SizedBox(height: 20),
                _WithdrawCard(),
                const SizedBox(height: 20),
                const Text('Gifts received',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  "From your live streams - doesn't include coins you've "
                  'earned elsewhere.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 10),
                _GiftsReceivedList(uid: user.uid),
              ],
            ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final String uid;
  const _BalanceCard({required this.uid});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2A2A), Color(0xFF141414)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream:
            FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, snap) {
          final int coins = (snap.data?.data()?['coins'] as num?)?.toInt() ?? 0;
          return Column(
            children: [
              const Text('Your balance',
                  style: TextStyle(color: Colors.white60, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('🪙', style: TextStyle(fontSize: 28)),
                  const SizedBox(width: 8),
                  Text('$coins',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HowToEarnCard extends StatelessWidget {
  const _HowToEarnCard();

  @override
  Widget build(BuildContext context) {
    const rows = [
      ('📅', 'Log in each day', '+10'),
      ('▶️', 'Watch a video to the end', '+1 (up to 20/day)'),
      ('🔁', 'Share a video to Fly', '+2 (up to 10/day)'),
      ('➕', 'Follow someone new', '+3 (once each)'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How to earn coins',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Text(r.$1, style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(r.$2,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                    ),
                    Text(r.$3,
                        style: const TextStyle(
                            color: Colors.amberAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class _WithdrawCard extends StatelessWidget {
  const _WithdrawCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  color: Colors.white38, size: 18),
              SizedBox(width: 8),
              Text('Withdraw to cash',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "Not available yet - coins can't be exchanged for real money "
            'right now. This is planned for a future update.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: null, // disabled on purpose - see file header
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              child: const Text('Coming soon',
                  style: TextStyle(color: Colors.white38)),
            ),
          ),
        ],
      ),
    );
  }
}

class _GiftsReceivedList extends StatelessWidget {
  final String uid;
  const _GiftsReceivedList({required this.uid});

  @override
  Widget build(BuildContext context) {
    // Gifts a host has ever received live under their own liveStreams
    // doc (doc id == host uid, reused across every live session they've
    // run), so this naturally covers gifts from every stream, not just
    // the most recent one.
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('liveStreams')
          .doc(uid)
          .collection('gifts')
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                "No gifts yet - they'll show up here once you go live "
                'and someone sends one.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final Timestamp? ts = data['createdAt'] as Timestamp?;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text(data['emoji'] as String? ?? '🎁',
                      style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(data['senderName'] as String? ?? 'Someone',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                        Text(
                          'sent ${data['giftName'] ?? 'a gift'}'
                          '${ts != null ? ' · ${_timeAgo(ts.toDate())}' : ''}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      const Text('🪙', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 3),
                      Text('${data['coins'] ?? 0}',
                          style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  String _timeAgo(DateTime time) {
    final Duration diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

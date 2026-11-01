// Permanent ban, step B2 (1 Nov 2026) - Child Safety Standards.
//
// When Ko removes something for child safety (and ticks "this really
// involves a minor" on the review page), the Worker closes the account
// FOR GOOD (cloudflare/livekit_token_worker.js, closeAccountForGood):
//   - moderationStrikes/{uid}.accountBanned = true (+ bannedAt,
//     bannedReason) - only the owner can read it, nobody can write it,
//   - the Firebase login is disabled and the sessions revoked, so Firebase
//     signs the app out within the hour and the person can't sign in again,
//   - their other videos are hidden, stories deleted, out of Search,
//   - users/{uid}.accountClosed = true (so a profile can say "closed").
// This file is what the APP shows for that:
//   - [AccountClosedGate] wraps the signed-in app (main.dart): as soon as
//     accountBanned is true it closes every open screen and shows
//     [AccountClosedScreen] - no waiting for the hour.
//   - [showAccountClosedDialog] for the login screen ("user-disabled").
//   - [isAccountClosed] for a profile someone else opens.
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'terms_consent.dart' show kChildSafetyUrl, openFlyWebPage;
import 'login_screen.dart';

/// Where people can write about a closed account.
const String kFlySupportEmail = 'chakaboycom@gmail.com';

const Color _red = Color(0xFFFF4757);

/// A profile's users/{uid} doc says the account was closed.
bool isAccountClosed(Map<String, dynamic>? userDoc) =>
    userDoc?['accountClosed'] == true;

/// Shows [child] (the signed-in app), or [AccountClosedScreen] once my
/// account is closed. Give it a key per uid (main.dart) so a new sign-in
/// starts a fresh listener.
class AccountClosedGate extends StatefulWidget {
  final Widget child;
  const AccountClosedGate({super.key, required this.child});

  @override
  State<AccountClosedGate> createState() => _AccountClosedGateState();
}

class _AccountClosedGateState extends State<AccountClosedGate> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // Errors (no internet, already signed out) = keep the app as it is;
    // the disabled login still signs the phone out.
    _sub = FirebaseFirestore.instance
        .collection('moderationStrikes')
        .doc(uid)
        .snapshots()
        .listen((s) {
      final bool closed = s.data()?['accountBanned'] == true;
      if (closed == _closed || !mounted) return;
      if (closed) {
        // Close every screen opened on top (a video, a chat...), so the
        // closed screen is what the person sees.
        Navigator.of(context, rootNavigator: true)
            .popUntil((route) => route.isFirst);
      }
      setState(() => _closed = closed);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _closed
          ? const AccountClosedScreen(key: ValueKey('closed'))
          : KeyedSubtree(key: const ValueKey('open'), child: widget.child),
    );
  }
}

/// Full screen, can't be left with Back: read why, contact, sign out.
class AccountClosedScreen extends StatelessWidget {
  const AccountClosedScreen({super.key});

  Future<void> _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(26, 24, 26, 32),
              child: _ClosedBody(
                actions: [
                  _Button(
                    label: 'Read the Child Safety Standards',
                    filled: true,
                    onTap: () => openFlyWebPage(context, kChildSafetyUrl),
                  ),
                  const SizedBox(height: 10),
                  _Button(
                    label: 'Sign out',
                    onTap: () => _signOut(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Login screen: Firebase said "user-disabled".
Future<void> showAccountClosedDialog(BuildContext context) {
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
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
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
            _ClosedBody(
              compact: true,
              actions: [
                _Button(
                  label: 'Read the Child Safety Standards',
                  filled: true,
                  onTap: () => openFlyWebPage(sheetContext, kChildSafetyUrl),
                ),
                const SizedBox(height: 10),
                _Button(
                  label: 'OK',
                  onTap: () => Navigator.pop(sheetContext),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ClosedBody extends StatelessWidget {
  final List<Widget> actions;
  final bool compact;
  const _ClosedBody({required this.actions, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.8, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutBack,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Container(
            width: compact ? 68 : 86,
            height: compact ? 68 : 86,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _red.withValues(alpha: 0.16),
              border: Border.all(color: _red.withValues(alpha: 0.55), width: 2),
              boxShadow: [
                BoxShadow(color: _red.withValues(alpha: 0.35), blurRadius: 28),
              ],
            ),
            child: Icon(Icons.block, color: _red, size: compact ? 36 : 44),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'This account has been closed',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 20 : 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Content on this account broke our Child Safety Standards, so '
          'the account was permanently closed. It can no longer be used '
          'to sign in, post, comment or chat.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 14.5, height: 1.45),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Think this is a mistake?',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Email us and a person from the Fly team will look at it:',
                style:
                    TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(
                      const ClipboardData(text: kFlySupportEmail));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Email address copied')),
                  );
                },
                child: Row(
                  children: const [
                    Flexible(
                      child: Text(kFlySupportEmail,
                          style: TextStyle(
                              color: Color(0xFF8AB4FF),
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                    ),
                    SizedBox(width: 8),
                    Icon(Icons.copy, color: Colors.white38, size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ...actions,
      ],
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool filled;
  const _Button(
      {required this.label, required this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: filled
              ? const LinearGradient(colors: [
                  Color(0xFFFF4B6E),
                  Color(0xFF9C4DFF),
                  Color(0xFF3A8DFF),
                ])
              : null,
          color: filled ? null : Colors.white.withValues(alpha: 0.08),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}

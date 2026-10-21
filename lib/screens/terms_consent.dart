// Terms of Use consent (22 Oct 2026).
//
// Google Play requires apps with user content to show their posting rules
// and get the person's agreement before they use it - and this step can't
// be skipped. Fly's rules live on the Worker:
//   https://livekit-token-worker.chakaboycom.workers.dev/terms
//   (Terms of Use + Community Guidelines; /privacy is the Privacy Policy).
//
//   - New accounts tick "I agree" on the Sign up screen (signup_screen.dart),
//     which saves termsVersion / termsAcceptedAt on users/{uid}.
//   - Everyone else (accounts made before this, or after kTermsVersion is
//     raised) sees [TermsConsentScreen] once, right after opening Fly
//     (MainNavigationScreen -> _maybeShowOnboardingOnce). It can't be
//     closed with Back: "I agree" or "Log out".
//
// Also: accepting removes the old `dateOfBirth` field that early sign-ups
// saved by mistake - the Privacy Policy says the birth date is NOT saved.
//
// Raise kTermsVersion (and the "Version" on the web page) only when the
// rules change in a way people must agree to again.
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';

const int kTermsVersion = 1;

// The public pages are the same for Fly and Fly Dev, so both open prod.
const String kFlyWebBase =
    'https://livekit-token-worker.chakaboycom.workers.dev';
const String kTermsUrl = '$kFlyWebBase/terms';
const String kCommunityGuidelinesUrl =
    '$kFlyWebBase/terms#community-guidelines';
const String kPrivacyUrl = '$kFlyWebBase/privacy';

/// Opens one of Fly's public pages in the browser.
Future<void> openFlyWebPage(BuildContext context, String url) async {
  final bool ok = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Couldn't open the page. Visit $url")),
    );
  }
}

/// The fields saved on users/{uid} when someone agrees.
Map<String, dynamic> termsAcceptedFields() => {
      'termsVersion': kTermsVersion,
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      // Never meant to be stored (see the Privacy Policy).
      'dateOfBirth': FieldValue.delete(),
    };

class TermsConsent {
  TermsConsent._();

  /// Shows the consent screen if the signed-in person hasn't agreed to the
  /// current Terms yet. Returns false if they logged out instead.
  /// If their profile can't be read (offline), it simply tries again next
  /// time Fly opens.
  static Future<bool> ensureAccepted(BuildContext context) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return true;
    int accepted = 0;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      accepted = (doc.data()?['termsVersion'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return true;
    }
    if (accepted >= kTermsVersion || !context.mounted) return true;

    final bool? agreed = await Navigator.of(context).push<bool>(
      PageRouteBuilder<bool>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) => const TermsConsentScreen(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
            child: child,
          ),
        ),
      ),
    );
    return agreed == true;
  }
}

class TermsConsentScreen extends StatefulWidget {
  const TermsConsentScreen({super.key});

  @override
  State<TermsConsentScreen> createState() => _TermsConsentScreenState();
}

class _TermsConsentScreenState extends State<TermsConsentScreen> {
  // A ValueNotifier so only the button rebuilds while saving.
  final ValueNotifier<bool> _saving = ValueNotifier<bool>(false);

  static const List<Color> _flyGradient = [
    Color(0xFFFF4B6E),
    Color(0xFF9C4DFF),
    Color(0xFF3A8DFF),
  ];

  @override
  void dispose() {
    _saving.dispose();
    super.dispose();
  }

  Future<void> _agree() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    HapticFeedback.mediumImpact();
    _saving.value = true;
    try {
      // Not awaited past the local write: with no connection Firestore
      // queues it and syncs later, so nobody gets stuck here.
      FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(termsAcceptedFields(), SetOptions(merge: true))
          .catchError((_) {});
    } finally {
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  Future<void> _logOut() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Widget _rule(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkChip(String label, String url) {
    return ActionChip(
      onPressed: () => openFlyWebPage(context, url),
      backgroundColor: Colors.white.withValues(alpha: 0.08),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      shape: const StadiumBorder(),
      avatar: const Icon(Icons.open_in_new_rounded,
          size: 16, color: Colors.white70),
      label: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF07060B),
        body: Stack(
          children: [
            // Soft Fly-gradient glow behind the glass card.
            Positioned(
              top: -120,
              left: -80,
              child: _glow(const Color(0xFFFF4B6E)),
            ),
            Positioned(
              top: 120,
              right: -120,
              child: _glow(const Color(0xFF9C4DFF)),
            ),
            Positioned(
              bottom: -140,
              left: 40,
              child: _glow(const Color(0xFF3A8DFF)),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ShaderMask(
                              shaderCallback: (r) =>
                                  const LinearGradient(colors: _flyGradient)
                                      .createShader(r),
                              child: const Text(
                                'Fly',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Before you fly 🕊️',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Fly is for everyone, everywhere. To keep it '
                              'fun and safe, please agree to our rules.',
                              style: TextStyle(
                                  color: Colors.white60, fontSize: 13.5),
                            ),
                            const SizedBox(height: 14),
                            _rule('💜',
                                'Be kind - no hate, bullying, threats or slurs.'),
                            _rule('🔞',
                                'No nudity or sexual content. Zero tolerance for anything harming children.'),
                            _rule('🚫',
                                'No scams, spam, illegal goods or pretending to be someone else.'),
                            _rule('🎵',
                                'Only post music and videos you have the rights to.'),
                            _rule('🛡️',
                                'Posts and comments are checked automatically, and rule breaks can be removed.'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                _linkChip('Terms of Use', kTermsUrl),
                                _linkChip('Community Guidelines',
                                    kCommunityGuidelinesUrl),
                                _linkChip('Privacy Policy', kPrivacyUrl),
                              ],
                            ),
                            const SizedBox(height: 18),
                            ValueListenableBuilder<bool>(
                              valueListenable: _saving,
                              builder: (context, saving, _) => GestureDetector(
                                onTap: saving ? null : _agree,
                                child: Container(
                                  height: 52,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    gradient: const LinearGradient(
                                        colors: _flyGradient),
                                  ),
                                  child: saving
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.4,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          'I agree',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Center(
                              child: TextButton(
                                onPressed: _logOut,
                                child: const Text(
                                  "I don't agree - log out",
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glow(Color color) {
    return Container(
      width: 320,
      height: 320,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.35), Colors.transparent],
        ),
      ),
    );
  }
}

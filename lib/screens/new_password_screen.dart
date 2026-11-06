// Password reset inside Fly (6 Nov 2026) - Ko: "tap the link in Gmail
// and land right where I type the new password".
//
// The reset email's link is Firebase's own action page
// https://<project>.firebaseapp.com/__/auth/action?mode=resetPassword&
// oobCode=... (the custom action URL can't be set on these projects:
// EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED). On a phone with Fly it is an Android
// App Link (AndroidManifest.xml + /.well-known/assetlinks.json on Firebase
// Hosting, firebase_hosting/), so Android opens Fly instead of the
// browser; MainActivity.kt passes it here over "fly/links":
//   - cold start: [AuthLinks.init] asks "takeAuthLink" once,
//   - Fly already running: MainActivity calls "onAuthLink".
// [NewPasswordScreen] checks the one-time code (verifyPasswordResetCode ->
// the account's email), takes the new password twice, saves it
// (confirmPasswordReset) and signs the person straight in.
// Without the app (computer, browser) the same link shows Firebase's own
// reset page. Each flavor's links come from its own Firebase project host,
// so a dev link only ever opens Fly Dev.
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'password_reset.dart' show sendPasswordResetWithFeedback;

class AuthLinks {
  AuthLinks._();

  static const MethodChannel _channel = MethodChannel('fly/links');
  static GlobalKey<NavigatorState>? _navigatorKey;

  /// Call once after runApp (main.dart).
  static void init(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAuthLink' && call.arguments is String) {
        _open(call.arguments as String);
      }
      return null;
    });
    _takeInitial();
  }

  static Future<void> _takeInitial() async {
    try {
      final String? link = await _channel.invokeMethod<String>('takeAuthLink');
      if (link != null) _open(link);
    } catch (_) {}
  }

  static void _open(String link, [int tries = 0]) {
    final Uri? uri = Uri.tryParse(link);
    if (uri == null) return;
    final String mode = uri.queryParameters['mode'] ?? '';
    final String code = uri.queryParameters['oobCode'] ?? '';
    if (mode != 'resetPassword' || code.isEmpty) return;
    final NavigatorState? nav = _navigatorKey?.currentState;
    if (nav == null) {
      // Cold start: the first screen isn't there yet - try again shortly.
      if (tries < 40) {
        Timer(const Duration(milliseconds: 150), () => _open(link, tries + 1));
      }
      return;
    }
    nav.push(MaterialPageRoute(
      builder: (_) => NewPasswordScreen(code: code),
    ));
  }
}

class NewPasswordScreen extends StatefulWidget {
  final String code;
  const NewPasswordScreen({super.key, required this.code});

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

enum _Stage { checking, form, saving, done, expired, failed }

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  static const List<Color> _gradient = [
    Color(0xFFFF4B6E),
    Color(0xFF9C4DFF),
    Color(0xFF3A8DFF),
  ];

  final TextEditingController _p1 = TextEditingController();
  final TextEditingController _p2 = TextEditingController();
  _Stage _stage = _Stage.checking;
  String _email = '';
  String _error = '';
  bool _hide1 = true;
  bool _hide2 = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final String email =
          await FirebaseAuth.instance.verifyPasswordResetCode(widget.code);
      if (!mounted) return;
      setState(() {
        _email = email;
        _stage = _Stage.form;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'expired-action-code' ||
            e.code == 'invalid-action-code') {
          _stage = _Stage.expired;
        } else {
          _stage = _Stage.failed;
          _error = e.code == 'network-request-failed'
              ? 'No connection. Check your internet and open the link again.'
              : 'Something went wrong. Please open the link again. (${e.code})';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'Something went wrong. Please open the link again.';
        });
      }
    }
  }

  Future<void> _save() async {
    final String p1 = _p1.text;
    if (p1.length < 6) {
      setState(() => _error = 'Please use at least 6 characters.');
      return;
    }
    if (p1 != _p2.text) {
      setState(() => _error = "The two passwords don't match.");
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _error = '';
      _stage = _Stage.saving;
    });
    try {
      await FirebaseAuth.instance
          .confirmPasswordReset(code: widget.code, newPassword: p1);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'expired-action-code' ||
            e.code == 'invalid-action-code') {
          _stage = _Stage.expired;
        } else {
          _stage = _Stage.form;
          _error = switch (e.code) {
            'weak-password' => 'Please use a stronger password.',
            'network-request-failed' => 'No connection - please try again.',
            'user-disabled' => 'This account has been closed.',
            _ => 'Something went wrong - please try again. (${e.code})',
          };
        }
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.form;
        _error = 'Something went wrong - please try again.';
      });
      return;
    }

    // Saved. Now sign straight in with it (someone else signed in on this
    // phone is signed out first).
    HapticFeedback.mediumImpact();
    bool signedIn = false;
    try {
      final User? current = FirebaseAuth.instance.currentUser;
      if (current != null &&
          (current.email ?? '').toLowerCase() != _email.toLowerCase()) {
        await FirebaseAuth.instance.signOut();
      }
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: _email, password: p1);
      signedIn = true;
    } catch (_) {}
    if (!mounted) return;
    if (signedIn) {
      // Back to the first screen - it's Home now that we're signed in.
      final ScaffoldMessengerState? messenger =
          ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).popUntil((route) => route.isFirst);
      messenger?.showSnackBar(
          const SnackBar(content: Text('Password changed - welcome back!')));
      return;
    }
    setState(() => _stage = _Stage.done);
  }

  Future<void> _askNewLink() async {
    if (_email.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    await sendPasswordResetWithFeedback(context, _email);
  }

  InputDecoration _field(String hint, bool hidden, VoidCallback toggle) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF9C4DFF)),
      ),
      suffixIcon: IconButton(
        icon: Icon(hidden ? Icons.visibility_off : Icons.visibility,
            color: Colors.white54),
        onPressed: toggle,
      ),
    );
  }

  Widget _button(String label, VoidCallback? onTap, {bool filled = true}) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: filled ? const LinearGradient(colors: _gradient) : null,
            color: filled ? null : Colors.white.withValues(alpha: 0.08),
          ),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, List<Color> colors) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: colors),
        boxShadow: [
          BoxShadow(color: colors.last.withValues(alpha: 0.4), blurRadius: 26),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 40),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.checking:
        return const Padding(
          padding: EdgeInsets.only(top: 120),
          child: Center(
              child: CircularProgressIndicator(color: Color(0xFF9C4DFF))),
        );
      case _Stage.form:
      case _Stage.saving:
        final bool busy = _stage == _Stage.saving;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: _icon(Icons.lock_reset, _gradient)),
            const SizedBox(height: 20),
            const Text('Set a new password',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('for $_email',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60, fontSize: 14)),
            const SizedBox(height: 26),
            TextField(
              controller: _p1,
              obscureText: _hide1,
              enabled: !busy,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: _field('New password', _hide1,
                  () => setState(() => _hide1 = !_hide1)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _p2,
              obscureText: _hide2,
              enabled: !busy,
              style: const TextStyle(color: Colors.white),
              onSubmitted: (_) => busy ? null : _save(),
              decoration: _field('Type it again', _hide2,
                  () => setState(() => _hide2 = !_hide2)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 22,
              child: Text(_error,
                  style: const TextStyle(
                      color: Color(0xFFFF9AA9), fontSize: 13.5)),
            ),
            const SizedBox(height: 10),
            _button(
                busy ? 'Saving...' : 'Save new password', busy ? null : _save),
            const SizedBox(height: 14),
            const Text(
              "At least 6 characters. Don't use the same password as your email.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12.5),
            ),
          ],
        );
      case _Stage.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
                child: _icon(Icons.check_rounded,
                    const [Color(0xFF24D17E), Color(0xFF1FB5A8)])),
            const SizedBox(height: 20),
            const Text('Password changed',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Log in with your new password.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 14.5)),
            const SizedBox(height: 26),
            _button('Go to log in', () => Navigator.of(context).pop()),
          ],
        );
      case _Stage.expired:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
                child: _icon(Icons.timer_off_outlined,
                    const [Color(0xFFFF9F1C), Color(0xFFFF4B6E)])),
            const SizedBox(height: 20),
            const Text('This link has expired',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text(
              'Reset links work once and only for a short time. '
              'Ask for a new one and use the newest email.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 14.5),
            ),
            const SizedBox(height: 26),
            _button(_email.isEmpty ? 'OK' : 'Send me a new link', _askNewLink),
          ],
        );
      case _Stage.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
                child: _icon(Icons.error_outline,
                    const [Color(0xFFFF9F1C), Color(0xFFFF4B6E)])),
            const SizedBox(height: 20),
            Text(_error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 26),
            _button('Close', () => Navigator.of(context).pop(), filled: false),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: _body(),
        ),
      ),
    );
  }
}

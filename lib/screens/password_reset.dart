// Password reset email (4 Nov 2026) - one place for "Forgot password?" on
// the login screen and in the Delete account flow.
//
// Ko's report: the reset email arrived in Gmail's Spam, and after many
// tries in a row it stopped arriving, while the app showed no clear
// message (only a short snackbar). Firebase sends the email itself (from
// noreply@<project>.firebaseapp.com), so the app can't force it into the
// inbox - but it can say clearly what happened:
//   - a loading spinner while Firebase answers (max 20 s),
//   - sent -> a dialog "Check your email ... look in Spam / Junk too"
//     with "Open Gmail",
//   - too-many-requests (Firebase pauses reset emails after many tries
//     in a short time) -> "Too many tries - wait about an hour",
//   - no internet / timeout / bad email -> its own clear message.
// With Firebase's email-enumeration protection on, an email that has no
// account also counts as "sent" (no error comes back) - so the text says
// "If an account exists for ...".
// Landing in the inbox instead of Spam needs Fly's own email domain
// (Firebase Console -> Authentication -> Templates -> customize domain).
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Sends the reset email to [email] and tells the person the result in a
/// dialog. [after] is an extra line under the "sent" text (e.g. what to do
/// next in the Delete account flow).
Future<void> sendPasswordResetWithFeedback(
  BuildContext context,
  String email, {
  String? after,
}) async {
  final String address = email.trim();
  if (address.isEmpty) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: Colors.white)),
    ),
  );

  String? errorTitle;
  String? errorText;
  try {
    await FirebaseAuth.instance
        .sendPasswordResetEmail(email: address)
        .timeout(const Duration(seconds: 20));
  } on FirebaseAuthException catch (e) {
    switch (e.code) {
      case 'too-many-requests':
        errorTitle = 'Too many tries';
        errorText = 'For your safety, reset emails for this account are '
            'paused for a while. Please wait about an hour and try again.';
        break;
      case 'network-request-failed':
        errorTitle = 'No connection';
        errorText = 'Check your internet connection and try again.';
        break;
      case 'invalid-email':
        errorTitle = 'Check the email';
        errorText = 'That email address looks invalid.';
        break;
      case 'user-not-found':
        errorTitle = 'No account found';
        errorText = 'There is no Fly account with that email.';
        break;
      case 'user-disabled':
        errorTitle = 'Account closed';
        errorText = 'This account has been closed, so its password can '
            'not be reset.';
        break;
      default:
        errorTitle = "Couldn't send the email";
        errorText = 'Please try again in a few minutes. (${e.code})';
    }
  } on TimeoutException {
    errorTitle = 'No answer';
    errorText = 'The connection is too slow right now. Please try again.';
  } catch (_) {
    errorTitle = "Couldn't send the email";
    errorText = 'Please try again in a few minutes.';
  }

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // the spinner
  HapticFeedback.lightImpact();

  final bool sent = errorTitle == null;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Row(
        children: [
          Icon(sent ? Icons.mark_email_read_outlined : Icons.error_outline,
              color: sent ? const Color(0xFF24D17E) : const Color(0xFFFF9F1C)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(sent ? 'Check your email' : errorTitle!,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: sent
              ? [
                  Text(
                    'If an account exists for $address, we sent it a link '
                    'to set a new password.',
                    style: const TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9F1C).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color:
                              const Color(0xFFFF9F1C).withValues(alpha: 0.4)),
                    ),
                    child: const Text(
                      "Can't find it? It can take a few minutes. Please look "
                      'in your Spam or Junk folder too, and mark it '
                      '"Not spam".',
                      style: TextStyle(
                          color: Color(0xFFFFD08A), fontSize: 13, height: 1.4),
                    ),
                  ),
                  if (after != null) ...[
                    const SizedBox(height: 12),
                    Text(after,
                        style: const TextStyle(
                            color: Colors.white70, height: 1.4)),
                  ],
                ]
              : [
                  Text(errorText!,
                      style:
                          const TextStyle(color: Colors.white70, height: 1.4)),
                ],
        ),
      ),
      actions: [
        if (sent)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openGmail();
            },
            child: const Text('Open Gmail',
                style: TextStyle(color: Color(0xFF35E1F2))),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

// Same channel as video_call_screen.dart's kBackgroundChannel
// (MainActivity.kt) - only "openEmailApp" is used here.
const MethodChannel _flyChannel = MethodChannel('fly/background');

// The Gmail APP itself (MainActivity.kt "openEmailApp"), else the phone's
// own email app; only if there is none, Gmail in the browser.
Future<void> _openGmail() async {
  try {
    final bool? opened = await _flyChannel.invokeMethod<bool>('openEmailApp');
    if (opened == true) return;
  } catch (_) {}
  try {
    await launchUrl(Uri.parse('https://mail.google.com/mail/u/0/#inbox'),
        mode: LaunchMode.externalApplication);
  } catch (_) {}
}

// Text moderation (21 Oct 2026) - asked BEFORE text that other people will
// see is saved: names, Sky Notes, video captions (+ hashtags, which come
// from the caption, and text stickers on the video), comments / replies,
// live comments and live titles. Chat messages are NOT checked (private
// between friends; Report handles them).
//
//   1. ContentFilter (on the phone, instant, works offline) - obvious
//      English words only;
//   2. the Worker's POST /moderate-text {text, kind} -> {ok} or
//      {ok: false, reason} - Zawgyi/Unicode Burmese, tricks like
//      "f u c k" / "sh1t" / zero-width characters, Telegram/WhatsApp
//      links, fake "Fly Official" names. Cloudflare never sleeps, so this
//      normally answers in ~0.2 s.
//
// If the Worker can't be reached (offline, timeout), the text passes on
// step 1 alone - Fly never refuses a post just because the check itself
// failed. Captions and comments still get the fly-moderation (Render)
// check afterwards, as before.
//
// Usage:
//   final ModerationResult r =
//       await ModerationService.checkText(text, ModerationKind.comment);
//   if (!r.ok) { show(r.message); return; }
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../app_config.dart';
import 'content_filter.dart';
import 'worker_auth.dart';

enum ModerationKind {
  name('name'),
  skyNote('skynote'),
  caption('caption'),
  comment('comment'),
  liveComment('live_comment'),
  liveTitle('live_title');

  const ModerationKind(this.apiName);

  /// The `kind` value the Worker expects.
  final String apiName;
}

class ModerationResult {
  /// True when the text may be saved.
  final bool ok;

  /// Friendly, ready-to-show English message when [ok] is false.
  final String? message;

  const ModerationResult._(this.ok, this.message);

  static const ModerationResult allowed = ModerationResult._(true, null);

  factory ModerationResult.blocked(ModerationKind kind, String reason) =>
      ModerationResult._(false, ModerationService.messageFor(kind, reason));
}

class ModerationService {
  ModerationService._();

  static const Duration _timeout = Duration(seconds: 6);

  /// Checks [text] before it is saved. Empty text is always fine.
  static Future<ModerationResult> checkText(
    String text,
    ModerationKind kind,
  ) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return ModerationResult.allowed;

    // 1. Instant, offline.
    if (ContentFilter.containsBlockedContent(trimmed)) {
      return ModerationResult.blocked(kind, 'language');
    }

    // 2. The Worker.
    try {
      final http.Response res = await http
          .post(
            Uri.parse('${AppConfig.workerUrl}/moderate-text'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'text': trimmed, 'kind': kind.apiName}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('moderate-text: HTTP ${res.statusCode}');
        return ModerationResult.allowed;
      }
      final dynamic data = jsonDecode(res.body);
      if (data is Map && data['ok'] == false) {
        return ModerationResult.blocked(
            kind, (data['reason'] as String?) ?? 'language');
      }
      return ModerationResult.allowed;
    } catch (e) {
      // Offline / timeout / not signed in: step 1 already passed.
      debugPrint('moderate-text: skipped ($e)');
      return ModerationResult.allowed;
    }
  }

  /// The message shown when something is refused.
  static String messageFor(ModerationKind kind, String reason) {
    if (reason == 'reserved') {
      return 'This name looks like an official Fly account. Please choose another name.';
    }
    if (reason == 'spam') {
      return kind == ModerationKind.name
          ? "Names can't contain links or phone numbers. Please choose another name."
          : "Links to other apps and spam aren't allowed on Fly. Please remove them.";
    }
    switch (kind) {
      case ModerationKind.name:
        return "This name isn't allowed on Fly. Please choose another one.";
      case ModerationKind.skyNote:
        return 'Your note contains inappropriate language. Please edit it.';
      case ModerationKind.caption:
        return 'Your caption or text contains inappropriate language. Please edit it before posting.';
      case ModerationKind.comment:
        return 'Your comment contains inappropriate language. Please edit it.';
      case ModerationKind.liveComment:
        return 'Your message contains inappropriate language. Please edit it.';
      case ModerationKind.liveTitle:
        return 'Your live title contains inappropriate language. Please edit it.';
    }
  }
}

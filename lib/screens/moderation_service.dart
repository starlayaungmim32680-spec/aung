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
// failed. (The old fly-moderation server on Render is no longer used.)
//
// Usage:
//   final ModerationResult r =
//       await ModerationService.checkText(text, ModerationKind.comment);
//   if (!r.ok) { show(r.message); return; }
//
// Pictures (21 Oct 2026, night): checkVideo() takes small frames out of a
// video ON THE PHONE (one every 2 seconds of the part that will be posted,
// at least 6, at most 16) and checkImage() shrinks a photo; both go to the
// Worker's
// POST /moderate-image, which asks OpenAI (nudity/sexual, graphic
// violence, self-harm). This runs BEFORE anything is uploaded, so a
// refused video never reaches Bunny. Used for feed posts
// (post_upload_manager.dart), video + photo stories (story_screen.dart)
// and profile photos (profile_screen.dart). Chat photos are NOT checked
// (private between friends - Report handles them).
// Pictures FAIL CLOSED (22 Oct 2026, Ko: sexual videos/photos must not
// get in): if the check can't run (offline, OpenAI down or over its free
// limit, no frames could be read) the upload is refused with "try again"
// (ModerationResult.retryable). Text still fails open.
// Known gaps: a very short scene between two frames can slip through,
// sound is not checked, and OpenAI's image check has no "minors"
// category - reports cover the rest.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../app_config.dart';
import 'content_filter.dart';
import 'worker_auth.dart';

enum ModerationKind {
  name('name'),
  skyNote('skynote'),
  caption('caption'),
  comment('comment'),
  liveComment('live_comment'),
  liveTitle('live_title'),
  // Pictures (checkVideo / checkImage).
  video('video'),
  photo('photo');

  const ModerationKind(this.apiName);

  /// The `kind` value the Worker expects.
  final String apiName;
}

class ModerationResult {
  /// True when the text may be saved.
  final bool ok;

  /// Friendly, ready-to-show English message when [ok] is false.
  final String? message;

  /// True when it was refused only because the check couldn't run -
  /// trying again later may work (show a Retry).
  final bool retryable;

  const ModerationResult._(this.ok, this.message, {this.retryable = false});

  static const ModerationResult allowed = ModerationResult._(true, null);

  factory ModerationResult.blocked(ModerationKind kind, String reason) =>
      ModerationResult._(false, ModerationService.messageFor(kind, reason));

  factory ModerationResult.unchecked(ModerationKind kind) => ModerationResult._(
        false,
        kind == ModerationKind.video
            ? "We couldn't check your video right now. Please check your connection and try again in a minute."
            : "We couldn't check your photo right now. Please check your connection and try again in a minute.",
        retryable: true,
      );
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

  // ---------------------------------------------------------------------
  // Pictures
  // ---------------------------------------------------------------------

  static const int _frameEveryMs = 2000;
  static const int _minFrames = 6;
  static const int _maxFrames = 16;
  static const int _frameMaxWidth = 512;
  static const Duration _imageTimeout = Duration(seconds: 45);

  /// Checks a video before it is uploaded. [startMs]/[endMs] limit the
  /// frames to the part that will actually be posted (the trim range);
  /// without them the whole video is used.
  static Future<ModerationResult> checkVideo(
    File file, {
    int? startMs,
    int? endMs,
  }) async {
    try {
      int from = startMs ?? 0;
      int to = endMs ?? 0;
      if (to <= from) {
        final VideoPlayerController c = VideoPlayerController.file(file);
        try {
          await c.initialize();
          to = c.value.duration.inMilliseconds;
        } finally {
          await c.dispose();
        }
        from = 0;
      }
      if (to <= from) return ModerationResult.unchecked(ModerationKind.video);

      // One frame every 2 s (6..16), spread evenly from 2% to 98%.
      final int count =
          ((to - from) ~/ _frameEveryMs).clamp(_minFrames, _maxFrames).toInt();
      final List<Uint8List> frames = [];
      for (int i = 0; i < count; i++) {
        final double at = 0.02 + 0.96 * i / (count - 1);
        final int timeMs = from + ((to - from) * at).round();
        final Uint8List? frame = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: _frameMaxWidth,
          timeMs: timeMs,
          quality: 70,
        );
        if (frame != null && frame.isNotEmpty) frames.add(frame);
      }
      // Most frames must be readable, or the video counts as unchecked.
      if (frames.length < (count + 1) ~/ 2) {
        debugPrint(
            'moderate-image: only ${frames.length}/$count frames from ${file.path}');
        return ModerationResult.unchecked(ModerationKind.video);
      }
      return _checkPictures(frames, ModerationKind.video);
    } catch (e) {
      debugPrint('moderate-image: video frames failed ($e)');
      return ModerationResult.unchecked(ModerationKind.video);
    }
  }

  /// Checks a photo (story photo, profile photo) before it is uploaded.
  static Future<ModerationResult> checkImage(Uint8List bytes) async {
    try {
      final Uint8List small = await _shrink(bytes);
      return _checkPictures([small], ModerationKind.photo);
    } catch (e) {
      debugPrint('moderate-image: photo failed ($e)');
      return ModerationResult.unchecked(ModerationKind.photo);
    }
  }

  // Max _frameMaxWidth wide, as PNG (dart:ui can't write JPEG). Small
  // photos are sent as they are.
  static Future<Uint8List> _shrink(Uint8List bytes) async {
    if (bytes.length <= 400 * 1024) return bytes;
    final ui.Codec codec =
        await ui.instantiateImageCodec(bytes, targetWidth: _frameMaxWidth);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? data =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return bytes;
    return data.buffer.asUint8List();
  }

  static Future<ModerationResult> _checkPictures(
    List<Uint8List> pictures,
    ModerationKind kind,
  ) async {
    try {
      final http.Response res = await http
          .post(
            Uri.parse('${AppConfig.workerUrl}/moderate-image'),
            headers: {
              ...await workerAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'images': pictures.map(base64Encode).toList(),
              'kind': kind.apiName,
            }),
          )
          .timeout(_imageTimeout);
      if (res.statusCode != 200) {
        debugPrint('moderate-image: HTTP ${res.statusCode} ${res.body}');
        return ModerationResult.unchecked(kind);
      }
      final dynamic data = jsonDecode(res.body);
      if (data is Map && data['ok'] == false) {
        return ModerationResult.blocked(
            kind, (data['reason'] as String?) ?? 'nudity');
      }
      if (data is Map && data['ok'] == true && data['checked'] == true) {
        return ModerationResult.allowed;
      }
      // No AI answer (no key, OpenAI down / over its limit) -> refuse.
      debugPrint('moderate-image: not checked ($data)');
      return ModerationResult.unchecked(kind);
    } catch (e) {
      debugPrint('moderate-image: failed ($e)');
      return ModerationResult.unchecked(kind);
    }
  }

  /// The message shown when something is refused.
  static String messageFor(ModerationKind kind, String reason) {
    if (kind == ModerationKind.video || kind == ModerationKind.photo) {
      final String what = switch (reason) {
        'violence' => 'graphic violence',
        'self_harm' => 'self-harm',
        _ => 'nudity or sexual content',
      };
      return kind == ModerationKind.video
          ? "This video can't be posted because it seems to show $what. "
              'Please choose another video.'
          : "This photo can't be used because it seems to show $what. "
              'Please choose another photo.';
    }
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
      case ModerationKind.video:
      case ModerationKind.photo:
        return "This can't be posted because it seems to break our Community Guidelines.";
    }
  }
}

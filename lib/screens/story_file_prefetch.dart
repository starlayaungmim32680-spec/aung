// Instant story start for VIEWERS (18 Oct 2026).
//
// The poster's own story starts at once because it plays from a local file
// (see local_video_cache.dart). A viewer's story had to open a network
// stream first, which showed a spinner for a second or two even when the
// next story was warmed up. So while the Home story bar is on screen we
// quietly download each story's video file (Bunny's original file, which
// Early-Play makes available right after upload) into the cache folder
// and register it in [LocalVideoCache] - the viewer then plays it like a
// local file, exactly as fast as the poster does.
//
// Files live in the OS cache folder (it may clear them any time; that is
// fine - playback just falls back to the network), at most [_maxFiles]
// are kept, and a failed download is retried at most every 30 seconds.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'local_video_cache.dart';
import 'video_upload_service.dart' show bunnyOriginalFileUrl;

class StoryFilePrefetch {
  StoryFilePrefetch._();

  static const int _maxFiles = 30;
  static const int _maxBytes = 60 * 1024 * 1024;
  static const int _maxParallel = 2;
  static const Duration _retryAfter = Duration(seconds: 30);

  static final List<String> _queue = [];
  static final Set<String> _busy = {};
  static final Map<String, DateTime> _failedAt = {};
  static int _active = 0;

  // Asks for [hlsUrl]'s video file to be fetched in the background.
  static void prefetch(String hlsUrl) {
    if (hlsUrl.isEmpty) return;
    if (LocalVideoCache.fileFor(hlsUrl) != null) return;
    if (_busy.contains(hlsUrl) || _queue.contains(hlsUrl)) return;
    final DateTime? failed = _failedAt[hlsUrl];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return;
    }
    if (bunnyOriginalFileUrl(hlsUrl) == null) return;
    _queue.add(hlsUrl);
    _pump();
  }

  static void _pump() {
    while (_active < _maxParallel && _queue.isNotEmpty) {
      final String url = _queue.removeAt(0);
      _active++;
      _busy.add(url);
      _download(url).whenComplete(() {
        _active--;
        _busy.remove(url);
        _pump();
      });
    }
  }

  static Future<void> _download(String hlsUrl) async {
    final String? original = bunnyOriginalFileUrl(hlsUrl);
    if (original == null) return;
    http.Client? client;
    File? part;
    try {
      // https://<cdn>/<guid>/original -> <guid>
      final List<String> segments = Uri.parse(original).pathSegments;
      if (segments.length < 2) return;
      final String guid = segments[segments.length - 2];
      final Directory dir =
          Directory('${(await getTemporaryDirectory()).path}/story_cache');
      await dir.create(recursive: true);
      final File target = File('${dir.path}/$guid.mp4');

      // Already downloaded earlier (even in a previous app session).
      if (await target.exists() && await target.length() > 0) {
        LocalVideoCache.register(hlsUrl, target.path);
        return;
      }

      client = http.Client();
      final http.StreamedResponse response = await client
          .send(http.Request('GET', Uri.parse(original)))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        _failedAt[hlsUrl] = DateTime.now();
        return;
      }
      final int? expected = response.contentLength;
      if (expected != null && expected > _maxBytes) {
        _failedAt[hlsUrl] = DateTime.now();
        return;
      }

      part = File('${target.path}.part');
      final IOSink sink = part.openWrite();
      int written = 0;
      try {
        await response.stream.timeout(const Duration(seconds: 30)).map((c) {
          written += c.length;
          if (written > _maxBytes) throw const FormatException('too big');
          return c;
        }).pipe(sink);
      } catch (_) {
        await sink.close().catchError((_) {});
        rethrow;
      }
      if (written <= 0 || (expected != null && written != expected)) {
        _failedAt[hlsUrl] = DateTime.now();
        await part.delete();
        return;
      }
      await part.rename(target.path);
      part = null;
      LocalVideoCache.register(hlsUrl, target.path);
      unawaited(_trim(dir));
    } catch (e) {
      _failedAt[hlsUrl] = DateTime.now();
      debugPrint('[story_prefetch] $hlsUrl failed: $e');
      try {
        if (part != null && await part.exists()) await part.delete();
      } catch (_) {}
    } finally {
      client?.close();
    }
  }

  // Keeps only the newest [_maxFiles] files, and nothing older than a day.
  static Future<void> _trim(Directory dir) async {
    try {
      final List<File> files = [
        await for (final FileSystemEntity e in dir.list())
          if (e is File && e.path.endsWith('.mp4')) e,
      ];
      files
          .sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 1));
      for (int i = 0; i < files.length; i++) {
        if (i >= _maxFiles || files[i].lastModifiedSync().isBefore(cutoff)) {
          await files[i].delete();
        }
      }
    } catch (_) {}
  }
}

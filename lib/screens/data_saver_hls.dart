// 23 Nov 2026 (Scale plan 2, S4 "data saver").
//
// On MOBILE DATA a Bunny Stream video should never pull its 720p
// rendition: Bunny bills every byte served, and so does the person's data
// plan. First try (23 Nov) played https://<cdn>/<guid>/480p/video.m3u8
// directly - but Bunny keeps the AUDIO as its own track
// (#EXT-X-MEDIA TYPE=AUDIO, URI="audio/audio.m3u8" in playlist.m3u8), so
// that file had pictures and NO SOUND (Ko, 23 Nov).
//
// Now: fetch the small master playlist.m3u8 once, keep every line except
// the video variants above 480p, make all links absolute
// (https://<cdn>/<guid>/...), save it as <temp>/fly_hls/<guid>.m3u8 and
// let the player open that local file. The player then still picks
// between 360p and 480p by itself, WITH the audio track - it just never
// sees 720p. On Wi-Fi nothing changes (the normal playlist, up to 720p).
//
// Anything odd (no internet, playlist not ready on a fresh upload, no
// variant <= 480p) -> null, and the caller plays the normal url. A local
// playlist that fails to play is reported with markFailed() and that
// video uses the normal url for the rest of this run.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../network_service.dart';
import 'media_utils.dart';

class DataSaverHls {
  DataSaverHls._();

  /// Highest video size kept on mobile data (the shorter side, so a
  /// portrait 480x854 video counts as 480p).
  static const int maxP = 480;

  static const String _folder = 'fly_hls';
  static final Map<String, Future<File?>> _files = {};
  static final Set<String> _failed = {};

  /// The video player for [videoUrl]: the 480p-capped local playlist on
  /// mobile data when possible, otherwise the normal network url.
  static Future<VideoPlayerController> controllerFor(String videoUrl) async {
    final File? file = await fileFor(videoUrl);
    if (file != null) return VideoPlayerController.file(file);
    return VideoPlayerController.networkUrl(
        Uri.parse(playableVideoUrl(videoUrl)));
  }

  /// True when [controller] plays one of our capped local playlists.
  static bool isCapped(VideoPlayerController controller) =>
      controller.dataSource.contains('/$_folder/');

  /// The capped playlist of [videoUrl] did not play -> normal url from now
  /// on (this run).
  static void markFailed(String videoUrl) {
    _failed.add(videoUrl);
    _files.remove(videoUrl);
  }

  /// The capped local playlist for [videoUrl], or null (Wi-Fi, not a Bunny
  /// playlist, failed before, or could not be built).
  static Future<File?> fileFor(String videoUrl) {
    if (!NetworkService.instance.isOnMobileData) return Future.value(null);
    if (_failed.contains(videoUrl)) return Future.value(null);
    if (!_isBunnyMaster(videoUrl)) return Future.value(null);
    final Future<File?> cached = _files[videoUrl] ?? _build(videoUrl);
    _files[videoUrl] = cached;
    // A failed build is not kept - the next try fetches again.
    cached.then((f) {
      if (f == null && identical(_files[videoUrl], cached)) {
        _files.remove(videoUrl);
      }
    });
    return cached;
  }

  static bool _isBunnyMaster(String url) =>
      url.contains('b-cdn.net') && url.endsWith('/playlist.m3u8');

  static Future<File?> _build(String masterUrl) async {
    try {
      final http.Response res = await http
          .get(Uri.parse(masterUrl))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final String? capped = cappedMaster(res.body, masterUrl);
      if (capped == null) return null;

      final List<String> parts = Uri.parse(masterUrl).pathSegments;
      final String guid = parts.length >= 2 ? parts[parts.length - 2] : '';
      if (guid.isEmpty) return null;
      final Directory dir =
          Directory('${(await getTemporaryDirectory()).path}/$_folder');
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File('${dir.path}/$guid.m3u8');
      await file.writeAsString(capped, flush: true);
      return file;
    } catch (e) {
      debugPrint('DataSaverHls: $e');
      return null;
    }
  }

  /// [body] = Bunny's master playlist. Returns it without the video
  /// variants above [maxP] and with absolute links, or null when nothing
  /// <= [maxP] is in it.
  @visibleForTesting
  static String? cappedMaster(String body, String masterUrl) {
    final String base = masterUrl.substring(0, masterUrl.lastIndexOf('/') + 1);
    String abs(String u) => u.startsWith('http') ? u : '$base$u';
    final RegExp uriAttr = RegExp(r'URI="([^"]+)"');
    final RegExp resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)');

    final List<String> lines = body.split(RegExp(r'\r?\n'));
    final List<String> out = [];
    int kept = 0;
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        // The variant's url is the next non-empty, non-comment line.
        int j = i + 1;
        while (j < lines.length &&
            (lines[j].trim().isEmpty || lines[j].trim().startsWith('#'))) {
          j++;
        }
        if (j >= lines.length) break;
        final String uri = lines[j].trim();
        final Match? m = resolution.firstMatch(line);
        final int p = m == null
            ? 0
            : [int.parse(m.group(1)!), int.parse(m.group(2)!)]
                .reduce((a, b) => a < b ? a : b);
        if (p <= maxP) {
          out.add(line);
          out.add(abs(uri));
          kept++;
        }
        i = j;
      } else if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
        continue; // seek thumbnails - not used by the app
      } else if (line.startsWith('#EXT-X-MEDIA')) {
        out.add(line.replaceAllMapped(uriAttr, (m) => 'URI="${abs(m[1]!)}"'));
      } else {
        out.add(line);
      }
    }
    if (kept == 0) return null;
    return '${out.join('\n')}\n';
  }
}

// Instant playback for the person who just posted a video.
//
// Bunny Stream needs some time to encode a new upload before its HLS
// playlist exists. Instead of making the uploader stare at "Processing",
// we remember which local file each freshly uploaded video came from and
// play THAT file (straight off the phone - no network, no waiting) for
// the uploader. Everyone else only sees the post once Bunny reports it
// ready (videoReady, set by the Worker's /bunny-webhook).
//
// Keyed by the post's/story's videoUrl, which is exactly what the feed
// and story viewer already have in hand. In-memory only: if the app is
// restarted before encoding finishes, playback just falls back to the
// network URL (and the "Processing video..." state in home_screen.dart).
import 'dart:io';

class LocalVideoCache {
  LocalVideoCache._();

  static final Map<String, String> _pathsByUrl = {};

  // Remember that [videoUrl] can be played from [localPath].
  static void register(String videoUrl, String localPath) {
    if (videoUrl.isEmpty || localPath.isEmpty) return;
    _pathsByUrl[videoUrl] = localPath;
  }

  // The local file for [videoUrl], or null if there isn't one (or it has
  // since been deleted by the OS clearing its temp/cache directory).
  static File? fileFor(String videoUrl) {
    final String? path = _pathsByUrl[videoUrl];
    if (path == null) return null;
    final File file = File(path);
    if (!file.existsSync()) {
      _pathsByUrl.remove(videoUrl);
      return null;
    }
    return file;
  }
}

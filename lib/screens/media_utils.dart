// Helpers for turning Cloudinary video URLs into cheap still images, and
// for picking the right playback quality for the current connection.
//
// Rendering a grid of thumbnails by spinning up a VideoPlayerController per
// tile is slow, burns data, and often shows a black frame. Cloudinary will
// hand back a JPG of any frame instead, which is far lighter.

import '../network_service.dart';

String cloudinaryThumbUrl(String videoUrl) {
  if (videoUrl.isEmpty) return '';
  String url = videoUrl;

  // Asking for an image extension makes Cloudinary return a still frame.
  final int dot = url.lastIndexOf('.');
  final int slash = url.lastIndexOf('/');
  if (dot > slash) {
    url = '${url.substring(0, dot)}.jpg';
  } else {
    url = '$url.jpg';
  }

  const String marker = '/upload/';
  final int idx = url.indexOf(marker);
  if (idx == -1) return url;

  final String head = url.substring(0, idx + marker.length);
  String tail = url.substring(idx + marker.length);

  // A trimmed upload carries its own start/end offsets, e.g. "so_0,eo_15".
  // Keeping those means asking for the very first frame, which is nearly
  // always black - so drop them before picking a frame.
  final List<String> parts = tail.split('/');
  final bool hasTransform =
      parts.isNotEmpty && !RegExp(r'^v\d+$').hasMatch(parts.first);
  if (hasTransform) {
    final List<String> kept = parts.first
        .split(',')
        .where((t) => !t.startsWith('so_') && !t.startsWith('eo_'))
        .toList();
    if (kept.isEmpty) {
      parts.removeAt(0);
    } else {
      parts[0] = kept.join(',');
    }
    tail = parts.join('/');
  }

  // Take the frame from halfway through, so fade-ins and black intros
  // don't produce an empty-looking thumbnail.
  return '${head}so_50p/$tail';
}

// Inserts a Cloudinary quality/codec transform into a video URL, right
// after /upload/ and before any existing transforms (like a trim's
// so_/eo_ offsets). This meaningfully shrinks the file Cloudinary serves
// - usually with no visible quality loss on a good connection - so
// playback starts buffering (and therefore appears) noticeably faster.
//
// On a weak/offline connection (see network_service.dart), asks for a
// smaller, lower-bitrate version instead ("q_auto:low" + a 480px width
// cap) - trading visual sharpness for a file that actually finishes
// buffering instead of stalling. Both home_screen.dart's real playback
// and video_preload_cache.dart's neighbor preloading go through this one
// function, so both benefit automatically.
String playableVideoUrl(String videoUrl) {
  if (videoUrl.isEmpty) return videoUrl;
  const String marker = '/upload/';
  final int idx = videoUrl.indexOf(marker);
  if (idx == -1) return videoUrl;

  final String head = videoUrl.substring(0, idx + marker.length);
  final String tail = videoUrl.substring(idx + marker.length);

  // Already has a quality transform (shouldn't normally happen, but avoid
  // stacking a second one if this URL was already processed once).
  if (tail.contains('q_auto')) return videoUrl;

  final String transform = NetworkService.instance.isSlowOrOffline
      ? 'q_auto:low,w_480,c_limit'
      : 'q_auto';

  return '$head$transform/$tail';
}

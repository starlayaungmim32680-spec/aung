// Helpers for turning Cloudinary video URLs into cheap still images.
//
// Rendering a grid of thumbnails by spinning up a VideoPlayerController per
// tile is slow, burns data, and often shows a black frame. Cloudinary will
// hand back a JPG of any frame instead, which is far lighter.

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

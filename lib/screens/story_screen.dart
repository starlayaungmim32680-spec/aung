import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_trimmer_2/video_trimmer_2.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'trim_editor_screen.dart';
import 'video_effects_screen.dart';
import 'photo_effects_screen.dart';
import 'story_music.dart';
import 'sound_screen.dart';
import 'sound_moderation.dart';
import 'video_upload_service.dart';
import 'local_video_cache.dart';
import 'text_overlay_style.dart';
import 'video_call_screen.dart' show kTokenServerUrl;
import 'worker_auth.dart';

// Reaction emojis available on stories
const Map<String, String> kStoryReactions = {
  'like': '👍',
  'love': '❤️',
  'haha': '😂',
  'wow': '😮',
  'sad': '😢',
  'angry': '😡',
};

// Bunny hostnames (not secret - just addresses). The real credentials
// live only as Cloudflare Worker secrets - see livekit_token_worker.js's
// /upload-image and /upload-video handlers.
const String _bunnyImagesCdnHostname = 'fly-images-aungdev756617.b-cdn.net';
const String _bunnyStreamCdnHostname = 'vz-a6ab9346-730.b-cdn.net';

// How long a story stays visible
const Duration kStoryLifetime = Duration(hours: 14);

// ---------------------------------------------------------------------------
// Add a story: pick a photo or video, upload to Bunny, create the doc
// ---------------------------------------------------------------------------
Future<void> addStory(BuildContext context) async {
  final String? kind = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF161616),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.photo, color: Colors.white),
              title: const Text('Photo', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text('Video', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  if (kind == null) return;

  final ImagePicker picker = ImagePicker();
  final XFile? picked = kind == 'image'
      ? await picker.pickImage(source: ImageSource.gallery)
      : await picker.pickVideo(source: ImageSource.gallery);
  if (picked == null) return;
  if (!context.mounted) return;

  // Stories cap videos to 15 seconds - both for a snappier, more
  // TikTok/Instagram-Stories-like viewing experience, and because it
  // directly bounds how much Storage/CDN bandwidth a single story clip
  // can ever cost, no matter how long the original video someone picked
  // actually is. Photos skip this entirely - there's no trim step for a
  // still image.
  File videoFileToUpload = File(picked.path);
  double videoSpeed = 1.0;
  String videoFilterType = 'none';
  List<TextOverlayData> videoTextOverlays = [];
  // Background music picked in either effects screen (null = none; a
  // video story then keeps - and shares - its own audio).
  StoryMusicSelection? storyMusic;
  // Whether a video story's own audio may be shared (rights confirmed).
  bool shareVideoSound = false;
  if (kind == 'video') {
    final TrimResult? trimResult = await Navigator.push<TrimResult>(
      context,
      MaterialPageRoute(
        builder: (context) => TrimEditorScreen(
          videoFile: File(picked.path),
          maxDurationSeconds: 15,
        ),
      ),
    );
    // Cancelled the trim step entirely - treat it the same as cancelling
    // the whole "add a story" flow, rather than posting an untrimmed
    // (potentially much longer, much more expensive to store/serve)
    // video.
    if (trimResult == null) return;
    if (!context.mounted) return;

    try {
      final Trimmer trimmer = Trimmer();
      final File trimmed = await trimmer.trimVideo(
        file: trimResult.originalFile,
        startMs: trimResult.startSeconds * 1000,
        endMs: trimResult.endSeconds * 1000,
      );
      videoFileToUpload = trimmed;
    } catch (e) {
      // Fall back to the untrimmed file rather than blocking the story
      // entirely over a trim failure - worse than ideal (the 15s cost
      // cap doesn't apply this one time) but far better than the person
      // not being able to post at all.
    }
    if (!context.mounted) return;

    // Speed, color filter, and text overlays - the same screen post
    // uploads use. Unlike upload_screen.dart (which runs this on the
    // UNtrimmed original, since its own physical trim happens later at
    // upload time), stories have already been physically cut above, so
    // this runs on the already-trimmed file with startSeconds: 0 rather
    // than needing to seek into an offset within a longer original.
    final VideoEffectsResult? effects =
        await Navigator.push<VideoEffectsResult>(
      context,
      MaterialPageRoute(
        builder: (context) => VideoEffectsScreen(
          videoFile: videoFileToUpload,
          startSeconds: 0,
          enableMusic: true,
        ),
      ),
    );
    // Cancelling this step cancels the whole "add a story" flow too, the
    // same as cancelling the trim step above - consistent behavior
    // throughout this pick-trim-style pipeline.
    if (effects == null) return;
    if (!context.mounted) return;
    videoSpeed = effects.speed;
    videoFilterType = effects.filterType;
    videoTextOverlays = effects.textOverlays;
    storyMusic = effects.music;
    shareVideoSound = effects.shareSound;
  }

  // Photo stories get their own effects step: color filter + text/sticker
  // overlays, stored as metadata (same fields as a video story) rather than
  // baked into the pixels. Cancelling it cancels the whole flow, same as
  // the video steps above.
  String imageFilterType = 'none';
  List<TextOverlayData> imageTextOverlays = [];
  double? imageAspectRatio;
  if (kind == 'image') {
    final PhotoEffectsResult? photoEffects =
        await Navigator.push<PhotoEffectsResult>(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoEffectsScreen(imageFile: File(picked.path)),
      ),
    );
    if (photoEffects == null) return;
    if (!context.mounted) return;
    imageFilterType = photoEffects.filterType;
    imageTextOverlays = photoEffects.textOverlays;
    imageAspectRatio = photoEffects.aspectRatio;
    storyMusic = photoEffects.music;
  }

  // Simple uploading dialog
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(color: Colors.redAccent),
    ),
  );

  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in');

    String mediaUrl;
    // Video stories only: Bunny id + the local file, for instant playback
    // by the poster and the "ready" flag (see video_upload_service.dart).
    String? storyBunnyVideoId;
    String? storyLocalVideoPath;
    if (kind == 'image') {
      // Images go to Bunny Storage - no transcoding needed, so this is a
      // plain pass-through PUT via the Worker's /upload-image (same
      // endpoint/hostname as the profile photo upload in
      // profile_screen.dart).
      final Uint8List bytes = await File(picked.path).readAsBytes();
      final String fileName =
          '${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final Map<String, String> authHeaders = await workerAuthHeaders();
      final http.Response response = await http
          .post(
            Uri.parse('$kTokenServerUrl/upload-image'),
            headers: {
              ...authHeaders,
              'X-File-Name': fileName,
              'Content-Type': 'image/jpeg',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw Exception('Image upload failed: ${response.body}');
      }
      mediaUrl = 'https://$_bunnyImagesCdnHostname/$fileName';
    } else {
      // Videos go to Bunny Stream via the Worker's /upload-video - the
      // same endpoint upload_screen.dart uses for feed posts. Bunny
      // transcodes to adaptive-bitrate HLS automatically.
      // Stories now get the same compression + upload path as feed videos
      // (see video_upload_service.dart) - before, story videos went up
      // uncompressed with a fixed 2-minute timeout.
      final File storyVideo = await compressVideoForUpload(videoFileToUpload);
      final String videoId = await uploadVideoToBunny(
        file: storyVideo,
        title: 'Fly story',
      );
      mediaUrl = 'https://$_bunnyStreamCdnHostname/$videoId/playlist.m3u8';
      storyBunnyVideoId = videoId;
      storyLocalVideoPath = storyVideo.path;
    }

    // Get the poster's name/photo
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final pdata = profile.data();
    final String userName =
        (pdata?['displayName'] as String?)?.trim().isNotEmpty == true
            ? pdata!['displayName']
            : (user.email?.split('@').first ?? 'User');
    final String userPhoto = (pdata?['photoUrl'] as String?) ?? '';

    final now = DateTime.now();
    final storyRef = FirebaseFirestore.instance.collection('stories').doc();

    // Sound bookkeeping - same `sounds` collection feed posts use:
    //  - picked music: credit it and bump its usage count (trending);
    //  - a video story without music whose owner confirmed the rights:
    //    its own audio becomes a reusable "Original sound" (doc id = story
    //    id), exactly like a feed upload.
    //    The Bunny video outlives the 14h story, so the sound keeps
    //    working after the story itself expires.
    Map<String, dynamic> soundFields = {};
    if (storyMusic != null) {
      soundFields = storyMusic.toStoryFields();
      FirebaseFirestore.instance
          .collection('sounds')
          .doc(storyMusic.soundId)
          .set(
              {'usageCount': FieldValue.increment(1)}, SetOptions(merge: true));
    } else if (kind == 'video' && shareVideoSound) {
      await FirebaseFirestore.instance
          .collection('sounds')
          .doc(storyRef.id)
          .set({
        'ownerId': user.uid,
        'ownerName': userName,
        'title': 'Original sound',
        'sourceUrl': mediaUrl,
        'sourceStoryId': storyRef.id,
        'usageCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        ...newSoundModerationFields(),
      });
      // No soundSourceUrl here: the viewer just plays the video's own
      // audio; soundId/title only drive the "♪" credit chip.
      soundFields = {
        'soundId': storyRef.id,
        'soundTitle': 'Original sound',
        'soundOwnerName': userName,
      };
    }

    await storyRef.set({
      'userId': user.uid,
      'userName': userName,
      'userPhoto': userPhoto,
      'mediaUrl': mediaUrl,
      'mediaType': kind, // 'image' or 'video'
      // Effects metadata. Videos also carry a playback speed; photos carry
      // their aspect ratio so the viewer can place overlays over the exact
      // image rect the editor used.
      if (kind == 'video') ...{
        'videoSpeed': videoSpeed,
        'filterType': videoFilterType,
        'textOverlays': videoTextOverlays.map((o) => o.toMap()).toList(),
      },
      if (kind == 'image') ...{
        'filterType': imageFilterType,
        'textOverlays': imageTextOverlays.map((o) => o.toMap()).toList(),
        if (imageAspectRatio != null) 'imageAspectRatio': imageAspectRatio,
      },
      ...soundFields,
      // Other people only see a video story once Bunny can play it.
      if (storyBunnyVideoId != null)
        ...newVideoReadinessFields(storyBunnyVideoId),
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(kStoryLifetime)),
    });

    if (storyBunnyVideoId != null && storyLocalVideoPath != null) {
      // The poster watches their story instantly from this phone's file.
      LocalVideoCache.register(mediaUrl, storyLocalVideoPath);
      unawaited(syncVideoReady(storyRef, storyBunnyVideoId));
    }

    if (context.mounted) {
      Navigator.pop(context); // close uploading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Story posted!')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Story failed: $e')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Stories bar: a horizontal row of story circles shown at the top of Home
// ---------------------------------------------------------------------------
class StoriesBar extends StatelessWidget {
  const StoriesBar({super.key});

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;

    return SizedBox(
      height: 182,
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('stories')
            .where('expiresAt', isGreaterThan: Timestamp.now())
            .orderBy('expiresAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          final docs = snapshot.data?.docs ?? [];

          // Group active stories by user (keep insertion order = newest first)
          final String? myUid = FirebaseAuth.instance.currentUser?.uid;
          final Map<String, List<QueryDocumentSnapshot>> byUser = {};
          for (final d in docs) {
            final m = d.data() as Map<String, dynamic>;
            final uid = (m['userId'] as String?) ?? '';
            if (uid.isEmpty) continue;
            // A video story still being encoded is only shown to its poster.
            if (!isVideoVisibleTo(m, myUid)) continue;
            byUser.putIfAbsent(uid, () => []).add(d);
          }

          final List<String> userIds = byUser.keys.toList();

          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: [
              // "Create Story" card (shows my own profile photo, Facebook-style)
              _CreateStoryCard(onTap: () => addStory(context)),
              // One big card per user with an active story
              ...userIds.map((uid) {
                final stories = byUser[uid]!;
                final first = stories.first.data() as Map<String, dynamic>;
                return _StoryCard(
                  name: uid == myId
                      ? 'You'
                      : (first['userName'] as String? ?? 'User'),
                  photoUrl: first['userPhoto'] as String? ?? '',
                  storyCount: stories.length,
                  onTap: () {
                    final ordered = stories.reversed.toList();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StoryViewerScreen(stories: ordered),
                      ),
                    );
                  },
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

// Builds a Cloudinary first-frame JPG thumbnail from a video URL
String _videoThumbUrl(String videoUrl) {
  const marker = '/upload/';
  final i = videoUrl.indexOf(marker);
  if (i == -1) return videoUrl;
  var u = videoUrl.substring(0, i + marker.length) +
      'so_0/' +
      videoUrl.substring(i + marker.length);
  final dot = u.lastIndexOf('.');
  if (dot > u.lastIndexOf('/')) {
    u = '${u.substring(0, dot)}.jpg';
  } else {
    u = '$u.jpg';
  }
  return u;
}

// Facebook-style "Create Story" card: shows the current user's own profile
// photo filling the card, with a "+" badge overlapping the bottom of the
// photo (matching how Facebook/Instagram show your own avatar on this card).
class _CreateStoryCard extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateStoryCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 78,
        child: StreamBuilder<DocumentSnapshot>(
          stream: myId == null
              ? null
              : FirebaseFirestore.instance
                  .collection('users')
                  .doc(myId)
                  .snapshots(),
          builder: (context, snapshot) {
            final Map<String, dynamic>? profile =
                snapshot.data?.data() as Map<String, dynamic>?;
            final String photoUrl = (profile?['photoUrl'] as String?) ?? '';

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 1.5),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: ClipOval(
                          child: photoUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: photoUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) =>
                                      Container(color: Colors.grey[850]),
                                  errorWidget: (_, __, ___) =>
                                      Container(color: Colors.grey[850]),
                                )
                              : Container(
                                  color: Colors.grey[850],
                                  child: const Icon(Icons.person,
                                      color: Colors.white38, size: 30),
                                ),
                        ),
                      ),
                      // "+" badge overlapping the bottom-right of the circle
                      Positioned(
                        bottom: -2,
                        right: -2,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFFF4B6E),
                            border: Border.all(
                              color: Colors.black,
                              width: 2,
                            ),
                          ),
                          child: const Icon(Icons.add,
                              color: Colors.white, size: 15),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Your Story',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// Circular story avatar with a segmented gradient ring — the number of
// segments matches how many active stories this person has, so it reads
// differently from the plain solid ring other apps use.
class _StoryCard extends StatelessWidget {
  final String name;
  final String photoUrl;
  final int storyCount;
  final VoidCallback onTap;

  const _StoryCard({
    required this.name,
    required this.photoUrl,
    required this.storyCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 78,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: CustomPaint(
                painter: _SegmentedRingPainter(segments: storyCount),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: CircleAvatar(
                    backgroundColor: Colors.grey[800],
                    backgroundImage: photoUrl.isNotEmpty
                        ? CachedNetworkImageProvider(photoUrl)
                        : null,
                    child: photoUrl.isEmpty
                        ? Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 20),
                          )
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// Draws N gradient arcs (with small gaps between) instead of one solid
// ring — the segment count equals how many active stories this person
// has, so the ring itself hints at "how many stories" before you tap in.
class _SegmentedRingPainter extends CustomPainter {
  final int segments;
  final double strokeWidth;

  _SegmentedRingPainter({required this.segments, this.strokeWidth = 3});

  @override
  void paint(Canvas canvas, Size size) {
    final int count = segments < 1 ? 1 : segments;
    final Rect rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final double gapDegrees = count == 1 ? 0 : 12.0;
    final double sweepDegrees = (360.0 / count) - gapDegrees;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF), Color(0xFFFF4B6E)],
      ).createShader(rect);

    for (int i = 0; i < count; i++) {
      final double startDegrees = (360.0 / count) * i - 90 + (gapDegrees / 2);
      canvas.drawArc(
        rect,
        startDegrees * (pi / 180),
        sweepDegrees * (pi / 180),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedRingPainter oldDelegate) =>
      oldDelegate.segments != segments;
}

// ---------------------------------------------------------------------------
// Full-screen story viewer with progress bars, auto-advance and reactions
// ---------------------------------------------------------------------------
class StoryViewerScreen extends StatefulWidget {
  final List<QueryDocumentSnapshot> stories;
  const StoryViewerScreen({super.key, required this.stories});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  VideoPlayerController? _video;
  int _index = 0;

  final List<_FloatingReaction> _floating = [];
  StreamSubscription<QuerySnapshot>? _reactionSub;
  bool _firstReactionSnapshot = true;
  final Random _rand = Random();

  static const Duration _imageDuration = Duration(seconds: 6);

  // Background music for the current story (see story_music.dart).
  final StoryMusicPlayer _music = StoryMusicPlayer();
  bool _hasMusic = false;
  // Bumped on every _loadCurrent so a slow load for a story the viewer has
  // already swiped past never starts playing over the current one.
  int _loadSeq = 0;

  // Wraps [child] in a ColorFiltered matrix only when a filter was actually
  // picked at upload time - skips the layer entirely for 'none' rather than
  // applying a technically-identity matrix, same reasoning as
  // home_screen.dart's equivalent for feed posts (some devices render even
  // an identity ColorFilter with a very slight colour/gamma shift).
  Widget _withOptionalFilter(String filterType, Widget child) {
    if (filterType == 'none') return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
          kVideoFilterMatrices[filterType] ?? kVideoFilterMatrices['none']!),
      child: child,
    );
  }

  Widget _positionedOverlayText(TextOverlayData overlay) {
    final double fontSize = (overlay.isSticker ? 56 : 20) * overlay.scale;
    return IgnorePointer(
      child: Align(
        alignment: Alignment(overlay.dx * 2 - 1, overlay.dy * 2 - 1),
        child: overlay.imageUrl != null
            ? Image.network(overlay.imageUrl!,
                width: 80 * overlay.scale, height: 80 * overlay.scale)
            : overlay.isSticker
                ? Text(overlay.text, style: TextStyle(fontSize: fontSize))
                : AnimatedOverlayText(
                    text: overlay.text,
                    fontSize: fontSize,
                    color: overlay.color,
                    styleId: overlay.styleId,
                    animationId: overlay.animationId,
                  ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _next();
      });
    _loadCurrent();
  }

  Map<String, dynamic> get _current =>
      widget.stories[_index].data() as Map<String, dynamic>;

  String get _currentId => widget.stories[_index].id;

  bool get _isOwner {
    final myId = FirebaseAuth.instance.currentUser?.uid;
    return myId != null && myId == (_current['userId'] as String?);
  }

  // Listens to the current story's reactions and floats new ones (from others)
  void _subscribeReactions() {
    _reactionSub?.cancel();
    _firstReactionSnapshot = true;
    final myId = FirebaseAuth.instance.currentUser?.uid;
    _reactionSub = FirebaseFirestore.instance
        .collection('stories')
        .doc(_currentId)
        .collection('reactions')
        .snapshots()
        .listen((snap) {
      if (_firstReactionSnapshot) {
        _firstReactionSnapshot = false;
        return; // don't float existing reactions on open
      }
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added ||
            change.type == DocumentChangeType.modified) {
          final data = change.doc.data() as Map<String, dynamic>?;
          if (data == null) continue;
          // We already floated our own reaction locally
          if (data['uid'] == myId) continue;
          final type = data['type'] as String? ?? 'like';
          _spawnFloating(kStoryReactions[type] ?? '👍');
        }
      }
    });
  }

  void _spawnFloating(String emoji) {
    final item = _FloatingReaction(
      id: DateTime.now().microsecondsSinceEpoch + _rand.nextInt(1000),
      emoji: emoji,
      startXFactor: 0.15 + _rand.nextDouble() * 0.7,
    );
    setState(() => _floating.add(item));
  }

  void _removeFloating(int id) {
    _floating.removeWhere((e) => e.id == id);
    if (mounted) setState(() {});
  }

  Future<void> _loadCurrent() async {
    final int seq = ++_loadSeq;
    _progress.stop();
    _progress.reset();
    await _music.stop();
    final VideoPlayerController? old = _video;
    _video = null;
    await old?.dispose();
    _subscribeReactions();

    final data = _current;
    final String type = data['mediaType'] ?? 'image';
    final String url = data['mediaUrl'] ?? '';
    final String musicUrl = data['soundSourceUrl'] as String? ?? '';
    final double musicStart =
        (data['soundStartOffset'] as num?)?.toDouble() ?? 0;
    _hasMusic = musicUrl.isNotEmpty;
    // Started now so it runs alongside the media load: a sound that has
    // since been removed or hidden after reports must not play.
    final Future<bool> musicAllowed = _hasMusic
        ? isSoundPlayable(data['soundId'] as String? ?? '')
        : Future<bool>.value(false);

    if (type == 'video' && url.isNotEmpty) {
      // The poster's own just-uploaded story plays from the local file -
      // instant, and works before Bunny has finished encoding it.
      final File? localFile = LocalVideoCache.fileFor(url);
      final controller = localFile != null
          ? VideoPlayerController.file(localFile)
          : VideoPlayerController.networkUrl(Uri.parse(url));
      try {
        await controller.initialize();
      } catch (_) {
        await controller.dispose();
        if (!mounted || seq != _loadSeq) return;
        // Unplayable video - still let the story time out and advance.
        setState(() {});
        _progress.duration = _imageDuration;
        _progress.forward();
        return;
      }
      if (!mounted || seq != _loadSeq) {
        await controller.dispose();
        return;
      }
      final double speed = (data['videoSpeed'] as num?)?.toDouble() ?? 1.0;
      await controller.setPlaybackSpeed(speed);
      final Duration rawDuration = controller.value.duration;
      _progress.duration = rawDuration.inMilliseconds > 0
          ? Duration(milliseconds: (rawDuration.inMilliseconds / speed).round())
          : _imageDuration;

      if (_hasMusic && !await musicAllowed) {
        // Hidden sound - fall back to the video's own audio.
        _hasMusic = false;
      }
      if (!mounted || seq != _loadSeq) {
        await controller.dispose();
        return;
      }
      if (_hasMusic) {
        // Music replaces the video's own audio. Start both together.
        await controller.setVolume(0);
        await _music.load(
          musicUrl,
          startOffset: musicStart,
          clipSeconds: _progress.duration!.inMilliseconds / 1000,
          autoPlay: false,
        );
        if (!mounted || seq != _loadSeq) {
          await controller.dispose();
          return;
        }
        _music.play();
      }

      controller.play();
      setState(() => _video = controller);
      _progress.forward();
    } else {
      if (!mounted) return;
      setState(() {});
      // A photo with music stays up for a full song clip.
      _progress.duration = _hasMusic
          ? Duration(milliseconds: (kStoryMusicClipSeconds * 1000).round())
          : _imageDuration;
      _progress.forward();
      if (_hasMusic) {
        // Not awaited: the photo shows right away and the music joins in
        // as soon as it has been cleared and buffered.
        musicAllowed.then((allowed) {
          if (!mounted || seq != _loadSeq) return;
          if (!allowed) {
            _hasMusic = false;
            return;
          }
          _music.load(
            musicUrl,
            startOffset: musicStart,
            clipSeconds: kStoryMusicClipSeconds,
          );
        });
      }
    }
  }

  void _pausePlayback() {
    _progress.stop();
    _video?.pause();
    if (_hasMusic) _music.pause();
  }

  void _resumePlayback() {
    if (!mounted) return;
    _progress.forward();
    _video?.play();
    if (_hasMusic) _music.play();
  }

  // Tapping the "♪" chip opens that sound's page; the story pauses while
  // it's open and picks up where it left off on return.
  Future<void> _openSound(String soundId) async {
    if (soundId.isEmpty) return;
    _pausePlayback();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SoundScreen(soundId: soundId)),
    );
    _resumePlayback();
  }

  // Deletes the currently-shown story (only the owner ever sees the button
  // that calls this - see the build() check). Removes it from the local
  // stories list too, so the viewer can keep going through whatever's left
  // without needing to be reopened.
  Future<void> _confirmDeleteStory(BuildContext context) async {
    _pausePlayback();
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete this story?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will permanently remove this story.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true) {
      _resumePlayback();
      return;
    }

    try {
      await widget.stories[_index].reference.delete();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        _resumePlayback();
      }
      return;
    }

    if (!mounted) return;

    widget.stories.removeAt(_index);
    if (widget.stories.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (_index >= widget.stories.length) {
      _index = widget.stories.length - 1;
    }
    _loadCurrent();
  }

  void _next() {
    if (_index < widget.stories.length - 1) {
      setState(() => _index++);
      _loadCurrent();
    } else {
      Navigator.pop(context);
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _loadCurrent();
    } else {
      // Already on the first story - restart it from the beginning.
      _progress.reset();
      _progress.forward();
      _video?.seekTo(Duration.zero);
      if (_hasMusic) _music.restart();
    }
  }

  Future<void> _react(String type) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    // Immediate local float
    _spawnFloating(kStoryReactions[type] ?? '👍');
    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final pdata = profile.data();
      final String myName =
          (pdata?['displayName'] as String?)?.trim().isNotEmpty == true
              ? pdata!['displayName']
              : (user.email?.split('@').first ?? 'User');
      final String myPhoto = (pdata?['photoUrl'] as String?) ?? '';

      await FirebaseFirestore.instance
          .collection('stories')
          .doc(_currentId)
          .collection('reactions')
          .doc(user.uid)
          .set({
        'uid': user.uid,
        'type': type,
        'userName': myName,
        'userPhoto': myPhoto,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // Shows the list of accounts that reacted (for the story owner)
  void _showReactors() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161616),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.5,
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Text('Reactions',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('stories')
                        .doc(_currentId)
                        .collection('reactions')
                        .snapshots(),
                    builder: (context, snap) {
                      final docs = snap.data?.docs ?? [];
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('No reactions yet',
                              style: TextStyle(color: Colors.grey)),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, i) {
                          final r = docs[i].data() as Map<String, dynamic>;
                          final String name = r['userName'] ?? 'User';
                          final String photo = r['userPhoto'] ?? '';
                          final String emoji =
                              kStoryReactions[r['type']] ?? '👍';
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[800],
                              backgroundImage: photo.isNotEmpty
                                  ? CachedNetworkImageProvider(photo)
                                  : null,
                              child: photo.isEmpty
                                  ? Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style:
                                          const TextStyle(color: Colors.white))
                                  : null,
                            ),
                            title: Text(name,
                                style: const TextStyle(color: Colors.white)),
                            trailing: Text(emoji,
                                style: const TextStyle(fontSize: 24)),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _reactionSub?.cancel();
    _progress.dispose();
    _video?.dispose();
    _music.dispose();
    super.dispose();
  }

  // Photo story: filtered image + overlays laid out inside the image's own
  // rect (via its saved aspect ratio), so text/stickers land exactly where
  // they were placed in PhotoEffectsScreen. Legacy photo stories without an
  // aspect ratio keep the old plain BoxFit.contain display.
  Widget _buildImageStory(
    String url,
    String filterType,
    List<TextOverlayData> textOverlays,
    double? aspectRatio,
  ) {
    Widget image(BoxFit fit) => CachedNetworkImage(
          imageUrl: url,
          fit: fit,
          placeholder: (_, __) => const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
          errorWidget: (_, __, ___) => const Center(
            child: Icon(Icons.broken_image, color: Colors.white38),
          ),
        );

    if (aspectRatio == null || aspectRatio <= 0) {
      return _withOptionalFilter(filterType, image(BoxFit.contain));
    }

    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: _withOptionalFilter(filterType, image(BoxFit.cover)),
            ),
            for (final overlay in textOverlays) _positionedOverlayText(overlay),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _current;
    final String type = data['mediaType'] ?? 'image';
    final String url = data['mediaUrl'] ?? '';
    final String name = data['userName'] ?? 'User';
    final String photo = data['userPhoto'] ?? '';
    // Set for both video and photo stories (see addStory above). Older
    // photo stories posted before the photo effects step simply don't have
    // these fields and fall back to the identity defaults.
    final double? imageAspectRatio =
        (data['imageAspectRatio'] as num?)?.toDouble();
    final String filterType = data['filterType'] as String? ?? 'none';
    final List<TextOverlayData> textOverlays =
        ((data['textOverlays'] as List<dynamic>?) ?? const [])
            .map((m) => TextOverlayData.fromMap(m as Map<String, dynamic>))
            .toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (details) {
          final w = MediaQuery.of(context).size.width;
          if (details.globalPosition.dx < w / 3) {
            _prev();
          } else {
            _next();
          }
        },
        child: Stack(
          children: [
            // Media
            Positioned.fill(
              child: type == 'video'
                  ? (_video != null && _video!.value.isInitialized
                      ? Center(
                          child: AspectRatio(
                            aspectRatio: _video!.value.aspectRatio,
                            child: _withOptionalFilter(
                              filterType,
                              VideoPlayer(_video!),
                            ),
                          ),
                        )
                      : const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)))
                  : _buildImageStory(
                      url, filterType, textOverlays, imageAspectRatio),
            ),
            if (type == 'video')
              for (final overlay in textOverlays)
                _positionedOverlayText(overlay),

            // Top: progress bars + author + close
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Column(
                  children: [
                    Row(
                      children: List.generate(widget.stories.length, (i) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: _SegmentBar(
                              controller: _progress,
                              state: i < _index ? 1 : (i == _index ? 2 : 0),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Colors.grey[800],
                          backgroundImage: photo.isNotEmpty
                              ? CachedNetworkImageProvider(photo)
                              : null,
                          child: photo.isEmpty
                              ? Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13),
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 6)
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (data['userId'] ==
                            FirebaseAuth.instance.currentUser?.uid)
                          GestureDetector(
                            onTap: () => _confirmDeleteStory(context),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.delete_outline,
                                  color: Colors.white),
                            ),
                          ),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                    // "♪ Title · Owner" credit - tap to open the sound page.
                    if ((data['soundId'] as String? ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, left: 2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: StoryMusicChip(
                            title: data['soundTitle'] as String? ??
                                'Original sound',
                            ownerName: data['soundOwnerName'] as String? ?? '',
                            onTap: () =>
                                _openSound(data['soundId'] as String? ?? ''),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Floating reactions rising up (non-interactive)
            IgnorePointer(
              child: Stack(
                children: _floating.map((f) {
                  return _FloatingReactionWidget(
                    key: ValueKey(f.id),
                    data: f,
                    onDone: () => _removeFloating(f.id),
                  );
                }).toList(),
              ),
            ),

            // Bottom: reactions row (+ "who reacted" for the owner)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isOwner)
                      GestureDetector(
                        onTap: _showReactors,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('stories')
                                .doc(_currentId)
                                .collection('reactions')
                                .snapshots(),
                            builder: (context, snap) {
                              final int c =
                                  snap.hasData ? snap.data!.docs.length : 0;
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.favorite,
                                      color: Colors.white, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    'See who reacted ($c)',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: kStoryReactions.entries.map((e) {
                          return GestureDetector(
                            onTap: () => _react(e.key),
                            child: Text(
                              e.value,
                              style: const TextStyle(fontSize: 32),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// One segment of the story progress bar
class _SegmentBar extends StatelessWidget {
  final AnimationController controller;
  final int state; // 0 = upcoming (empty), 1 = done (full), 2 = current

  const _SegmentBar({required this.controller, required this.state});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: state == 2
            ? AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  return LinearProgressIndicator(
                    value: controller.value,
                    backgroundColor: Colors.white30,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                  );
                },
              )
            : Container(
                color: state == 1 ? Colors.white : Colors.white30,
              ),
      ),
    );
  }
}

// A single reaction emoji that floats up the screen and fades out
class _FloatingReaction {
  final int id;
  final String emoji;
  final double startXFactor; // 0..1 across the width

  _FloatingReaction({
    required this.id,
    required this.emoji,
    required this.startXFactor,
  });
}

class _FloatingReactionWidget extends StatefulWidget {
  final _FloatingReaction data;
  final VoidCallback onDone;

  const _FloatingReactionWidget({
    super.key,
    required this.data,
    required this.onDone,
  });

  @override
  State<_FloatingReactionWidget> createState() =>
      _FloatingReactionWidgetState();
}

class _FloatingReactionWidgetState extends State<_FloatingReactionWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final double t = _c.value;
        final double bottom = 90 + t * (size.height * 0.6);
        final double drift = sin(t * pi * 2) * 24;
        final double opacity = t < 0.75 ? 1.0 : (1.0 - (t - 0.75) / 0.25);
        final double scale = 0.7 + 0.5 * (t < 0.3 ? t / 0.3 : 1.0);
        return Positioned(
          bottom: bottom,
          left: widget.data.startXFactor * size.width + drift,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Text(widget.data.emoji, style: const TextStyle(fontSize: 34)),
    );
  }
}

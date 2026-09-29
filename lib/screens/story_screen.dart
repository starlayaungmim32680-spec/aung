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
import 'media_utils.dart' show cloudinaryThumbUrl;

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
      // Keep the untrimmed original if trimming turned a camera video the
      // wrong way round (see video_upload_service.dart).
      videoFileToUpload = await keepVideoOrientation(
        reference: trimResult.originalFile,
        candidate: trimmed,
        step: 'story trim',
      );
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
// Stories bar (Home): Facebook-style tall story CARDS, with Fly's own
// touches on top (29 Sep 2026 redesign - Ko asked for "like Facebook, but
// cooler"):
//   - each card previews the person's LATEST story (photo, or the video's
//     thumbnail) - like Facebook;
//   - the avatar in the corner keeps Fly's segmented gradient ring (one
//     segment per active story), so you see "how many" before tapping;
//   - a small glass chip shows how long ago the latest story was posted,
//     and small badges mark video (▶) and music (♪) stories;
//   - a soft pink→purple gradient frame and a press-down "squish" when
//     tapped.
// The bar keeps its old height (182), so the Home header layout above the
// feed doesn't move.
// ---------------------------------------------------------------------------
const double _kStoryCardWidth = 104;
const double _kStoryCardHeight = 166;
const double _kStoryCardRadius = 18;
const List<Color> _kFlyStoryGradient = [Color(0xFFFF4B6E), Color(0xFF9C4DFF)];

class StoriesBar extends StatefulWidget {
  const StoriesBar({super.key});

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar> {
  // Built once (Fly's stream rule) - building it in build() resubscribed
  // on every rebuild of the Home header.
  late final Stream<QuerySnapshot> _storiesStream = FirebaseFirestore.instance
      .collection('stories')
      .where('expiresAt', isGreaterThan: Timestamp.now())
      .orderBy('expiresAt', descending: true)
      .snapshots();

  @override
  Widget build(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;

    return SizedBox(
      height: 182,
      child: StreamBuilder<QuerySnapshot>(
        stream: _storiesStream,
        builder: (context, snapshot) {
          final docs = snapshot.data?.docs ?? [];
          final DateTime now = DateTime.now();

          // Group active stories by user (newest first within each user).
          final Map<String, List<QueryDocumentSnapshot>> byUser = {};
          for (final d in docs) {
            final m = d.data() as Map<String, dynamic>;
            final uid = (m['userId'] as String?) ?? '';
            if (uid.isEmpty) continue;
            // The query's `now` is fixed when the stream starts, so also
            // drop stories that have expired since.
            final Timestamp? exp = m['expiresAt'] as Timestamp?;
            if (exp != null && exp.toDate().isBefore(now)) continue;
            // A video story still being encoded is only shown to its poster.
            if (!isVideoVisibleTo(m, myId)) continue;
            byUser.putIfAbsent(uid, () => []).add(d);
          }

          // My own stories first (right after "Create story"), then others.
          final List<String> userIds = byUser.keys.toList()
            ..sort((a, b) {
              if (a == myId) return -1;
              if (b == myId) return 1;
              return 0;
            });

          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              _CreateStoryCard(onTap: () => addStory(context)),
              ...userIds.map((uid) {
                final stories = byUser[uid]!;
                final latest = stories.first.data() as Map<String, dynamic>;
                return _StoryCard(
                  key: ValueKey(uid),
                  name: uid == myId
                      ? 'Your story'
                      : (latest['userName'] as String? ?? 'User'),
                  photoUrl: latest['userPhoto'] as String? ?? '',
                  latest: latest,
                  storyCount: stories.length,
                  onTap: () {
                    // Everyone's stories, one group per person in the
                    // same order as the bar, so the viewer can move on to
                    // the next person by itself.
                    final groups = [
                      for (final u in userIds) byUser[u]!.reversed.toList(),
                    ];
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StoryViewerScreen(
                          groups: groups,
                          initialGroup: userIds.indexOf(uid),
                        ),
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

// Preview image for a story card: the photo itself, or the video's
// thumbnail. (Bunny *image* URLs must not go through cloudinaryThumbUrl -
// it would turn them into a video-thumbnail path.)
String _storyPreviewUrl(Map<String, dynamic> story) {
  final String url = (story['mediaUrl'] as String?) ?? '';
  if (url.isEmpty) return '';
  return story['mediaType'] == 'video' ? cloudinaryThumbUrl(url) : url;
}

// "now", "5m", "3h" - the story's age, shown in the card's corner chip.
String _storyAgeLabel(Map<String, dynamic> story) {
  final Timestamp? ts = story['createdAt'] as Timestamp?;
  if (ts == null) return 'now';
  final Duration age = DateTime.now().difference(ts.toDate());
  if (age.inMinutes < 1) return 'now';
  if (age.inHours < 1) return '${age.inMinutes}m';
  return '${age.inHours}h';
}

// Shrinks slightly while pressed, then springs back - the "squish".
class _PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressableScale({required this.child, required this.onTap});

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// Card shell shared by both card types: size, rounded corners and Fly's
// thin gradient frame.
class _StoryCardFrame extends StatelessWidget {
  final Widget child;
  final bool glow;
  const _StoryCardFrame({required this.child, this.glow = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kStoryCardWidth,
      height: _kStoryCardHeight,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kStoryCardRadius),
        gradient: glow
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _kFlyStoryGradient,
              )
            : null,
        color: glow ? null : Colors.white12,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: const Color(0xFF9C4DFF).withOpacity(0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_kStoryCardRadius - 1.5),
        child: child,
      ),
    );
  }
}

// "Create story" card, Facebook-style: my profile photo fills the top, a
// dark panel with "Create story" sits below, and a round gradient "+"
// button straddles the line between them.
class _CreateStoryCard extends StatefulWidget {
  final VoidCallback onTap;
  const _CreateStoryCard({required this.onTap});

  @override
  State<_CreateStoryCard> createState() => _CreateStoryCardState();
}

class _CreateStoryCardState extends State<_CreateStoryCard> {
  final String? _myId = FirebaseAuth.instance.currentUser?.uid;
  late final Stream<DocumentSnapshot>? _profileStream = _myId == null
      ? null
      : FirebaseFirestore.instance.collection('users').doc(_myId).snapshots();

  @override
  Widget build(BuildContext context) {
    const double photoHeight = 112;

    return _PressableScale(
      onTap: widget.onTap,
      child: _StoryCardFrame(
        glow: false,
        child: StreamBuilder<DocumentSnapshot>(
          stream: _profileStream,
          builder: (context, snapshot) {
            final Map<String, dynamic>? profile =
                snapshot.data?.data() as Map<String, dynamic>?;
            final String photoUrl = (profile?['photoUrl'] as String?) ?? '';

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    SizedBox(
                      height: photoHeight,
                      width: double.infinity,
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
                                  color: Colors.white38, size: 40),
                            ),
                    ),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        color: const Color(0xFF1C1C1E),
                        alignment: Alignment.bottomCenter,
                        padding: const EdgeInsets.only(bottom: 9),
                        child: const Text(
                          'Create story',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Round "+" button on the seam between photo and panel.
                Positioned(
                  top: photoHeight - 17,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: _kFlyStoryGradient,
                        ),
                        border: Border.all(
                          color: const Color(0xFF1C1C1E),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF4B6E).withOpacity(0.45),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child:
                          const Icon(Icons.add, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// One person's story card: their latest story as the background, their
// avatar with Fly's segmented ring top-left, age chip top-right, name at
// the bottom over a dark fade.
class _StoryCard extends StatelessWidget {
  final String name;
  final String photoUrl;
  final Map<String, dynamic> latest;
  final int storyCount;
  final VoidCallback onTap;

  const _StoryCard({
    super.key,
    required this.name,
    required this.photoUrl,
    required this.latest,
    required this.storyCount,
    required this.onTap,
  });

  Widget _glassBadge(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 0.6),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String previewUrl = _storyPreviewUrl(latest);
    final bool isVideo = latest['mediaType'] == 'video';
    final bool hasMusic = ((latest['soundTitle'] as String?) ?? '').isNotEmpty;

    return _PressableScale(
      onTap: onTap,
      child: _StoryCardFrame(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Latest story as the card background.
            if (previewUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: previewUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[900]),
                errorWidget: (_, __, ___) => Container(color: Colors.grey[900]),
              )
            else
              Container(color: Colors.grey[900]),
            // Dark fades top and bottom so the avatar and name stay readable
            // on any photo.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.3, 0.6, 1],
                  colors: [
                    Color(0x80000000),
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0xCC000000),
                  ],
                ),
              ),
            ),
            // Avatar with the segmented ring (one segment per story).
            Positioned(
              top: 7,
              left: 7,
              child: SizedBox(
                width: 40,
                height: 40,
                child: CustomPaint(
                  painter: _SegmentedRingPainter(
                      segments: storyCount, strokeWidth: 2.6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: CircleAvatar(
                      backgroundColor: Colors.grey[800],
                      backgroundImage: photoUrl.isNotEmpty
                          ? CachedNetworkImageProvider(photoUrl)
                          : null,
                      child: photoUrl.isEmpty
                          ? Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            // How long ago.
            Positioned(
              top: 9,
              right: 7,
              child: _glassBadge(Text(
                _storyAgeLabel(latest),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              )),
            ),
            // Name at the bottom, with small video / music badges.
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isVideo || hasMusic)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          if (isVideo)
                            _glassBadge(const Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 12)),
                          if (isVideo && hasMusic) const SizedBox(width: 4),
                          if (hasMusic)
                            _glassBadge(const Icon(Icons.music_note_rounded,
                                color: Colors.white, size: 12)),
                        ],
                      ),
                    ),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                ],
              ),
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
// Full-screen story viewer (29 Sep 2026 redesign - "like Facebook, but
// cooler"):
//   - swipe left/right between PEOPLE with a 3D cube turn; when one
//     person's stories end it moves on to the next person by itself;
//   - tap right/left = next/previous story, press-and-hold = pause (the
//     whole UI fades away so you can look at the story clean);
//   - swipe down = close;
//   - header shows name + how long ago ("3h");
//   - bottom: quick emoji reactions + a "Send message..." reply box that
//     drops the reply straight into your chat with that person (with a
//     small preview of the story) - the owner sees "See who reacted"
//     instead.
// Only the page on screen plays; neighbours just show a still preview.
// ---------------------------------------------------------------------------
class StoryViewerScreen extends StatefulWidget {
  // One list per person, each in viewing order (oldest story first).
  final List<List<QueryDocumentSnapshot>> groups;
  final int initialGroup;

  const StoryViewerScreen({
    super.key,
    required this.groups,
    this.initialGroup = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late final PageController _pages =
      PageController(initialPage: widget.initialGroup);
  late int _active = widget.initialGroup;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  // Moves to person [index]; past the last person closes the viewer.
  void _goToGroup(int index) {
    if (!mounted) return;
    if (index < 0) return;
    if (index >= widget.groups.length) {
      Navigator.of(context).maybePop();
      return;
    }
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // The reply box lifts itself above the keyboard; the story itself
      // must not shrink when the keyboard opens.
      resizeToAvoidBottomInset: false,
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.groups.length,
        onPageChanged: (i) => setState(() => _active = i),
        itemBuilder: (context, i) {
          final group = widget.groups[i];
          final String uid = ((group.first.data()
                  as Map<String, dynamic>)['userId'] as String?) ??
              '$i';
          final Widget page = _UserStoriesPage(
            key: ValueKey(uid),
            stories: group,
            isActive: i == _active,
            onFinished: () => _goToGroup(i + 1),
            onBeforeFirst: i > 0 ? () => _goToGroup(i - 1) : null,
            onClose: () => Navigator.of(context).maybePop(),
          );

          // 3D cube turn between people: each page rotates around the edge
          // it shares with its neighbour, and darkens as it turns away.
          return AnimatedBuilder(
            animation: _pages,
            child: page,
            builder: (context, child) {
              double current = _active.toDouble();
              if (_pages.hasClients && _pages.position.haveDimensions) {
                current = _pages.page ?? current;
              }
              final double delta = (i - current).clamp(-1.0, 1.0);
              if (delta == 0) return child!;
              return Transform(
                alignment:
                    delta > 0 ? Alignment.centerLeft : Alignment.centerRight,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(delta * pi / 2.2),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child!,
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black
                            .withOpacity((delta.abs() * 0.6).clamp(0.0, 0.6)),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// All the stories of ONE person (one page of the viewer above).
class _UserStoriesPage extends StatefulWidget {
  final List<QueryDocumentSnapshot> stories;
  final bool isActive;
  final VoidCallback onFinished;
  // null = this is the first person, so "back" just restarts the story.
  final VoidCallback? onBeforeFirst;
  final VoidCallback onClose;

  const _UserStoriesPage({
    super.key,
    required this.stories,
    required this.isActive,
    required this.onFinished,
    required this.onBeforeFirst,
    required this.onClose,
  });

  @override
  State<_UserStoriesPage> createState() => _UserStoriesPageState();
}

class _UserStoriesPageState extends State<_UserStoriesPage>
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
  // already moved past never starts playing over the current one.
  int _loadSeq = 0;

  // Has this page loaded its current story yet? (Pages next to the one on
  // screen are built during a swipe but only load once they're active.)
  bool _loaded = false;
  // Press-and-hold pause: hides the UI while held.
  bool _holding = false;

  // Reply box.
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  bool _sendingReply = false;

  // Wraps [child] in a ColorFiltered matrix only when a filter was actually
  // picked at upload time - skips the layer entirely for 'none' (some
  // devices render even an identity ColorFilter with a slight shift).
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
        if (status == AnimationStatus.completed && widget.isActive) _next();
      });
    _replyFocus.addListener(() {
      // Typing a reply pauses the story; leaving the box resumes it.
      if (_replyFocus.hasFocus) {
        _pausePlayback();
      } else if (!_holding) {
        _resumePlayback();
      }
      if (mounted) setState(() {});
    });
    if (widget.isActive) {
      _loaded = true;
      _loadCurrent();
    }
  }

  @override
  void didUpdateWidget(covariant _UserStoriesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      if (_loaded && _progress.isCompleted) {
        // Came back to a person whose last story had already finished -
        // replay that story instead of sitting on a full progress bar.
        _loadCurrent();
      } else if (_loaded) {
        _resumePlayback();
      } else {
        _loaded = true;
        _loadCurrent();
      }
    } else {
      _replyFocus.unfocus();
      _pausePlayback();
    }
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
    if (!mounted) return;
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
    if (!mounted || seq != _loadSeq) return;
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
        if (_canPlay) _progress.forward();
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
        if (_canPlay) _music.play();
      }

      if (_canPlay) controller.play();
      setState(() => _video = controller);
      if (_canPlay) _progress.forward();
    } else {
      if (!mounted) return;
      setState(() {});
      // A photo with music stays up for a full song clip.
      _progress.duration = _hasMusic
          ? Duration(milliseconds: (kStoryMusicClipSeconds * 1000).round())
          : _imageDuration;
      if (_canPlay) _progress.forward();
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
            autoPlay: _canPlay,
          );
        });
      }
    }
  }

  // Playback may run only on the page on screen, not while held, and not
  // while a reply is being typed.
  bool get _canPlay => widget.isActive && !_holding && !_replyFocus.hasFocus;

  void _pausePlayback() {
    _progress.stop();
    _video?.pause();
    if (_hasMusic) _music.pause();
  }

  void _resumePlayback() {
    if (!mounted || !_canPlay || !_loaded) return;
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
  // that calls this). Removes it from the local list too, so the viewer
  // keeps going through whatever's left.
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
      widget.onFinished();
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
      // This person is done - on to the next person (or close).
      _pausePlayback();
      widget.onFinished();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _loadCurrent();
    } else if (widget.onBeforeFirst != null) {
      _pausePlayback();
      widget.onBeforeFirst!();
    } else {
      // Very first story overall - restart it from the beginning.
      _progress.reset();
      if (_canPlay) _progress.forward();
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

  // Sends the reply as a normal chat message to the story's owner - the
  // same chats/{chatId}/messages path, fields and chat-list update that
  // chat_screen.dart uses - plus storyId/storyThumb so the chat bubble can
  // show which story it answers.
  Future<void> _sendReply() async {
    final User? me = FirebaseAuth.instance.currentUser;
    final String text = _replyController.text.trim();
    final String ownerId = (_current['userId'] as String?) ?? '';
    if (me == null || text.isEmpty || ownerId.isEmpty || ownerId == me.uid) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String storyThumb = _storyPreviewUrl(_current);
    final String storyId = _currentId;

    setState(() => _sendingReply = true);
    _replyController.clear();
    _replyFocus.unfocus();

    try {
      final ids = [me.uid, ownerId]..sort();
      final String chatId = '${ids[0]}_${ids[1]}';
      final chatRef =
          FirebaseFirestore.instance.collection('chats').doc(chatId);

      await chatRef.collection('messages').add({
        'senderId': me.uid,
        'type': 'text',
        'text': text,
        'storyId': storyId,
        'storyThumb': storyThumb,
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final String preview = '↩ Story reply: $text';
      await chatRef.set({
        'participants': [me.uid, ownerId],
        'lastMessage': preview,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastSenderId': me.uid,
      }, SetOptions(merge: true));

      final myProfile = await FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .get();
      final myData = myProfile.data();
      final String myName =
          (myData?['displayName'] as String?)?.trim().isNotEmpty == true
              ? myData!['displayName']
              : 'Someone';
      await FirebaseFirestore.instance
          .collection('users')
          .doc(ownerId)
          .collection('notifications')
          .add({
        'type': 'message',
        'text': preview,
        'fromId': me.uid,
        'fromName': myName,
        'fromPhoto': (myData?['photoUrl'] as String?) ?? '',
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Reply sent 💬'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't send. Please try again.")),
      );
    }
    if (mounted) setState(() => _sendingReply = false);
  }

  // Shows the list of accounts that reacted (for the story owner)
  void _showReactors() {
    _pausePlayback();
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
    ).whenComplete(_resumePlayback);
  }

  @override
  void dispose() {
    _reactionSub?.cancel();
    _progress.dispose();
    _video?.dispose();
    _music.dispose();
    _replyController.dispose();
    _replyFocus.dispose();
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

  // While a video story loads (or on a neighbouring page that isn't
  // playing yet): its thumbnail, with a spinner only on the active page.
  Widget _videoPlaceholder(String url) {
    final String thumb = cloudinaryThumbUrl(url);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb.isNotEmpty)
          CachedNetworkImage(
            imageUrl: thumb,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => const SizedBox.shrink(),
          ),
        if (widget.isActive)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
      ],
    );
  }

  Widget _replyBar() {
    final String ownerName = (_current['userName'] as String?) ?? '';
    final bool typing = _replyFocus.hasFocus;
    final double keyboard = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick reactions (hidden while typing, like Facebook).
          if (!typing)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: kStoryReactions.entries.map((e) {
                  return _PressableScale(
                    onTap: () => _react(e.key),
                    child: Text(e.value, style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color:
                            typing ? const Color(0xFFFF4B6E) : Colors.white54,
                        width: 1.2,
                      ),
                    ),
                    child: TextField(
                      controller: _replyController,
                      focusNode: _replyFocus,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: const Color(0xFFFF4B6E),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendReply(),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: ownerName.isEmpty
                            ? 'Send message...'
                            : 'Send message to $ownerName...',
                        hintStyle: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _PressableScale(
                  onTap: _sendingReply ? () {} : _sendReply,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: _kFlyStoryGradient),
                    ),
                    child: _sendingReply
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded,
                            color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final double? imageAspectRatio =
        (data['imageAspectRatio'] as num?)?.toDouble();
    final String filterType = data['filterType'] as String? ?? 'none';
    final List<TextOverlayData> textOverlays =
        ((data['textOverlays'] as List<dynamic>?) ?? const [])
            .map((m) => TextOverlayData.fromMap(m as Map<String, dynamic>))
            .toList();
    // UI (bars, header, reply box) fades out while holding to look.
    final bool showUi = !_holding;

    return Stack(
      children: [
        // Media + gestures
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              if (_replyFocus.hasFocus) {
                _replyFocus.unfocus();
                return;
              }
              final w = MediaQuery.of(context).size.width;
              if (details.globalPosition.dx < w / 3) {
                _prev();
              } else {
                _next();
              }
            },
            onLongPressStart: (_) {
              setState(() => _holding = true);
              _pausePlayback();
            },
            onLongPressEnd: (_) {
              setState(() => _holding = false);
              _resumePlayback();
            },
            // Swipe down to close.
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 400) widget.onClose();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (type == 'video')
                  (_video != null && _video!.value.isInitialized
                      ? Center(
                          child: AspectRatio(
                            aspectRatio: _video!.value.aspectRatio,
                            child: _withOptionalFilter(
                              filterType,
                              VideoPlayer(_video!),
                            ),
                          ),
                        )
                      : _videoPlaceholder(url))
                else
                  _buildImageStory(
                      url, filterType, textOverlays, imageAspectRatio),
                if (type == 'video')
                  for (final overlay in textOverlays)
                    _positionedOverlayText(overlay),
                // Soft dark fades so the header and reply box stay readable.
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0, 0.18, 0.75, 1],
                        colors: [
                          Color(0x99000000),
                          Color(0x00000000),
                          Color(0x00000000),
                          Color(0x99000000),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Top: progress bars + author + age + close
        IgnorePointer(
          ignoring: !showUi,
          child: AnimatedOpacity(
            opacity: showUi ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: SafeArea(
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
                        // Avatar with Fly's gradient ring.
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient:
                                LinearGradient(colors: _kFlyStoryGradient),
                          ),
                          child: CircleAvatar(
                            radius: 17,
                            backgroundColor: Colors.grey[800],
                            backgroundImage: photo.isNotEmpty
                                ? CachedNetworkImageProvider(photo)
                                : null,
                            child: photo.isEmpty
                                ? Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 6)
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _storyAgeLabel(data),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6)
                            ],
                          ),
                        ),
                        const Spacer(),
                        if (_isOwner)
                          GestureDetector(
                            onTap: () => _confirmDeleteStory(context),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.delete_outline,
                                  color: Colors.white),
                            ),
                          ),
                        GestureDetector(
                          onTap: widget.onClose,
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

        // Bottom: reply box + reactions, or "See who reacted" for the owner
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !showUi,
            child: AnimatedOpacity(
              opacity: showUi ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: SafeArea(
                top: false,
                child: _isOwner
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Center(
                          child: GestureDetector(
                            onTap: _showReactors,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.45),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: Colors.white24, width: 0.8),
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
                                          color: Color(0xFFFF4B6E), size: 16),
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
                        ),
                      )
                    : _replyBar(),
              ),
            ),
          ),
        ),
      ],
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

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Reaction emojis available on stories
const Map<String, String> kStoryReactions = {
  'like': '👍',
  'love': '❤️',
  'haha': '😂',
  'wow': '😮',
  'sad': '😢',
  'angry': '😡',
};

// Cloudinary config (same as the rest of the app)
const String _kCloudName = 'dwx402gy4';
const String _kUploadPreset = 'fly_unsigned';

// How long a story stays visible
const Duration kStoryLifetime = Duration(hours: 14);

// ---------------------------------------------------------------------------
// Add a story: pick a photo or video, upload to Cloudinary, create the doc
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

    final String endpoint = kind == 'image' ? 'image' : 'video';
    final Uri url = Uri.parse(
        'https://api.cloudinary.com/v1_1/$_kCloudName/$endpoint/upload');

    final bytes = await File(picked.path).readAsBytes();
    final request = http.MultipartRequest('POST', url)
      ..fields['upload_preset'] = _kUploadPreset
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: kind == 'image' ? 'story.jpg' : 'story.mp4'));

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('Upload failed: $body');
    }
    final Map<String, dynamic> data = jsonDecode(body);
    final String mediaUrl = data['secure_url'];

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
    await FirebaseFirestore.instance.collection('stories').add({
      'userId': user.uid,
      'userName': userName,
      'userPhoto': userPhoto,
      'mediaUrl': mediaUrl,
      'mediaType': kind, // 'image' or 'video'
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(kStoryLifetime)),
    });

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
          final Map<String, List<QueryDocumentSnapshot>> byUser = {};
          for (final d in docs) {
            final m = d.data() as Map<String, dynamic>;
            final uid = (m['userId'] as String?) ?? '';
            if (uid.isEmpty) continue;
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
                  mediaUrl: first['mediaUrl'] as String? ?? '',
                  mediaType: first['mediaType'] as String? ?? 'image',
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
      child: Container(
        width: 104,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.hardEdge,
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
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.none,
                    children: [
                      // My own profile photo as the card's background
                      if (photoUrl.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: photoUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: Colors.grey[850]),
                          errorWidget: (_, __, ___) =>
                              Container(color: Colors.grey[850]),
                        )
                      else
                        Container(
                          color: Colors.grey[850],
                          child: const Icon(Icons.person,
                              color: Colors.white38, size: 40),
                        ),
                      // "+" badge overlapping the seam between photo and label
                      Positioned(
                        bottom: -14,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFFF4B6E),
                              border: Border.all(
                                color: Colors.grey[900]!,
                                width: 3,
                              ),
                            ),
                            child: const Icon(Icons.add,
                                color: Colors.white, size: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 46,
                  width: double.infinity,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.only(left: 4, right: 4, top: 14),
                  child: const Text(
                    'Create Story',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
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

// Facebook-style big story card (media preview + avatar + name)
class _StoryCard extends StatelessWidget {
  final String name;
  final String photoUrl;
  final String mediaUrl;
  final String mediaType;
  final VoidCallback onTap;

  const _StoryCard({
    required this.name,
    required this.photoUrl,
    required this.mediaUrl,
    required this.mediaType,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final String bg =
        mediaType == 'video' ? _videoThumbUrl(mediaUrl) : mediaUrl;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 104,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.grey[900],
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Media preview
            if (bg.isNotEmpty)
              CachedNetworkImage(
                imageUrl: bg,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[850]),
                errorWidget: (_, __, ___) => Container(color: Colors.grey[850]),
              ),
            // Dark gradient for text legibility
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black38, Colors.transparent, Colors.black87],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
            if (mediaType == 'video')
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 34),
              ),
            // Avatar with gradient ring (top-left)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                  ),
                ),
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: photoUrl.isNotEmpty
                      ? CachedNetworkImageProvider(photoUrl)
                      : null,
                  child: photoUrl.isEmpty
                      ? Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        )
                      : null,
                ),
              ),
            ),
            // Name (bottom-left)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    _progress.stop();
    _progress.reset();
    await _video?.dispose();
    _video = null;
    _subscribeReactions();

    final data = _current;
    final String type = data['mediaType'] ?? 'image';
    final String url = data['mediaUrl'] ?? '';

    if (type == 'video' && url.isNotEmpty) {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      controller.play();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _video = controller);
      _progress.duration = controller.value.duration.inMilliseconds > 0
          ? controller.value.duration
          : _imageDuration;
      _progress.forward();
    } else {
      if (!mounted) return;
      setState(() {});
      _progress.duration = _imageDuration;
      _progress.forward();
    }
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
      _progress.reset();
      _progress.forward();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _current;
    final String type = data['mediaType'] ?? 'image';
    final String url = data['mediaUrl'] ?? '';
    final String name = data['userName'] ?? 'User';
    final String photo = data['userPhoto'] ?? '';

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
                            child: VideoPlayer(_video!),
                          ),
                        )
                      : const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)))
                  : CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.contain,
                      placeholder: (_, __) => const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                      errorWidget: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image, color: Colors.white38),
                      ),
                    ),
            ),

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
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ],
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

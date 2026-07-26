import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'home_screen.dart';
import 'upload_screen.dart';

// Shows one sound (for now always an "Original sound" taken from a user's
// own upload), lets you listen to it, and lists every video using it -
// the TikTok "sound page".
class SoundScreen extends StatefulWidget {
  final String soundId;

  const SoundScreen({super.key, required this.soundId});

  @override
  State<SoundScreen> createState() => _SoundScreenState();
}

class _SoundScreenState extends State<SoundScreen> {
  // The sound is stored as the audio of a video file, so a video
  // controller plays it - we just never render its picture.
  VideoPlayerController? _audioController;
  bool _isPreparing = false;
  bool _isPlaying = false;
  String? _loadedUrl;

  @override
  void dispose() {
    _audioController?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(String sourceUrl) async {
    if (sourceUrl.isEmpty) return;

    // Already loaded this sound - just flip play/pause.
    if (_audioController != null && _loadedUrl == sourceUrl) {
      if (_isPlaying) {
        await _audioController!.pause();
      } else {
        await _audioController!.play();
      }
      if (mounted) setState(() => _isPlaying = !_isPlaying);
      return;
    }

    setState(() => _isPreparing = true);
    try {
      await _audioController?.dispose();
      final controller = VideoPlayerController.networkUrl(Uri.parse(sourceUrl));
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _audioController = controller;
        _loadedUrl = sourceUrl;
        _isPlaying = true;
        _isPreparing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isPreparing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play this sound: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Sound', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('sounds')
            .doc(widget.soundId)
            .snapshots(),
        builder: (context, soundSnap) {
          if (!soundSnap.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            );
          }

          final data = soundSnap.data!.data() as Map<String, dynamic>?;
          if (data == null) {
            return const Center(
              child: Text('This sound is no longer available',
                  style: TextStyle(color: Colors.grey)),
            );
          }

          final String title = data['title'] ?? 'Original sound';
          final String ownerName = data['ownerName'] ?? 'Someone';
          final String sourceUrl = data['sourceUrl'] ?? '';

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .where('soundId', isEqualTo: widget.soundId)
                .snapshots(),
            builder: (context, postSnap) {
              final docs = postSnap.data?.docs ?? [];

              return Column(
                children: [
                  // ---- Header: artwork, title, owner, actions ----
                  _SoundHeader(
                    soundId: widget.soundId,
                    title: title,
                    ownerId: data['ownerId'] ?? '',
                    ownerName: ownerName,
                    sourceUrl: sourceUrl,
                    videoCount: postSnap.hasData ? docs.length : null,
                    isPlaying: _isPlaying,
                    isPreparing: _isPreparing,
                    onTogglePlay: () => _togglePlay(sourceUrl),
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  // Make a video with this sound
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          // Stop the preview so it doesn't keep playing
                          // over the upload screen.
                          if (_isPlaying) {
                            _audioController?.pause();
                            setState(() => _isPlaying = false);
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => UploadScreen(
                                presetSoundId: widget.soundId,
                                presetSoundTitle: title,
                                presetSoundOwnerName: ownerName,
                                presetSoundSourceUrl: sourceUrl,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.music_note, size: 18),
                        label: const Text('Use this sound'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 1),

                  // ---- Videos using this sound ----
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        if (postSnap.hasError) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                'Could not load videos:\n${postSnap.error}',
                                style: const TextStyle(color: Colors.redAccent),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          );
                        }
                        if (!postSnap.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                                color: Colors.redAccent),
                          );
                        }
                        if (docs.isEmpty) {
                          return const Center(
                            child: Text('No videos use this sound yet',
                                style: TextStyle(color: Colors.grey)),
                          );
                        }

                        return GridView.builder(
                          padding: const EdgeInsets.all(2),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 2,
                            mainAxisSpacing: 2,
                            childAspectRatio: 0.7,
                          ),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final post = doc.data() as Map<String, dynamic>;
                            return GestureDetector(
                              onTap: () {
                                // Stop the preview so it doesn't play over
                                // the video being opened.
                                if (_isPlaying) {
                                  _audioController?.pause();
                                  setState(() => _isPlaying = false);
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => SingleVideoScreen(
                                      postId: doc.id,
                                      userId: post['userId'] ?? '',
                                      videoUrl: post['videoUrl'] ?? '',
                                      caption: post['caption'] ?? '',
                                      userEmail:
                                          post['userEmail'] ?? 'Unknown user',
                                      videoType:
                                          (post['videoType'] as String?) ??
                                              'short',
                                    ),
                                  ),
                                );
                              },
                              child: _SoundVideoThumbnail(
                                videoUrl: post['videoUrl'] ?? '',
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// Header of the sound page - circular artwork, title with an inline play
// button, the owner with a follow button, and how many videos use it.
class _SoundHeader extends StatelessWidget {
  final String soundId;
  final String title;
  final String ownerId;
  final String ownerName;
  final String sourceUrl;
  final int? videoCount;
  final bool isPlaying;
  final bool isPreparing;
  final VoidCallback onTogglePlay;

  const _SoundHeader({
    required this.soundId,
    required this.title,
    required this.ownerId,
    required this.ownerName,
    required this.sourceUrl,
    required this.videoCount,
    required this.isPlaying,
    required this.isPreparing,
    required this.onTogglePlay,
  });

  Future<void> _toggleFollow(String myId, bool isFollowing) async {
    final firestore = FirebaseFirestore.instance;
    final followersDoc = firestore
        .collection('users')
        .doc(ownerId)
        .collection('followers')
        .doc(myId);
    final followingDoc = firestore
        .collection('users')
        .doc(myId)
        .collection('following')
        .doc(ownerId);

    if (isFollowing) {
      await followersDoc.delete();
      await followingDoc.delete();
    } else {
      await followersDoc.set({'createdAt': FieldValue.serverTimestamp()});
      await followingDoc.set({'createdAt': FieldValue.serverTimestamp()});
    }
  }

  @override
  Widget build(BuildContext context) {
    final String myId = FirebaseAuth.instance.currentUser?.uid ?? '';
    final String artUrl = _cloudinaryThumbUrl(sourceUrl);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Circular artwork with a coloured ring
          Container(
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF3AE6D0), Color(0xFF3A8DFF)],
              ),
            ),
            child: Container(
              width: 86,
              height: 86,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
              ),
              child: ClipOval(
                child: artUrl.isEmpty
                    ? const Icon(Icons.music_note,
                        color: Colors.white54, size: 34)
                    : CachedNetworkImage(
                        imageUrl: artUrl,
                        fit: BoxFit.cover,
                        placeholder: (c, u) => const Center(
                          child: Icon(Icons.music_note,
                              color: Colors.white24, size: 30),
                        ),
                        errorWidget: (c, u, e) => const Center(
                          child: Icon(Icons.music_note,
                              color: Colors.white24, size: 30),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + inline play/pause
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: isPreparing ? null : onTogglePlay,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.15),
                        ),
                        child: isPreparing
                            ? const Padding(
                                padding: EdgeInsets.all(7),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 18,
                              ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Owner avatar + name + follow
                StreamBuilder<DocumentSnapshot>(
                  stream: ownerId.isEmpty
                      ? null
                      : FirebaseFirestore.instance
                          .collection('users')
                          .doc(ownerId)
                          .snapshots(),
                  builder: (context, ownerSnap) {
                    final ownerData =
                        ownerSnap.data?.data() as Map<String, dynamic>?;
                    final String photo =
                        (ownerData?['photoUrl'] as String?) ?? '';

                    return Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: Colors.grey[800],
                          backgroundImage:
                              photo.isNotEmpty ? NetworkImage(photo) : null,
                          child: photo.isEmpty
                              ? Text(
                                  ownerName.isNotEmpty
                                      ? ownerName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 11),
                                )
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            ownerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                          ),
                        ),
                        if (ownerId.isNotEmpty && ownerId != myId) ...[
                          const SizedBox(width: 10),
                          StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('users')
                                .doc(ownerId)
                                .collection('followers')
                                .doc(myId)
                                .snapshots(),
                            builder: (context, followSnap) {
                              final bool isFollowing =
                                  followSnap.data?.exists ?? false;
                              return GestureDetector(
                                onTap: myId.isEmpty
                                    ? null
                                    : () => _toggleFollow(myId, isFollowing),
                                child: Text(
                                  isFollowing ? 'Following' : '+ Follow',
                                  style: TextStyle(
                                    color: isFollowing
                                        ? Colors.white54
                                        : Colors.redAccent,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    );
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  videoCount == null
                      ? '...'
                      : '$videoCount '
                          '${videoCount == 1 ? "video" : "videos"}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Cloudinary renders a still image from a video if you ask for an image
// extension, so a grid tile doesn't need to spin up a whole video player
// (which also tended to show a black first frame).
String _cloudinaryThumbUrl(String videoUrl) {
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

  // A trimmed upload carries its own start/end offsets, e.g.
  // "so_0,eo_15". Keeping those means asking for the very first frame,
  // which is nearly always black - so drop them before picking a frame.
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

// Still-frame thumbnail for the sound page grid
class _SoundVideoThumbnail extends StatelessWidget {
  final String videoUrl;

  const _SoundVideoThumbnail({required this.videoUrl});

  @override
  Widget build(BuildContext context) {
    final String thumbUrl = _cloudinaryThumbUrl(videoUrl);

    return Container(
      color: Colors.grey[900],
      child: thumbUrl.isEmpty
          ? const Center(
              child: Icon(Icons.videocam_off_outlined,
                  color: Colors.white24, size: 26),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: thumbUrl,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white24),
                    ),
                  ),
                  errorWidget: (context, url, error) => const Center(
                    child: Icon(Icons.videocam_off_outlined,
                        color: Colors.white24, size: 26),
                  ),
                ),
                const Positioned(
                  left: 6,
                  bottom: 6,
                  child: Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 18,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              ],
            ),
    );
  }
}

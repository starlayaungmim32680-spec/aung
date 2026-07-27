import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'media_utils.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  // Confirms and deletes one of the user's own posts
  Future<void> _confirmDelete(BuildContext context, String postId) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title:
            const Text('Delete video?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will permanently remove this video.',
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

    if (confirm == true) {
      try {
        await FirebaseFirestore.instance
            .collection('posts')
            .doc(postId)
            .delete();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video deleted')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
    }
  }

  // Confirms and removes a shared video (repost) from this profile
  Future<void> _confirmRemoveRepost(
    BuildContext context,
    String originalPostId,
    String? uid,
  ) async {
    if (uid == null) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Remove from profile?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will remove the shared video from your profile. It won\'t '
          'delete the original video.',
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
                const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await FirebaseFirestore.instance
            .collection('reposts')
            .doc('${uid}_$originalPostId')
            .delete();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed from profile')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Remove failed: $e')),
          );
        }
      }
    }
  }

  // A single stat column (value on top, label below)
  Widget _profileStat(String value, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final String email = user?.email ?? 'Unknown user';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      // Listen to this user's profile document (name + photo)
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user?.uid)
            .snapshots(),
        builder: (context, profileSnapshot) {
          final Map<String, dynamic>? profile =
              profileSnapshot.data?.data() as Map<String, dynamic>?;

          // Use saved name, or fall back to the part before "@" in the email
          final String displayName =
              (profile?['displayName'] as String?)?.trim().isNotEmpty == true
                  ? profile!['displayName']
                  : (email.contains('@') ? email.split('@').first : email);
          final String? photoUrl = profile?['photoUrl'] as String?;

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .where('userId', isEqualTo: user?.uid)
                .snapshots(),
            builder: (context, snapshot) {
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('reposts')
                    .where('sharedBy', isEqualTo: user?.uid)
                    .snapshots(),
                builder: (context, repostSnapshot) {
                  final ownDocs = snapshot.data?.docs ?? [];
                  final repostDocs = repostSnapshot.data?.docs ?? [];
                  final int postCount = ownDocs.length;

                  // Combined grid: own uploads + videos this user shared
                  // (reposts), newest first, so shared videos show up on
                  // the profile for others to see too.
                  final List<_ProfileGridItem> gridItems = [
                    for (int i = 0; i < ownDocs.length; i++)
                      _ProfileGridItem.own(ownDocs[i], i),
                    for (final d in repostDocs) _ProfileGridItem.repost(d),
                  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                  final bool isLoading = snapshot.connectionState ==
                          ConnectionState.waiting ||
                      repostSnapshot.connectionState == ConnectionState.waiting;

                  return CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              // Avatar with a gradient ring
                              Container(
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [
                                      Color(0xFFFF4B6E),
                                      Color(0xFF9C4DFF)
                                    ],
                                  ),
                                ),
                                child: CircleAvatar(
                                  radius: 44,
                                  backgroundColor: Colors.grey[850],
                                  backgroundImage:
                                      (photoUrl != null && photoUrl.isNotEmpty)
                                          ? NetworkImage(photoUrl)
                                          : null,
                                  child: (photoUrl == null || photoUrl.isEmpty)
                                      ? Text(
                                          displayName.isNotEmpty
                                              ? displayName[0].toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 36,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                email,
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 13),
                              ),
                              const SizedBox(height: 16),
                              // Edit profile button
                              OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => EditProfileScreen(
                                        currentName: displayName,
                                        currentPhotoUrl: photoUrl,
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.edit,
                                    size: 16, color: Colors.white),
                                label: const Text('Edit Profile',
                                    style: TextStyle(color: Colors.white)),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white38),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              // Stats: Posts / Followers / Following
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _profileStat('$postCount', 'Posts'),
                                  StreamBuilder<QuerySnapshot>(
                                    stream: FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(user?.uid ?? 'none')
                                        .collection('followers')
                                        .snapshots(),
                                    builder: (context, snap) {
                                      final int c = snap.hasData
                                          ? snap.data!.docs.length
                                          : 0;
                                      return _profileStat('$c', 'Followers');
                                    },
                                  ),
                                  StreamBuilder<QuerySnapshot>(
                                    stream: FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(user?.uid ?? 'none')
                                        .collection('following')
                                        .snapshots(),
                                    builder: (context, snap) {
                                      final int c = snap.hasData
                                          ? snap.data!.docs.length
                                          : 0;
                                      return _profileStat('$c', 'Following');
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              const Divider(color: Colors.white12, height: 1),
                            ],
                          ),
                        ),
                      ),
                      if (isLoading)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: CircularProgressIndicator(
                                color: Colors.redAccent),
                          ),
                        )
                      else if (gridItems.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.videocam_off_outlined,
                                    color: Colors.grey[700], size: 56),
                                const SizedBox(height: 12),
                                Text(
                                  'No posts yet',
                                  style: TextStyle(
                                      color: Colors.grey[600], fontSize: 15),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(2),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 2,
                              mainAxisSpacing: 2,
                              childAspectRatio: 0.7,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final item = gridItems[index];
                                return GestureDetector(
                                  onTap: () {
                                    if (item.isRepost) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => SingleVideoScreen(
                                            postId: item.postId,
                                            userId: item.originalUserId,
                                            videoUrl: item.videoUrl,
                                            caption: item.caption,
                                            userEmail: item.userEmail,
                                            videoType: item.videoType,
                                            repostNote: item.note,
                                            repostByName: item.sharedByName,
                                            repostByUserId: item.sharedByUserId,
                                            repostByPhoto: item.sharedByPhoto,
                                          ),
                                        ),
                                      );
                                    } else {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => UserVideoFeedScreen(
                                            userId: user?.uid ?? '',
                                            initialIndex: item.ownIndex,
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  onLongPress: () => item.isRepost
                                      ? _confirmRemoveRepost(
                                          context, item.postId, user?.uid)
                                      : _confirmDelete(context, item.postId),
                                  child: _VideoThumbnail(
                                    videoUrl: item.videoUrl,
                                    caption: item.caption,
                                    postId: item.postId,
                                    isRepost: item.isRepost,
                                  ),
                                );
                              },
                              childCount: gridItems.length,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// One tile in the profile grid: either the user's own upload, or a video
// they shared (repost). originalUserId/postId always point at the actual
// video/post so likes, comments, and views stay attributed to the original.
class _ProfileGridItem {
  final String postId;
  final String videoUrl;
  final String caption;
  final String videoType;
  final String userEmail;
  final String originalUserId;
  final bool isRepost;
  final DateTime createdAt;
  final int ownIndex;
  final String? note;
  final String? sharedByName;
  final String? sharedByUserId;
  final String? sharedByPhoto;

  _ProfileGridItem.own(QueryDocumentSnapshot doc, int index)
      : postId = doc.id,
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        userEmail = (doc.data() as Map<String, dynamic>)['userEmail'] ?? '',
        originalUserId = (doc.data() as Map<String, dynamic>)['userId'] ?? '',
        isRepost = false,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        ownIndex = index,
        note = null,
        sharedByName = null,
        sharedByUserId = null,
        sharedByPhoto = null;

  _ProfileGridItem.repost(QueryDocumentSnapshot doc)
      : postId = (doc.data() as Map<String, dynamic>)['originalPostId'] ?? '',
        videoUrl = (doc.data() as Map<String, dynamic>)['videoUrl'] ?? '',
        caption = (doc.data() as Map<String, dynamic>)['caption'] ?? '',
        videoType =
            (doc.data() as Map<String, dynamic>)['videoType'] ?? 'short',
        userEmail = (doc.data() as Map<String, dynamic>)['userEmail'] ?? '',
        originalUserId =
            (doc.data() as Map<String, dynamic>)['originalUserId'] ?? '',
        isRepost = true,
        createdAt =
            ((doc.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                    ?.toDate() ??
                DateTime.now(),
        ownIndex = -1,
        note = (doc.data() as Map<String, dynamic>)['note'] as String?,
        sharedByName =
            (doc.data() as Map<String, dynamic>)['sharedByName'] as String?,
        sharedByUserId =
            (doc.data() as Map<String, dynamic>)['sharedBy'] as String?,
        sharedByPhoto =
            (doc.data() as Map<String, dynamic>)['sharedByPhoto'] as String?;
}

// Screen for editing the profile name and photo
class EditProfileScreen extends StatefulWidget {
  final String currentName;
  final String? currentPhotoUrl;

  const EditProfileScreen({
    super.key,
    required this.currentName,
    required this.currentPhotoUrl,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  // Cloudinary configuration (image endpoint)
  static const String _cloudName = 'dwx402gy4';
  static const String _uploadPreset = 'fly_unsigned';

  late final TextEditingController _nameController;
  Uint8List? _pickedImageBytes;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // Shows a bottom sheet so the user can choose Camera or Gallery
  Future<void> _showImageSourceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.white),
                title: const Text('Take Photo',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.white),
                title: const Text('Choose from Gallery',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    try {
      final XFile? picked = await picker.pickImage(
        source: source,
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.front,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        setState(() {
          _pickedImageBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get photo: $e')),
        );
      }
    }
  }

  // Uploads the picked image to Cloudinary and returns its URL
  Future<String?> _uploadImage(Uint8List bytes) async {
    final Uri uploadUrl =
        Uri.parse('https://api.cloudinary.com/v1_1/$_cloudName/image/upload');

    final request = http.MultipartRequest('POST', uploadUrl)
      ..fields['upload_preset'] = _uploadPreset
      ..files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: 'profile.jpg'));

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception('Image upload failed: $responseBody');
    }

    final Map<String, dynamic> data = jsonDecode(responseBody);
    return data['secure_url'] as String?;
  }

  Future<void> _saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      String? photoUrl = widget.currentPhotoUrl;

      // Upload a new photo only if the user picked one
      if (_pickedImageBytes != null) {
        photoUrl = await _uploadImage(_pickedImageBytes!);
      }

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'displayName': _nameController.text.trim(),
        'photoUrl': photoUrl ?? '',
        'email': user.email,
      }, SetOptions(merge: true));

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasNewImage = _pickedImageBytes != null;
    final bool hasExistingImage =
        widget.currentPhotoUrl != null && widget.currentPhotoUrl!.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title:
            const Text('Edit Profile', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: Text(
              _isSaving ? 'Saving...' : 'Save',
              style: const TextStyle(
                  color: Colors.redAccent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Tappable avatar to pick a new photo (opens Camera / Gallery sheet)
            GestureDetector(
              onTap: _isSaving ? null : _showImageSourceSheet,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 50,
                      backgroundColor: Colors.grey[850],
                      backgroundImage: hasNewImage
                          ? MemoryImage(_pickedImageBytes!)
                          : (hasExistingImage
                              ? NetworkImage(widget.currentPhotoUrl!)
                              : null) as ImageProvider?,
                      child: (!hasNewImage && !hasExistingImage)
                          ? const Icon(Icons.person,
                              color: Colors.white, size: 50)
                          : null,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.redAccent,
                    ),
                    child: const Icon(Icons.camera_alt,
                        color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Tap photo to change',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const SizedBox(height: 28),
            // Name field
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Display Name',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Enter your name',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: Colors.grey[900],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// A single video thumbnail tile that shows the first frame of the video
class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String caption;
  final String postId;
  final bool isRepost;

  const _VideoThumbnail({
    required this.videoUrl,
    required this.caption,
    required this.postId,
    this.isRepost = false,
  });

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  @override
  Widget build(BuildContext context) {
    final String thumbUrl = cloudinaryThumbUrl(widget.videoUrl);

    return Container(
      color: Colors.grey[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumbUrl.isNotEmpty)
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
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white30, size: 30),
              ),
            )
          else
            const Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white30, size: 30),
            ),
          // TikTok-style view count (bottom-left)
          Positioned(
            left: 6,
            bottom: 6,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(widget.postId)
                  .collection('views')
                  .snapshots(),
              builder: (context, snap) {
                final int views = snap.hasData ? snap.data!.docs.length : 0;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                    const SizedBox(width: 2),
                    Text(
                      _fmtCount(views),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          // Small badge marking this as a shared video (repost)
          if (widget.isRepost)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.repeat_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Formats view counts like 1200 -> "1.2K"
String _fmtCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

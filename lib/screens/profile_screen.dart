import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';

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
              final int postCount =
                  snapshot.hasData ? snapshot.data!.docs.length : 0;

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
                                colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
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
                          Column(
                            children: [
                              Text(
                                '$postCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Posts',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 13),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const Divider(color: Colors.white12, height: 1),
                        ],
                      ),
                    ),
                  ),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child:
                            CircularProgressIndicator(color: Colors.redAccent),
                      ),
                    )
                  else if (postCount == 0)
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
                            final post = snapshot.data!.docs[index].data()
                                as Map<String, dynamic>;
                            return _VideoThumbnail(
                              videoUrl: post['videoUrl'] ?? '',
                              caption: post['caption'] ?? '',
                            );
                          },
                          childCount: postCount,
                        ),
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

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      setState(() {
        _pickedImageBytes = bytes;
      });
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
            // Tappable avatar to pick a new photo
            GestureDetector(
              onTap: _isSaving ? null : _pickImage,
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

  const _VideoThumbnail({required this.videoUrl, required this.caption});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (widget.videoUrl.isEmpty) return;
    final controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    await controller.initialize();
    await controller.seekTo(Duration.zero);
    if (mounted) {
      setState(() {
        _controller = controller;
        _isInitialized = true;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_isInitialized && _controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            )
          else
            const Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white30, size: 30),
            ),
          const Positioned(
            top: 6,
            right: 6,
            child: Icon(Icons.play_arrow, color: Colors.white, size: 18),
          ),
          if (widget.caption.isNotEmpty)
            Positioned(
              left: 4,
              right: 4,
              bottom: 4,
              child: Text(
                widget.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'trim_editor_screen.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  // Cloudinary configuration
  static const String _cloudName = 'dwx402gy4';
  static const String _uploadPreset = 'fly_unsigned';

  final TextEditingController _captionController = TextEditingController();
  Uint8List? _videoBytes;
  VideoPlayerController? _previewController;
  int? _trimStartSeconds;
  int? _trimEndSeconds;
  bool _isUploading = false;
  String? _errorMessage;

  // Which kind of video the user is posting: 'short' or 'long'.
  // null means the user hasn't chosen an upload type yet.
  String? _videoType;

  @override
  void dispose() {
    _captionController.dispose();
    _previewController?.dispose();
    super.dispose();
  }

  // Called when the user picks an upload type (Short or Video)
  Future<void> _chooseType(String type) async {
    setState(() {
      _videoType = type;
      _errorMessage = null;
    });
    await _pickAndTrimVideo();
    // If the user backed out without picking a video, return to the chooser
    if (_videoBytes == null && mounted) {
      setState(() => _videoType = null);
    }
  }

  // Resets everything back to the type chooser
  void _resetToChooser() {
    _previewController?.dispose();
    setState(() {
      _videoType = null;
      _videoBytes = null;
      _previewController = null;
      _trimStartSeconds = null;
      _trimEndSeconds = null;
      _captionController.clear();
      _errorMessage = null;
    });
  }

  Future<void> _pickAndTrimVideo() async {
    final ImagePicker picker = ImagePicker();
    final XFile? picked = await picker.pickVideo(source: ImageSource.gallery);

    if (picked == null) return;
    if (!mounted) return;

    // Open the trim editor screen and wait for the user's selected start/end
    final TrimResult? result = await Navigator.push<TrimResult>(
      context,
      MaterialPageRoute(
        builder: (context) => TrimEditorScreen(videoFile: File(picked.path)),
      ),
    );

    if (result == null) return;

    final Uint8List bytes = await result.originalFile.readAsBytes();

    await _previewController?.dispose();
    final VideoPlayerController controller =
        VideoPlayerController.file(result.originalFile);
    await controller.initialize();
    await controller.seekTo(Duration(seconds: result.startSeconds));
    controller.setLooping(true);
    controller.play();

    setState(() {
      _videoBytes = bytes;
      _previewController = controller;
      _trimStartSeconds = result.startSeconds;
      _trimEndSeconds = result.endSeconds;
      _errorMessage = null;
    });
  }

  // Inserts a Cloudinary trim transformation (so_/eo_) right after "/upload/"
  String _buildTrimmedUrl(
      String originalUrl, int startSeconds, int endSeconds) {
    const String marker = '/upload/';
    final int index = originalUrl.indexOf(marker);
    if (index == -1) return originalUrl;

    final String before = originalUrl.substring(0, index + marker.length);
    final String after = originalUrl.substring(index + marker.length);
    return '${before}so_$startSeconds,eo_$endSeconds/$after';
  }

  Future<void> _uploadPost() async {
    if (_videoBytes == null) {
      setState(() {
        _errorMessage = 'Please choose a video first';
      });
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _errorMessage = 'You must be logged in to upload';
      });
      return;
    }

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final Uri uploadUrl =
          Uri.parse('https://api.cloudinary.com/v1_1/$_cloudName/video/upload');

      final http.MultipartRequest request =
          http.MultipartRequest('POST', uploadUrl)
            ..fields['upload_preset'] = _uploadPreset
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                _videoBytes!,
                filename: 'video.mp4',
              ),
            );

      final http.StreamedResponse streamedResponse = await request.send();
      final String responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode != 200) {
        throw Exception('Cloudinary upload failed: $responseBody');
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      String videoUrl = data['secure_url'];

      // Apply trim transformation if the user selected a trim range
      if (_trimStartSeconds != null && _trimEndSeconds != null) {
        videoUrl =
            _buildTrimmedUrl(videoUrl, _trimStartSeconds!, _trimEndSeconds!);
      }

      await FirebaseFirestore.instance.collection('posts').add({
        'userId': user.uid,
        'userEmail': user.email,
        'videoUrl': videoUrl,
        'caption': _captionController.text.trim(),
        // 'short' = full-screen vertical, 'long' = landscape (YouTube style)
        'videoType': _videoType ?? 'short',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        await _previewController?.dispose();
        setState(() {
          _isUploading = false;
          _videoType = null;
          _videoBytes = null;
          _previewController = null;
          _trimStartSeconds = null;
          _trimEndSeconds = null;
          _captionController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Posted successfully!')),
        );
      }
    } catch (e) {
      setState(() {
        _isUploading = false;
        _errorMessage = 'Upload failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Upload', style: TextStyle(color: Colors.white)),
        leading: _videoType != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _isUploading ? null : _resetToChooser,
              )
            : null,
      ),
      body: _videoType == null ? _buildTypeChooser() : _buildUploadForm(),
    );
  }

  // The first screen: choose Short or Video
  Widget _buildTypeChooser() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'What do you want to post?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 28),
          _buildChoiceCard(
            type: 'short',
            icon: Icons.smartphone,
            title: 'Short Video',
            subtitle: 'Full-screen vertical (TikTok style)',
            colors: const [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
          ),
          const SizedBox(height: 18),
          _buildChoiceCard(
            type: 'long',
            icon: Icons.movie_outlined,
            title: 'Video',
            subtitle: 'Landscape (YouTube style)',
            colors: const [Color(0xFF3A8DFF), Color(0xFF1565C0)],
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceCard({
    required String type,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Color> colors,
  }) {
    return GestureDetector(
      onTap: _isUploading ? null : () => _chooseType(type),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ],
        ),
      ),
    );
  }

  // The upload form (preview + caption + post) after a type is chosen
  Widget _buildUploadForm() {
    final bool isShort = _videoType == 'short';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Small header showing the chosen mode
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  isShort ? Icons.smartphone : Icons.movie_outlined,
                  color: isShort
                      ? const Color(0xFFFF4B6E)
                      : const Color(0xFF3A8DFF),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  isShort ? 'Short Video' : 'Video',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _isUploading ? null : _resetToChooser,
                  child: const Text(
                    'Change',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _isUploading ? null : _pickAndTrimVideo,
            child: Container(
              height: 280,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
              ),
              child: _previewController != null &&
                      _previewController!.value.isInitialized
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: _previewController!.value.aspectRatio,
                        child: VideoPlayer(_previewController!),
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.video_call_outlined,
                            color: Colors.grey, size: 56),
                        SizedBox(height: 12),
                        Text(
                          'Tap to choose and trim a video',
                          style: TextStyle(color: Colors.grey, fontSize: 15),
                        ),
                      ],
                    ),
            ),
          ),
          if (_previewController != null &&
              _previewController!.value.isInitialized) ...[
            const SizedBox(height: 8),
            const Text(
              'Tap to choose a different video',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _captionController,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Write a caption...',
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
          const SizedBox(height: 20),
          if (_isUploading)
            const Column(
              children: [
                CircularProgressIndicator(color: Colors.redAccent),
                SizedBox(height: 8),
                Text('Uploading...', style: TextStyle(color: Colors.grey)),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _uploadPost,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Post',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

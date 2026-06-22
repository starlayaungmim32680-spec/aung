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

  @override
  void dispose() {
    _captionController.dispose();
    _previewController?.dispose();
    super.dispose();
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
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        await _previewController?.dispose();
        setState(() {
          _isUploading = false;
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
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
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
      ),
    );
  }
}

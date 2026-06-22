import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
  String? _videoFileName;
  bool _isUploading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final ImagePicker picker = ImagePicker();
    final XFile? picked = await picker.pickVideo(source: ImageSource.gallery);

    if (picked != null) {
      final Uint8List bytes = await picked.readAsBytes();
      setState(() {
        _videoBytes = bytes;
        _videoFileName = picked.name;
        _errorMessage = null;
      });
    }
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
                filename: _videoFileName ?? 'video.mp4',
              ),
            );

      final http.StreamedResponse streamedResponse = await request.send();
      final String responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode != 200) {
        throw Exception('Cloudinary upload failed: $responseBody');
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String videoUrl = data['secure_url'];

      await FirebaseFirestore.instance.collection('posts').add({
        'userId': user.uid,
        'userEmail': user.email,
        'videoUrl': videoUrl,
        'caption': _captionController.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _isUploading = false;
          _videoBytes = null;
          _videoFileName = null;
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
              onTap: _isUploading ? null : _pickVideo,
              child: Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _videoFileName != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle,
                              color: Colors.greenAccent, size: 48),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              _videoFileName!,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Tap to choose a different video',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.video_call_outlined,
                              color: Colors.grey, size: 56),
                          SizedBox(height: 12),
                          Text(
                            'Tap to choose a video',
                            style: TextStyle(color: Colors.grey, fontSize: 15),
                          ),
                        ],
                      ),
              ),
            ),
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

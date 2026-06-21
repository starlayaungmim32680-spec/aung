import 'package:flutter/material.dart';

class UploadScreen extends StatelessWidget {
  const UploadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Upload', style: TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_upload_outlined,
                color: Colors.grey, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Tap to upload a video or photo',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                // Upload logic to be added with Cloudinary
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              ),
              child: const Text('Choose File'),
            ),
          ],
        ),
      ),
    );
  }
}

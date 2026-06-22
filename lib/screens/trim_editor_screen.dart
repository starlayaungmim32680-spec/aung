import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_editor/video_editor.dart';

class TrimResult {
  final File originalFile;
  final int startSeconds;
  final int endSeconds;

  TrimResult({
    required this.originalFile,
    required this.startSeconds,
    required this.endSeconds,
  });
}

class TrimEditorScreen extends StatefulWidget {
  final File videoFile;

  const TrimEditorScreen({super.key, required this.videoFile});

  @override
  State<TrimEditorScreen> createState() => _TrimEditorScreenState();
}

class _TrimEditorScreenState extends State<TrimEditorScreen> {
  late VideoEditorController _controller;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = VideoEditorController.file(
      widget.videoFile,
      minDuration: const Duration(seconds: 1),
      maxDuration: const Duration(seconds: 90),
    );
    _initializeController();
  }

  Future<void> _initializeController() async {
    try {
      await _controller.initialize();
      setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load video: $e';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirmTrim() {
    final int startSeconds =
        (_controller.startTrim.inMilliseconds / 1000).round();
    final int endSeconds = (_controller.endTrim.inMilliseconds / 1000).round();

    Navigator.pop(
      context,
      TrimResult(
        originalFile: widget.videoFile,
        startSeconds: startSeconds,
        endSeconds: endSeconds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.initialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _errorMessage != null
              ? Text(_errorMessage!,
                  style: const TextStyle(color: Colors.redAccent))
              : const CircularProgressIndicator(color: Colors.redAccent),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Trim Video', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _confirmTrim,
            child: const Text(
              'Done',
              style: TextStyle(
                  color: Colors.redAccent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: CropGridViewer.preview(controller: _controller),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: TrimSlider(
              controller: _controller,
              height: 60,
              horizontalMargin: 20,
              child: TrimTimeline(
                  controller: _controller,
                  padding: const EdgeInsets.only(top: 10)),
            ),
          ),
        ],
      ),
    );
  }
}

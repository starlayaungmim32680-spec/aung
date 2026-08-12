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
import 'video_effects_screen.dart';
import 'text_overlay_style.dart';
import 'face_filter_camera_screen.dart';

class UploadScreen extends StatefulWidget {
  // When opened from a sound page via "Use this sound", these carry the
  // sound to lay over the new video instead of its own audio.
  final String? presetSoundId;
  final String? presetSoundTitle;
  final String? presetSoundOwnerName;
  final String? presetSoundSourceUrl;

  const UploadScreen({
    super.key,
    this.presetSoundId,
    this.presetSoundTitle,
    this.presetSoundOwnerName,
    this.presetSoundSourceUrl,
  });

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
  double _videoSpeed = 1.0;
  String _filterType = 'none';
  List<TextOverlayData> _textOverlays = [];
  bool _isUploading = false;
  // 0.0 - 1.0 while the video is being sent to Cloudinary
  double _uploadProgress = 0;
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
      _videoSpeed = 1.0;
      _filterType = 'none';
      _textOverlays = [];
      _captionController.clear();
      _errorMessage = null;
    });
  }

  // Asks the user whether to record a new video or pick one from the
  // gallery, then returns the picked file (or null if cancelled).
  Future<XFile?> _pickVideoFile() async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading:
                    const Icon(Icons.videocam_rounded, color: Colors.white),
                title: const Text('Record a video',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined,
                    color: Colors.white),
                title: const Text('Choose from gallery',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (source == null) return null;
    if (source == ImageSource.camera) {
      // Custom camera screen with live face-filter preview (Phase 1 —
      // filters show live while recording but aren't baked into the saved
      // video file yet; see face_filter_camera_screen.dart).
      final XFile? recorded = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(builder: (_) => const FaceFilterCameraScreen()),
      );
      return recorded;
    }
    final ImagePicker picker = ImagePicker();
    return picker.pickVideo(source: source);
  }

  Future<void> _pickAndTrimVideo() async {
    final XFile? picked = await _pickVideoFile();

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

    // Let the user pick a speed, a color filter, and place any text
    // overlays before moving on to the caption screen.
    final VideoEffectsResult? effects =
        await Navigator.push<VideoEffectsResult>(
      context,
      MaterialPageRoute(
        builder: (context) => VideoEffectsScreen(
          videoFile: result.originalFile,
          startSeconds: result.startSeconds,
        ),
      ),
    );

    if (effects == null) return;

    final Uint8List bytes = await result.originalFile.readAsBytes();

    await _previewController?.dispose();
    final VideoPlayerController controller =
        VideoPlayerController.file(result.originalFile);
    await controller.initialize();
    await controller.seekTo(Duration(seconds: result.startSeconds));
    controller.setLooping(true);
    controller.setPlaybackSpeed(effects.speed);
    controller.play();

    setState(() {
      _videoBytes = bytes;
      _previewController = controller;
      _trimStartSeconds = result.startSeconds;
      _trimEndSeconds = result.endSeconds;
      _videoSpeed = effects.speed;
      _filterType = effects.filterType;
      _textOverlays = effects.textOverlays;
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

  // Pulls the Cloudinary public id out of a delivery URL, e.g.
  // ".../upload/so_0,eo_15/v1784906524/scfmvz1oo1zs9tttppd3.mp4"
  // -> "scfmvz1oo1zs9tttppd3". That id is what an audio overlay needs.
  String _publicIdFromUrl(String url) {
    if (url.isEmpty) return '';
    final String path = url.split('?').first;
    final String last = path.split('/').last;
    final int dot = last.lastIndexOf('.');
    return dot > 0 ? last.substring(0, dot) : last;
  }

  // Replaces the new video's own audio with the chosen sound, entirely on
  // Cloudinary's side - "ac_none" drops the original audio track and the
  // audio layer adds the borrowed one on top.
  String _buildSoundUrl(String videoUrl, String soundPublicId) {
    if (soundPublicId.isEmpty) return videoUrl;
    const String marker = '/upload/';
    final int index = videoUrl.indexOf(marker);
    if (index == -1) return videoUrl;

    final String before = videoUrl.substring(0, index + marker.length);
    final String after = videoUrl.substring(index + marker.length);
    return '${before}ac_none/l_audio:$soundPublicId/fl_layer_apply/$after';
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
      _uploadProgress = 0;
      _errorMessage = null;
    });

    final http.Client client = http.Client();
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

      // Send the body ourselves so the bytes can be counted on the way
      // out - MultipartRequest.send() gives no progress at all, which
      // made big uploads look like the app had frozen.
      //
      // finalize() must come first: that's where MultipartRequest sets
      // its "multipart/form-data; boundary=..." content-type header, and
      // without that header the server can't parse the body at all.
      final http.ByteStream bodyStream = request.finalize();
      final int totalBytes = request.contentLength;
      int sentBytes = 0;

      final http.StreamedRequest streamed =
          http.StreamedRequest('POST', uploadUrl)
            ..headers.addAll(request.headers)
            ..contentLength = totalBytes;

      bodyStream.listen(
        (List<int> chunk) {
          streamed.sink.add(chunk);
          sentBytes += chunk.length;
          if (mounted && totalBytes > 0) {
            setState(() => _uploadProgress = sentBytes / totalBytes);
          }
        },
        onDone: () => streamed.sink.close(),
        onError: (Object e) => streamed.sink.addError(e),
        cancelOnError: true,
      );

      final http.StreamedResponse streamedResponse =
          await client.send(streamed);
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

      // Look up the uploader's display name so the sound can be
      // credited to them ("Original sound - Aung") wherever it's reused.
      String ownerName = user.email?.split('@').first ?? 'User';
      try {
        final profile = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final profileData = profile.data();
        final String? displayName = profileData?['displayName'] as String?;
        if (displayName != null && displayName.trim().isNotEmpty) {
          ownerName = displayName.trim();
        }
      } catch (_) {
        // Keep the fallback name
      }

      final postRef = FirebaseFirestore.instance.collection('posts').doc();

      final String? borrowedSoundId = widget.presetSoundId;
      final bool usingBorrowedSound =
          borrowedSoundId != null && borrowedSoundId.isNotEmpty;

      String soundId;
      String soundTitle;
      String soundOwnerName;

      if (usingBorrowedSound) {
        // Swap this video's audio for the borrowed sound, and credit the
        // sound to whoever it originally came from.
        final String soundPublicId =
            _publicIdFromUrl(widget.presetSoundSourceUrl ?? '');
        videoUrl = _buildSoundUrl(videoUrl, soundPublicId);

        soundId = borrowedSoundId;
        soundTitle = widget.presetSoundTitle ?? 'Original sound';
        soundOwnerName = widget.presetSoundOwnerName ?? '';
      } else {
        // A fresh upload also becomes a reusable sound of its own. The
        // sound doc shares the post's id so the two are easy to match up.
        soundId = postRef.id;
        soundTitle = 'Original sound';
        soundOwnerName = ownerName;

        await FirebaseFirestore.instance
            .collection('sounds')
            .doc(postRef.id)
            .set({
          'ownerId': user.uid,
          'ownerName': ownerName,
          'title': 'Original sound',
          // The video this audio comes from - reusing the sound means
          // taking the audio track off this URL.
          'sourceUrl': videoUrl,
          'sourcePostId': postRef.id,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      final String captionText = _captionController.text.trim();
      // Lowercased so hashtag lookups are case-insensitive; the caption
      // itself (with original casing) is still stored separately above.
      final List<String> hashtags = RegExp(r'#([\p{L}\p{N}_]+)', unicode: true)
          .allMatches(captionText)
          .map((m) => m.group(1)!.toLowerCase())
          .toSet()
          .toList();

      await postRef.set({
        'userId': user.uid,
        'userEmail': user.email,
        'videoUrl': videoUrl,
        'caption': captionText,
        'hashtags': hashtags,
        // 'short' = full-screen vertical, 'long' = landscape (YouTube style)
        'videoType': _videoType ?? 'short',
        'videoSpeed': _videoSpeed,
        'filterType': _filterType,
        'textOverlays': _textOverlays.map((o) => o.toMap()).toList(),
        'soundId': soundId,
        'soundTitle': soundTitle,
        'soundOwnerName': soundOwnerName,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        await _previewController?.dispose();
        setState(() {
          _isUploading = false;
          _uploadProgress = 0;
          _videoType = null;
          _videoBytes = null;
          _previewController = null;
          _trimStartSeconds = null;
          _trimEndSeconds = null;
          _videoSpeed = 1.0;
          _filterType = 'none';
          _textOverlays = [];
          _captionController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Posted successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = 0;
          _errorMessage = 'Upload failed: $e';
        });
      }
    } finally {
      client.close();
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
      body: Column(
        children: [
          // Shown when this screen was opened via "Use this sound"
          if (widget.presetSoundId != null && widget.presetSoundId!.isNotEmpty)
            Container(
              width: double.infinity,
              color: const Color(0xFF1E1E1E),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.music_note,
                      color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            widget.presetSoundTitle ?? 'Original sound',
                            widget.presetSoundOwnerName ?? '',
                          ].where((s) => s.isNotEmpty).join(' - '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(
                          'This sound will replace your video\'s audio',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child:
                _videoType == null ? _buildTypeChooser() : _buildUploadForm(),
          ),
        ],
      ),
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
            subtitle: 'Full-screen vertical',
            colors: const [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
          ),
          const SizedBox(height: 18),
          _buildChoiceCard(
            type: 'long',
            icon: Icons.movie_outlined,
            title: 'Video',
            subtitle: 'Landscape',
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
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                ColorFiltered(
                                  colorFilter: ColorFilter.matrix(
                                      kVideoFilterMatrices[_filterType]!),
                                  child: VideoPlayer(_previewController!),
                                ),
                                for (final overlay in _textOverlays)
                                  Align(
                                    alignment: Alignment(
                                        overlay.dx * 2 - 1, overlay.dy * 2 - 1),
                                    child: overlay.imageUrl != null
                                        ? Image.network(overlay.imageUrl!,
                                            width: 70 * overlay.scale,
                                            height: 70 * overlay.scale)
                                        : overlay.isSticker
                                            ? Text(overlay.text,
                                                style: TextStyle(
                                                    fontSize:
                                                        48 * overlay.scale))
                                            : AnimatedOverlayText(
                                                text: overlay.text,
                                                fontSize: 18 * overlay.scale,
                                                color: overlay.color,
                                                styleId: overlay.styleId,
                                                animationId:
                                                    overlay.animationId,
                                              ),
                                  ),
                              ],
                            );
                          },
                        ),
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
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    // Null until the first chunk goes out, so the bar
                    // animates instead of sitting at a dead 0%.
                    value: _uploadProgress > 0 ? _uploadProgress : null,
                    minHeight: 8,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.redAccent),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _uploadProgress > 0
                      ? 'Uploading... ${(_uploadProgress * 100).toStringAsFixed(0)}%'
                      : 'Preparing...',
                  style: const TextStyle(color: Colors.grey),
                ),
                if (_uploadProgress >= 1) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Finishing up...',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
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

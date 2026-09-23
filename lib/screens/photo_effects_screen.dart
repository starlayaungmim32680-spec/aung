import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'video_effects_screen.dart';
import 'text_overlay_style.dart';
import 'story_music.dart';

// Photo-story equivalent of VideoEffectsScreen: color filter + text/sticker
// overlays on a still image. Nothing is baked into the pixels - the
// original photo is uploaded untouched and the filter name + overlay list
// are stored on the story doc (same fields a video story uses), so the
// viewer can reproduce the look, including looping text animations.
class PhotoEffectsResult {
  final String filterType;
  final List<TextOverlayData> textOverlays;
  // width / height of the photo as displayed (EXIF orientation applied).
  // Saved on the story so the viewer can lay overlays out over the exact
  // same image rect the editor used.
  final double aspectRatio;
  // Optional background music (a sound from the sounds library), or null.
  final StoryMusicSelection? music;

  PhotoEffectsResult({
    required this.filterType,
    required this.textOverlays,
    required this.aspectRatio,
    this.music,
  });
}

// Display names for the shared filter presets in kVideoFilterMatrices.
String photoFilterLabel(String id) {
  switch (id) {
    case 'warm':
      return 'Warm';
    case 'cool':
      return 'Cool';
    case 'bw':
      return 'B&W';
    case 'vintage':
      return 'Vintage';
    case 'none':
    default:
      return 'Normal';
  }
}

class PhotoEffectsScreen extends StatefulWidget {
  final File imageFile;

  const PhotoEffectsScreen({super.key, required this.imageFile});

  @override
  State<PhotoEffectsScreen> createState() => _PhotoEffectsScreenState();
}

class _PhotoEffectsScreenState extends State<PhotoEffectsScreen> {
  Uint8List? _bytes;
  double? _aspectRatio;
  String? _loadError;

  // Filter lives in a ValueNotifier so switching filters only rebuilds the
  // image layer and the filter strip, not the overlays or the whole page.
  final ValueNotifier<String> _filter = ValueNotifier<String>('none');
  final List<TextOverlayData> _overlays = [];

  // Background music preview - plays the chosen 15s window on a loop.
  StoryMusicSelection? _music;
  final StoryMusicPlayer _musicPlayer = StoryMusicPlayer();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Uint8List bytes = await widget.imageFile.readAsBytes();
      // Full decode (not just the header) so EXIF rotation is applied and
      // the ratio matches what Image / CachedNetworkImage will actually show.
      final ui.Image decoded = await decodeImageFromList(bytes);
      final double ratio = decoded.width / decoded.height;
      decoded.dispose();
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _aspectRatio = ratio;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = 'Could not open this photo');
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    _musicPlayer.dispose();
    super.dispose();
  }

  // ---- Music ----

  Future<void> _pickMusic() async {
    // The library screen has its own preview player - silence ours first.
    await _musicPlayer.pause();
    if (!mounted) return;
    final StoryMusicSelection? picked =
        await pickStoryMusic(context, clipSeconds: kStoryMusicClipSeconds);
    if (!mounted) return;
    if (picked == null) {
      // Backed out - keep (and resume) whatever was selected before.
      if (_music != null) _musicPlayer.play();
      return;
    }
    setState(() => _music = picked);
    _musicPlayer.load(
      picked.sourceUrl,
      startOffset: picked.startOffset,
      clipSeconds: kStoryMusicClipSeconds,
    );
  }

  void _removeMusic() {
    _musicPlayer.pause();
    setState(() => _music = null);
  }

  // ---- Overlays ----

  Future<void> _addTextOverlay() async {
    final Map<String, dynamic>? result =
        await showTextOverlayDialog(context, title: 'Add text');
    if (!mounted) return;
    final String? text = result?['text'] as String?;
    if (text == null || text.isEmpty) return;
    setState(() {
      _overlays.add(TextOverlayData(
        text: text,
        color: result?['color'] as Color? ?? Colors.white,
        styleId: result?['styleId'] as String? ?? 'classic',
        animationId: result?['animationId'] as String? ?? 'none',
      ));
    });
  }

  Future<void> _editTextOverlay(int index) async {
    final TextOverlayData overlay = _overlays[index];
    final Map<String, dynamic>? result = await showTextOverlayDialog(
      context,
      title: 'Edit text',
      initialText: overlay.text,
      initialColor: overlay.color,
      initialStyle: overlay.styleId,
      initialAnimation: overlay.animationId,
      showDelete: true,
    );
    if (!mounted || result == null) return;
    setState(() {
      if (result['delete'] == true) {
        _overlays.removeAt(index);
        return;
      }
      final String? text = result['text'] as String?;
      if (text == null || text.isEmpty) return;
      overlay.text = text;
      overlay.color = result['color'] as Color? ?? overlay.color;
      overlay.styleId = result['styleId'] as String? ?? overlay.styleId;
      overlay.animationId =
          result['animationId'] as String? ?? overlay.animationId;
    });
  }

  Future<void> _addSticker() async {
    final Object? result = await showOverlayStickerPicker(context);
    if (!mounted || result == null) return;
    setState(() {
      if (result is KlipyStickerResult) {
        _overlays.add(TextOverlayData(
          text: '',
          isSticker: true,
          imageUrl: result.fullUrl,
        ));
      } else if (result is String) {
        _overlays.add(TextOverlayData(text: result, isSticker: true));
      }
    });
  }

  void _confirm() {
    if (_aspectRatio == null) return;
    _musicPlayer.pause();
    Navigator.pop(
      context,
      PhotoEffectsResult(
        filterType: _filter.value,
        textOverlays: List<TextOverlayData>.of(_overlays),
        aspectRatio: _aspectRatio!,
        music: _music,
      ),
    );
  }

  // ---- Building blocks ----

  // Skips the ColorFiltered layer entirely for 'none' (same as the story
  // viewer) so the editor preview never shows an identity-matrix tint.
  Widget _filtered(String filterType, Widget child) {
    if (filterType == 'none') return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
          kVideoFilterMatrices[filterType] ?? kVideoFilterMatrices['none']!),
      child: child,
    );
  }

  Widget _buildDraggableOverlay(int index, double width, double height) {
    final TextOverlayData overlay = _overlays[index];
    double gestureStartScale = overlay.scale;
    final double fontSize = (overlay.isSticker ? 56 : 20) * overlay.scale;

    return Align(
      alignment: Alignment(overlay.dx * 2 - 1, overlay.dy * 2 - 1),
      child: GestureDetector(
        onScaleStart: (_) => gestureStartScale = overlay.scale,
        onScaleUpdate: (details) {
          setState(() {
            overlay.dx = (overlay.dx + details.focalPointDelta.dx / width)
                .clamp(0.0, 1.0);
            overlay.dy = (overlay.dy + details.focalPointDelta.dy / height)
                .clamp(0.0, 1.0);
            overlay.scale = (gestureStartScale * details.scale).clamp(0.4, 4.0);
          });
        },
        onTap: overlay.isSticker ? null : () => _editTextOverlay(index),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            overlay.imageUrl != null
                ? Image.network(overlay.imageUrl!,
                    width: 80 * overlay.scale, height: 80 * overlay.scale)
                : overlay.isSticker
                    ? Text(overlay.text, style: TextStyle(fontSize: fontSize))
                    : AnimatedOverlayText(
                        text: overlay.text,
                        fontSize: fontSize,
                        color: overlay.color,
                        styleId: overlay.styleId,
                        animationId: overlay.animationId,
                      ),
            Positioned(
              top: -10,
              right: -10,
              child: GestureDetector(
                onTap: () => setState(() => _overlays.removeAt(index)),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterStrip() {
    return SizedBox(
      height: 96,
      child: ValueListenableBuilder<String>(
        valueListenable: _filter,
        builder: (context, current, _) {
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: kVideoFilterMatrices.keys.map((name) {
              final bool isActive = current == name;
              return GestureDetector(
                onTap: () => _filter.value = name,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Column(
                    children: [
                      Container(
                        width: 58,
                        height: 70,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isActive
                                ? const Color(0xFFFF4B6E)
                                : Colors.white24,
                            width: isActive ? 2 : 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          // Same MemoryImage as the main preview, so every
                          // thumbnail reuses one decoded image.
                          child: _filtered(
                            name,
                            Image.memory(
                              _bytes!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        photoFilterLabel(name),
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white60,
                          fontSize: 11,
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onPressed,
      {bool active = false}) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon,
            size: 18, color: active ? const Color(0xFFFF4B6E) : Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          side: BorderSide(
              color: active ? const Color(0xFFFF4B6E) : Colors.white24),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(
          child: Text(_loadError!, style: const TextStyle(color: Colors.white)),
        ),
      );
    }

    if (_bytes == null || _aspectRatio == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.redAccent),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title:
            const Text('Photo effects', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _confirm,
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
          if (_music != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: StoryMusicChip(
                title: _music!.title,
                ownerName: _music!.ownerName,
                onTap: _pickMusic,
                onRemove: _removeMusic,
              ),
            ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspectRatio!,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // Image layer: isolated so overlay drags don't
                        // repaint it, and only filter changes rebuild it.
                        RepaintBoundary(
                          child: ValueListenableBuilder<String>(
                            valueListenable: _filter,
                            builder: (context, filterType, _) => _filtered(
                              filterType,
                              Image.memory(
                                _bytes!,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                        for (int i = 0; i < _overlays.length; i++)
                          _buildDraggableOverlay(
                              i, constraints.maxWidth, constraints.maxHeight),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          if (_overlays.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                'Drag to move • pinch to resize • tap text to edit',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
          _buildFilterStrip(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _toolButton(Icons.text_fields, 'Text', _addTextOverlay),
                  const SizedBox(width: 8),
                  _toolButton(
                      Icons.emoji_emotions_outlined, 'Sticker', _addSticker),
                  const SizedBox(width: 8),
                  _toolButton(Icons.music_note, 'Music', _pickMusic,
                      active: _music != null),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

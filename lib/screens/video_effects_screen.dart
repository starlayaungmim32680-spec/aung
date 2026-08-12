import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'text_overlay_style.dart';

// One piece of text (or a big emoji "sticker") placed on top of the video.
// Position is stored as a fraction (0.0-1.0) of the video's width/height so
// it lines up correctly wherever the video is later displayed, at any
// screen size.
class TextOverlayData {
  String text;
  double dx;
  double dy;
  // true for an emoji sticker (rendered bigger, no background chip);
  // false for a regular caption-style text overlay.
  bool isSticker;
  // Pinch-to-resize multiplier, applied on top of the base font size.
  double scale;
  // When set, this is a Klipy sticker (GIF/PNG image) instead of an emoji
  // or text — rendered as a network image, not as Text.
  String? imageUrl;
  // Text fill color (only used for non-sticker text overlays). Text is
  // always drawn with a black outline too, so any color stays readable
  // without needing a solid background chip.
  Color color;
  // Visual preset (classic/background/shadow/neon/impact/gradient) - see
  // text_overlay_style.dart. Only used for non-sticker text overlays.
  String styleId;
  // Looping entrance/exit animation (none/fadeInOut/blink/typewriter/
  // bounceIn/slideUp) - see text_overlay_style.dart. Only used for
  // non-sticker text overlays.
  String animationId;

  TextOverlayData({
    required this.text,
    this.dx = 0.5,
    this.dy = 0.5,
    this.isSticker = false,
    this.scale = 1.0,
    this.imageUrl,
    this.color = Colors.white,
    this.styleId = 'classic',
    this.animationId = 'none',
  });

  Map<String, dynamic> toMap() => {
        'text': text,
        'dx': dx,
        'dy': dy,
        'isSticker': isSticker,
        'scale': scale,
        'imageUrl': imageUrl,
        'color': color.value,
        'styleId': styleId,
        'animationId': animationId,
      };

  static TextOverlayData fromMap(Map<String, dynamic> map) => TextOverlayData(
        text: map['text'] as String? ?? '',
        dx: (map['dx'] as num?)?.toDouble() ?? 0.5,
        dy: (map['dy'] as num?)?.toDouble() ?? 0.5,
        isSticker: map['isSticker'] as bool? ?? false,
        scale: (map['scale'] as num?)?.toDouble() ?? 1.0,
        imageUrl: map['imageUrl'] as String?,
        color: map['color'] != null ? Color(map['color'] as int) : Colors.white,
        styleId: map['styleId'] as String? ?? 'classic',
        animationId: map['animationId'] as String? ?? 'none',
      );
}

// ---- Klipy sticker search (free GIF/sticker API) ----
// Get your own key from https://partner.klipy.com → API Keys, then paste it
// below. Never commit a real key to a public repo.
const String kKlipyApiKey =
    'TkCEKW9gkdq9CGw75RkfwTXkfy2j3S7gjIOABGwe1jqEjd4yvfefd9hqN3DPzmmi';

class KlipyStickerResult {
  final String previewUrl; // shown in the picker grid
  final String fullUrl; // used as the actual overlay on the video

  KlipyStickerResult({required this.previewUrl, required this.fullUrl});
}

// Klipy nests each sticker's image formats a few levels deep and the exact
// key names can vary by result, so rather than hard-coding one path, this
// walks the JSON looking for any "url" value — the first one found is used
// as the preview, and if a second is found it's used as the full-size image
// (falls back to the same url for both if only one is present).
List<String> _findAllUrls(dynamic node, [List<String>? acc]) {
  final List<String> urls = acc ?? [];
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key == 'url' && entry.value is String) {
        urls.add(entry.value as String);
      } else {
        _findAllUrls(entry.value, urls);
      }
    }
  } else if (node is List) {
    for (final item in node) {
      _findAllUrls(item, urls);
    }
  }
  return urls;
}

Future<List<KlipyStickerResult>> searchKlipyStickers(String query) async {
  if (kKlipyApiKey == 'PASTE_YOUR_KLIPY_API_KEY_HERE') return [];
  try {
    final Uri uri = Uri.parse(
      'https://api.klipy.com/api/v1/$kKlipyApiKey/stickers/search'
      '?page=1&per_page=24&q=${Uri.encodeQueryComponent(query)}'
      '&customer_id=fly_app&content_filter=medium',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return [];

    final decoded = jsonDecode(response.body);
    // Klipy wraps results as {"result": true, "data": {"data": [...] }}
    // in most of their APIs - try a few likely shapes defensively.
    List<dynamic> items = [];
    if (decoded is Map) {
      final data = decoded['data'];
      if (data is Map && data['data'] is List) {
        items = data['data'] as List;
      } else if (data is List) {
        items = data;
      } else if (decoded['results'] is List) {
        items = decoded['results'] as List;
      }
    }

    final List<KlipyStickerResult> stickers = [];
    for (final item in items) {
      final List<String> urls = _findAllUrls(item);
      if (urls.isEmpty) continue;
      stickers.add(KlipyStickerResult(
        previewUrl: urls.first,
        fullUrl: urls.length > 1 ? urls[1] : urls.first,
      ));
    }
    return stickers;
  } catch (_) {
    return [];
  }
}

// A large, curated set of emoji offered as "stickers" — no account, API
// key, or network access needed, since these render straight from the
// phone's own built-in emoji font.
const List<String> kStickerEmojis = [
  '😀',
  '😂',
  '🤣',
  '😍',
  '😘',
  '😜',
  '🤩',
  '🥳',
  '😎',
  '🤔',
  '😴',
  '😭',
  '😡',
  '🥺',
  '😱',
  '🤯',
  '🥶',
  '🤗',
  '🙄',
  '😏',
  '👍',
  '👎',
  '👏',
  '🙌',
  '🤝',
  '🙏',
  '💪',
  '✌️',
  '🤞',
  '👌',
  '❤️',
  '🧡',
  '💛',
  '💚',
  '💙',
  '💜',
  '🖤',
  '🤍',
  '💕',
  '💔',
  '🔥',
  '✨',
  '⭐',
  '🌟',
  '💯',
  '💥',
  '🎉',
  '🎊',
  '🎈',
  '🎁',
  '😻',
  '🐶',
  '🐱',
  '🐼',
  '🦄',
  '🐸',
  '🐷',
  '🦋',
  '🌈',
  '☀️',
  '🌙',
  '⚡',
  '💧',
  '❄️',
  '🍀',
  '🌸',
  '🍕',
  '🍔',
  '🍟',
  '🍩',
  '☕',
  '🍺',
  '🎵',
  '🎶',
  '🎤',
  '🎧',
  '📸',
  '🎬',
  '⚽',
  '🏆',
  '💰',
  '💎',
  '👑',
  '🚀',
  '⏰',
  '📍',
  '💡',
  '❗',
  '❓',
  '💬',
];

class VideoEffectsResult {
  final double speed;
  final String filterType;
  final List<TextOverlayData> textOverlays;

  VideoEffectsResult({
    required this.speed,
    required this.filterType,
    required this.textOverlays,
  });
}

// Preset color-adjustment matrices. Shared by name ('none', 'warm', ...) so
// playback anywhere in the app can reproduce the same look without needing
// the original pixel data re-encoded.
const Map<String, List<double>> kVideoFilterMatrices = {
  'none': <double>[
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  'warm': <double>[
    1.15,
    0,
    0,
    0,
    12,
    0,
    1.05,
    0,
    0,
    6,
    0,
    0,
    0.85,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  'cool': <double>[
    0.9,
    0,
    0,
    0,
    0,
    0,
    1.0,
    0,
    0,
    0,
    0,
    0,
    1.2,
    0,
    12,
    0,
    0,
    0,
    1,
    0,
  ],
  'bw': <double>[
    0.33,
    0.59,
    0.11,
    0,
    0,
    0.33,
    0.59,
    0.11,
    0,
    0,
    0.33,
    0.59,
    0.11,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  'vintage': <double>[
    1.05,
    0.05,
    0.05,
    0,
    12,
    0,
    0.95,
    0.05,
    0,
    6,
    0.05,
    0.1,
    0.75,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
};

const List<double> kSpeedOptions = [0.5, 1.0, 1.5, 2.0];

class VideoEffectsScreen extends StatefulWidget {
  final File videoFile;
  final int startSeconds;

  const VideoEffectsScreen({
    super.key,
    required this.videoFile,
    required this.startSeconds,
  });

  @override
  State<VideoEffectsScreen> createState() => _VideoEffectsScreenState();
}

class _VideoEffectsScreenState extends State<VideoEffectsScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  double _speed = 1.0;
  String _filterType = 'none';
  final List<TextOverlayData> _textOverlays = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final VideoPlayerController controller =
        VideoPlayerController.file(widget.videoFile);
    await controller.initialize();
    await controller.seekTo(Duration(seconds: widget.startSeconds));
    controller.setLooping(true);
    controller.play();
    if (!mounted) return;
    setState(() {
      _controller = controller;
      _isInitialized = true;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _controller?.setPlaybackSpeed(speed);
  }

  void _setFilter(String filterType) {
    setState(() => _filterType = filterType);
  }

  Future<void> _addSticker() async {
    final TextEditingController searchController = TextEditingController();
    List<KlipyStickerResult> klipyResults = [];
    bool isSearching = false;
    bool searchedOnce = false;

    final result = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return DefaultTabController(
          length: 2,
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> runSearch(String query) async {
                if (query.trim().isEmpty) return;
                setSheetState(() => isSearching = true);
                final results = await searchKlipyStickers(query.trim());
                setSheetState(() {
                  klipyResults = results;
                  isSearching = false;
                  searchedOnce = true;
                });
              }

              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: SizedBox(
                    height: 420,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Pick a sticker',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const TabBar(
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.white38,
                          indicatorColor: Color(0xFFFF4B6E),
                          tabs: [
                            Tab(text: 'Emoji'),
                            Tab(text: 'Sticker Pack'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: TabBarView(
                            children: [
                              // ---- Emoji tab ----
                              GridView.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 6,
                                ),
                                itemCount: kStickerEmojis.length,
                                itemBuilder: (context, index) {
                                  final String emoji = kStickerEmojis[index];
                                  return GestureDetector(
                                    onTap: () => Navigator.pop(
                                        sheetContext, emoji as Object),
                                    child: Center(
                                      child: Text(emoji,
                                          style: const TextStyle(fontSize: 28)),
                                    ),
                                  );
                                },
                              ),
                              // ---- Klipy sticker pack tab ----
                              Column(
                                children: [
                                  TextField(
                                    controller: searchController,
                                    style: const TextStyle(color: Colors.white),
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: runSearch,
                                    decoration: InputDecoration(
                                      hintText:
                                          'Search stickers... (e.g. happy)',
                                      hintStyle:
                                          const TextStyle(color: Colors.grey),
                                      prefixIcon: const Icon(Icons.search,
                                          color: Colors.grey),
                                      filled: true,
                                      fillColor: Colors.black26,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide.none,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              vertical: 0, horizontal: 12),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: isSearching
                                        ? const Center(
                                            child: CircularProgressIndicator(
                                                color: Colors.redAccent))
                                        : !searchedOnce
                                            ? const Center(
                                                child: Text(
                                                  'Search for a sticker pack above',
                                                  style: TextStyle(
                                                      color: Colors.grey),
                                                ),
                                              )
                                            : klipyResults.isEmpty
                                                ? const Center(
                                                    child: Text(
                                                      'No stickers found',
                                                      style: TextStyle(
                                                          color: Colors.grey),
                                                    ),
                                                  )
                                                : GridView.builder(
                                                    gridDelegate:
                                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                                      crossAxisCount: 3,
                                                      crossAxisSpacing: 6,
                                                      mainAxisSpacing: 6,
                                                    ),
                                                    itemCount:
                                                        klipyResults.length,
                                                    itemBuilder:
                                                        (context, index) {
                                                      final sticker =
                                                          klipyResults[index];
                                                      return GestureDetector(
                                                        onTap: () =>
                                                            Navigator.pop(
                                                                sheetContext,
                                                                sticker
                                                                    as Object),
                                                        child: ClipRRect(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(8),
                                                          child: Image.network(
                                                            sticker.previewUrl,
                                                            fit: BoxFit.cover,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );

    if (result == null) return;
    setState(() {
      if (result is KlipyStickerResult) {
        _textOverlays.add(TextOverlayData(
          text: '',
          isSticker: true,
          imageUrl: result.fullUrl,
        ));
      } else if (result is String) {
        _textOverlays.add(TextOverlayData(text: result, isSticker: true));
      }
    });
  }

  Future<Map<String, dynamic>?> _showTextOverlayDialog({
    required String title,
    String initialText = '',
    Color initialColor = Colors.white,
    String initialStyle = 'classic',
    String initialAnimation = 'none',
    bool showDelete = false,
  }) async {
    final TextEditingController textController =
        TextEditingController(text: initialText);
    Color selectedColor = initialColor;
    String selectedStyle = initialStyle;
    String selectedAnimation = initialAnimation;
    const List<Color> colorChoices = [
      Colors.white,
      Colors.black,
      Colors.redAccent,
      Colors.yellowAccent,
      Colors.lightBlueAccent,
      Colors.greenAccent,
      Color(0xFFFF4B6E),
      Color(0xFF9C4DFF),
    ];

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textController,
                  maxLength: 60,
                  autofocus: true,
                  style: TextStyle(
                    color: selectedColor,
                    fontWeight: FontWeight.bold,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4),
                      Shadow(color: Colors.black, blurRadius: 4),
                    ],
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Type something...',
                    hintStyle: TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.redAccent)),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Style',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kTextOverlayStyles.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final String styleId = kTextOverlayStyles[i];
                      final bool isSelected = styleId == selectedStyle;
                      return GestureDetector(
                        onTap: () =>
                            setDialogState(() => selectedStyle = styleId),
                        child: Container(
                          width: 64,
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.redAccent
                                  : Colors.white24,
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              styledOverlayText(
                                  'Aa', 20, selectedColor, styleId),
                              const SizedBox(height: 4),
                              Text(
                                textOverlayStyleLabel(styleId),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Animation',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kTextOverlayAnimations.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final String animId = kTextOverlayAnimations[i];
                      final bool isSelected = animId == selectedAnimation;
                      return GestureDetector(
                        onTap: () =>
                            setDialogState(() => selectedAnimation = animId),
                        child: Container(
                          width: 64,
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.redAccent
                                  : Colors.white24,
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedOverlayText(
                                text: 'Aa',
                                fontSize: 20,
                                color: selectedColor,
                                styleId: selectedStyle,
                                animationId: animId,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                textOverlayAnimationLabel(animId),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Text color',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: colorChoices.map((color) {
                    final bool isSelected = color.value == selectedColor.value;
                    return GestureDetector(
                      onTap: () => setDialogState(() => selectedColor = color),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? Colors.white : Colors.white24,
                            width: isSelected ? 2.5 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            if (showDelete)
              TextButton(
                onPressed: () => Navigator.pop(ctx, {'delete': true}),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, {
                'text': textController.text.trim(),
                'color': selectedColor,
                'styleId': selectedStyle,
                'animationId': selectedAnimation,
              }),
              child: Text(showDelete ? 'Save' : 'Add',
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addTextOverlay() async {
    final Map<String, dynamic>? result =
        await _showTextOverlayDialog(title: 'Add text');
    final String? text = result?['text'] as String?;
    if (text == null || text.isEmpty) return;
    setState(() {
      _textOverlays.add(TextOverlayData(
        text: text,
        color: result?['color'] as Color? ?? Colors.white,
        styleId: result?['styleId'] as String? ?? 'classic',
        animationId: result?['animationId'] as String? ?? 'none',
      ));
    });
  }

  // Tapping an existing text overlay (not a sticker/emoji) reopens the
  // same dialog pre-filled with its current text/color/style/animation,
  // so a typo or a wrong style choice can be fixed in place instead of
  // deleting and re-adding it from scratch.
  Future<void> _editTextOverlay(int index) async {
    final TextOverlayData overlay = _textOverlays[index];
    final Map<String, dynamic>? result = await _showTextOverlayDialog(
      title: 'Edit text',
      initialText: overlay.text,
      initialColor: overlay.color,
      initialStyle: overlay.styleId,
      initialAnimation: overlay.animationId,
      showDelete: true,
    );
    if (result == null) return;
    setState(() {
      if (result['delete'] == true) {
        _textOverlays.removeAt(index);
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

  void _confirm() {
    Navigator.pop(
      context,
      VideoEffectsResult(
        speed: _speed,
        filterType: _filterType,
        textOverlays: _textOverlays,
      ),
    );
  }

  Widget _buildDraggableText(int index, double width, double height) {
    final TextOverlayData overlay = _textOverlays[index];
    double gestureStartScale = overlay.scale;

    final double baseFontSize = overlay.isSticker ? 56 : 20;
    final double fontSize = baseFontSize * overlay.scale;

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
        // Tapping a text overlay (not a sticker/emoji, which has nothing
        // typed to correct) reopens the add-text dialog pre-filled, so a
        // typo or wrong color/style choice can be fixed without deleting
        // and re-adding it.
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
            // Small, always-visible delete button so removing an overlay
            // doesn't rely on remembering a long-press gesture.
            Positioned(
              top: -10,
              right: -10,
              child: GestureDetector(
                onTap: () => setState(() => _textOverlays.removeAt(index)),
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

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
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
        title: const Text('Add effects', style: TextStyle(color: Colors.white)),
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
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ColorFiltered(
                          colorFilter: ColorFilter.matrix(
                              kVideoFilterMatrices[_filterType]!),
                          child: VideoPlayer(_controller!),
                        ),
                        for (int i = 0; i < _textOverlays.length; i++)
                          _buildDraggableText(
                              i, constraints.maxWidth, constraints.maxHeight),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          if (_textOverlays.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'Drag to move • pinch to resize • tap ✕ to remove',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
          // Speed picker
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: kSpeedOptions.map((speed) {
                final bool isActive = _speed == speed;
                return GestureDetector(
                  onTap: () => _setSpeed(speed),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: isActive
                          ? const LinearGradient(colors: [
                              Color(0xFFFF4B6E),
                              Color(0xFF9C4DFF),
                            ])
                          : null,
                      color: isActive ? null : Colors.grey[850],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${speed}x',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Filter picker
          SizedBox(
            height: 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: kVideoFilterMatrices.keys.map((name) {
                final bool isActive = _filterType == name;
                return GestureDetector(
                  onTap: () => _setFilter(name),
                  child: Container(
                    margin: const EdgeInsets.only(right: 10),
                    width: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            isActive ? const Color(0xFFFF4B6E) : Colors.white24,
                        width: isActive ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      name,
                      style: TextStyle(
                        color: isActive ? Colors.white : Colors.white70,
                        fontSize: 12,
                        fontWeight:
                            isActive ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Add text / Add sticker buttons
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _addTextOverlay,
                      icon: const Icon(Icons.text_fields, color: Colors.white),
                      label: const Text('Add text',
                          style: TextStyle(color: Colors.white)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _addSticker,
                      icon: const Icon(Icons.emoji_emotions_outlined,
                          color: Colors.white),
                      label: const Text('Add sticker',
                          style: TextStyle(color: Colors.white)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

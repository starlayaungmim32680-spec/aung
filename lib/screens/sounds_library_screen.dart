// Browse and search every reusable sound in the app - all of them are
// other creators' own uploaded audio (see upload_screen.dart / sound_
// screen.dart), so this is entirely user-generated content, not a
// licensed music catalog. See the app's copyright constraints: adding
// actual commercial/licensed music would need paid label deals, which
// is out of scope for now.
//
// Two ways in:
//  - sound_screen.dart's "Use this sound" button (after browsing to a
//    specific video first)
//  - this screen (search/browse without needing to find a video first),
//    pushed from upload_screen.dart's "Add sound" row
//
// Selecting a sound here pops back to the caller with a result map
// (soundId/title/ownerName/sourceUrl) rather than navigating anywhere
// itself, so it slots into whichever screen opened it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'media_utils.dart';

class SoundsLibraryScreen extends StatefulWidget {
  const SoundsLibraryScreen({super.key});

  @override
  State<SoundsLibraryScreen> createState() => _SoundsLibraryScreenState();
}

class _SoundsLibraryScreenState extends State<SoundsLibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  VideoPlayerController? _previewController;
  String? _previewingSoundId;
  bool _previewLoading = false;

  @override
  void dispose() {
    _searchController.dispose();
    _previewController?.dispose();
    super.dispose();
  }

  Future<void> _togglePreview(String soundId, String sourceUrl) async {
    if (sourceUrl.isEmpty) return;

    if (_previewingSoundId == soundId && _previewController != null) {
      // Already loaded - just flip play/pause.
      final bool playing = _previewController!.value.isPlaying;
      if (playing) {
        await _previewController!.pause();
      } else {
        await _previewController!.play();
      }
      setState(() {});
      return;
    }

    setState(() {
      _previewLoading = true;
      _previewingSoundId = soundId;
    });
    try {
      await _previewController?.dispose();
      final controller = VideoPlayerController.networkUrl(Uri.parse(sourceUrl));
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _previewController = controller;
        _previewLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _previewLoading = false;
          _previewingSoundId = null;
        });
      }
    }
  }

  void _selectSound(Map<String, dynamic> data, String soundId) {
    _previewController?.pause();
    Navigator.pop(context, {
      'soundId': soundId,
      'title': (data['title'] as String?) ?? 'Original sound',
      'ownerName': (data['ownerName'] as String?) ?? '',
      'sourceUrl': (data['sourceUrl'] as String?) ?? '',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Add sound', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search by creator name...',
                hintStyle: const TextStyle(color: Colors.grey),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
              ),
            ),
          ),
          if (_query.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.music_note, color: Colors.redAccent, size: 16),
                  SizedBox(width: 6),
                  Text('Recent',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              // Newest-first. Firestore has no native text search, so the
              // name search below is a client-side filter over this same
              // batch - fine at the catalog sizes this app will have for
              // a good while. (Sorted by createdAt rather than usageCount
              // so sounds posted before that field existed still show up
              // - Firestore excludes docs missing an orderBy field.)
              stream: FirebaseFirestore.instance
                  .collection('sounds')
                  .orderBy('createdAt', descending: true)
                  .limit(100)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Could not load sounds:\n${snap.error}',
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                List<QueryDocumentSnapshot> docs = snap.data!.docs;
                if (_query.isNotEmpty) {
                  docs = docs.where((d) {
                    final data = d.data() as Map<String, dynamic>;
                    final String owner =
                        (data['ownerName'] as String? ?? '').toLowerCase();
                    final String title =
                        (data['title'] as String? ?? '').toLowerCase();
                    return owner.contains(_query) || title.contains(_query);
                  }).toList();
                }

                if (docs.isEmpty) {
                  return Center(
                    child: Text(
                      _query.isEmpty
                          ? 'No sounds yet - be the first to post!'
                          : 'No creators matching "$_query"',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final String title =
                        (data['title'] as String?) ?? 'Original sound';
                    final String ownerName =
                        (data['ownerName'] as String?) ?? 'Someone';
                    final String sourceUrl =
                        (data['sourceUrl'] as String?) ?? '';
                    final int usageCount =
                        (data['usageCount'] as num?)?.toInt() ?? 0;
                    final bool isThisPreviewing = _previewingSoundId == doc.id;
                    final bool isThisPlaying = isThisPreviewing &&
                        _previewController != null &&
                        _previewController!.value.isPlaying;

                    return ListTile(
                      onTap: () => _selectSound(data, doc.id),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: sourceUrl.isEmpty
                              ? Container(
                                  color: Colors.grey[850],
                                  child: const Icon(Icons.music_note,
                                      color: Colors.white38, size: 20),
                                )
                              : CachedNetworkImage(
                                  imageUrl: cloudinaryThumbUrl(sourceUrl),
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) =>
                                      Container(color: Colors.grey[850]),
                                  errorWidget: (_, __, ___) =>
                                      Container(color: Colors.grey[850]),
                                ),
                        ),
                      ),
                      title: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(
                        '$ownerName · $usageCount ${usageCount == 1 ? "video" : "videos"}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                      trailing: GestureDetector(
                        onTap: () => _togglePreview(doc.id, sourceUrl),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.1),
                          ),
                          child: _previewLoading && isThisPreviewing
                              ? const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : Icon(
                                  isThisPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 18,
                                ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

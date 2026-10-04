import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'home_screen.dart';
import 'media_utils.dart';
import 'public_profile_screen.dart';
import '../block_service.dart';
import '../search_service.dart';
import '../search_history.dart';
import 'presence_badge.dart';

// Search screen. Before typing: my RECENT searches (accounts I opened +
// words I searched, TikTok/Facebook style - search_history.dart; no video
// grid any more, Ko asked 4 Oct 2026) and "Trending on Fly" (top words
// different people searched in the last 7 days - SearchService.trending,
// 4 Oct 2026). Once I type: matching accounts +
// videos. Since 4 Oct
// 2026 the matching runs on the server (search_service.dart -> Worker ->
// Cloudflare D1): the phone only downloads the ~20 results, and finds
// text anywhere in a name / caption ("ung" -> "Aung", "#travel").
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  // What's typed (drives the clear button) vs. what's actually searched -
  // the search waits until typing pauses, so "aung" is one request, not 4.
  String _typed = '';
  String _query = '';
  Timer? _debounce;

  void _onChanged(String v) {
    final String text = v.trim();
    setState(() => _typed = text);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted && text != _query) setState(() => _query = text);
    });
  }

  @override
  void initState() {
    super.initState();
    SearchHistory.instance.load();
    SearchService.loadTrending();
  }

  // Runs a search from a recent item / the keyboard's search button.
  void _searchNow(String text) {
    final String q = text.trim();
    _debounce?.cancel();
    if (_controller.text != text) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    setState(() {
      _typed = q;
      _query = q;
    });
    SearchHistory.instance.addText(q);
    SearchService.logSearch(q);
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _typed = '';
      _query = '';
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.search, color: Colors.grey[500], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search videos or accounts',
                    hintStyle: TextStyle(color: Colors.grey[500]),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: _searchNow,
                ),
              ),
              if (_typed.isNotEmpty)
                GestureDetector(
                  onTap: _clear,
                  child: Icon(Icons.close, color: Colors.grey[500], size: 18),
                ),
            ],
          ),
        ),
      ),
      body: _typed.isEmpty
          ? _SearchHome(onSearchText: _searchNow)
          : _query.isEmpty
              ? const SizedBox.shrink()
              // A new key per query = a fresh one-shot search (the Future
              // is created once in initState, never inside build()).
              : _SearchResults(key: ValueKey(_query), query: _query),
    );
  }
}

// Before typing: my recent searches (newest first - accounts with their
// photo, typed words with a clock icon; ✕ removes one, "Clear all" after
// asking) and then "Trending on Fly". Each part rebuilds only when its own
// list changes (two ValueListenableBuilders).
class _SearchHome extends StatelessWidget {
  final void Function(String text) onSearchText;

  const _SearchHome({required this.onSearchText});

  Future<void> _confirmClear(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Clear all recent searches?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This removes your search history on every device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear all',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      HapticFeedback.mediumImpact();
      await SearchHistory.instance.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SearchHistoryItem>>(
      valueListenable: SearchHistory.instance.items,
      builder: (context, items, _) {
        final visible = items
            .where(
                (e) => !e.isUser || !BlockService.instance.isHidden(e.userId))
            .toList();
        return ValueListenableBuilder<List<String>>(
          valueListenable: SearchService.trending,
          builder: (context, trending, _) {
            if (visible.isEmpty && trending.isEmpty) {
              return const _SearchMessage(
                icon: Icons.travel_explore_rounded,
                title: 'Search Fly',
                subtitle:
                    'Find friends by name, or videos by a word or #hashtag.\nYour recent searches will show up here.',
              );
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (visible.isNotEmpty) ...[
                  _HomeHeader(
                    title: 'Recent',
                    action: TextButton(
                      onPressed: () => _confirmClear(context),
                      child: const Text('Clear all',
                          style: TextStyle(color: Color(0xFFFF7A95))),
                    ),
                  ),
                  for (final item in visible)
                    Dismissible(
                      key: ValueKey(item.key),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.redAccent.withValues(alpha: 0.25),
                        child: const Icon(Icons.delete_outline,
                            color: Colors.white),
                      ),
                      onDismissed: (_) => SearchHistory.instance.remove(item),
                      child: _RecentRow(
                        item: item,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          if (item.isUser) {
                            // Opening them again moves them to the top.
                            SearchHistory.instance
                                .addUser(item.userId, item.name, item.photo);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PublicProfileScreen(userId: item.userId),
                              ),
                            );
                          } else {
                            onSearchText(item.text);
                          }
                        },
                        onRemove: () {
                          HapticFeedback.lightImpact();
                          SearchHistory.instance.remove(item);
                        },
                      ),
                    ),
                ],
                if (trending.isNotEmpty) ...[
                  if (visible.isNotEmpty) const SizedBox(height: 8),
                  const _HomeHeader(
                    title: 'Trending on Fly',
                    icon: Icons.local_fire_department_rounded,
                  ),
                  for (int i = 0; i < trending.length; i++)
                    _TrendingRow(
                      rank: i + 1,
                      term: trending[i],
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onSearchText(trending[i]);
                      },
                    ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _HomeHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? action;

  const _HomeHeader({required this.title, this.icon, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 8, action == null ? 8 : 4),
      child: Row(
        children: [
          if (icon != null) ...[
            ShaderMask(
              shaderCallback: (rect) => const LinearGradient(colors: [
                Color(0xFFFF4B6E),
                Color(0xFF9C4DFF),
              ]).createShader(rect),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

// One trending word: its rank (top 3 in Fly pink), the word, and a small
// "trending up" arrow. Tapping searches it.
class _TrendingRow extends StatelessWidget {
  final int rank;
  final String term;
  final VoidCallback onTap;

  const _TrendingRow({
    required this.rank,
    required this.term,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool top = rank <= 3;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: TextStyle(
                  color: top ? const Color(0xFFFF4B6E) : Colors.grey[500],
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: Text(
                term,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.trending_up_rounded,
              size: 18,
              color: top ? const Color(0xFFFF7A95) : Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final SearchHistoryItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RecentRow({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final Widget leading;
    if (item.isUser) {
      final String name = item.name.trim().isEmpty ? 'User' : item.name.trim();
      leading = Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [
            Color(0xFFFF4B6E),
            Color(0xFF9C4DFF),
            Color(0xFF3A8DFF),
          ]),
        ),
        child: CircleAvatar(
          radius: 20,
          backgroundColor: Colors.grey[850],
          backgroundImage:
              item.photo.isNotEmpty ? NetworkImage(item.photo) : null,
          child: item.photo.isEmpty
              ? Text(
                  name[0].toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                )
              : null,
        ),
      );
    } else {
      leading = Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.08),
        ),
        child: Icon(
          item.text.startsWith('#') ? Icons.tag_rounded : Icons.history_rounded,
          color: Colors.white70,
          size: 22,
        ),
      );
    }

    return ListTile(
      onTap: onTap,
      leading: leading,
      title: Text(
        item.isUser
            ? (item.name.trim().isEmpty ? 'User' : item.name)
            : item.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: item.isUser
          ? Text('Account',
              style: TextStyle(color: Colors.grey[500], fontSize: 12))
          : null,
      trailing: IconButton(
        tooltip: 'Remove',
        icon: Icon(Icons.close_rounded, color: Colors.grey[500], size: 20),
        onPressed: onRemove,
      ),
    );
  }
}

// Results for one query, from SearchService (server-side search). One
// request per query; while it runs a spinner shows, and a failure shows a
// friendly retry instead of raw error text.
class _SearchResults extends StatefulWidget {
  final String query;

  const _SearchResults({super.key, required this.query});

  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends State<_SearchResults> {
  late Future<SearchResults> _future;

  @override
  void initState() {
    super.initState();
    _future = SearchService.search(widget.query);
  }

  void _retry() {
    setState(() => _future = SearchService.search(widget.query));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SearchResults>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFFF4B6E)),
          );
        }
        if (snap.hasError) {
          final String msg = snap.error is SearchException
              ? snap.error.toString()
              : "Couldn't search right now.";
          return _SearchMessage(
            icon: Icons.wifi_off_rounded,
            title: msg,
            actionLabel: 'Try again',
            onAction: _retry,
          );
        }
        final SearchResults results = snap.data!;
        if (results.isEmpty) {
          return _SearchMessage(
            icon: Icons.search_off_rounded,
            title: 'No results for "${widget.query}"',
            subtitle: 'Try another name, a word from a caption, or a #hashtag.',
          );
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (results.users.isNotEmpty) ...[
              const _SectionTitle('Accounts'),
              ...results.users.map((doc) {
                final data = doc.data() ?? const <String, dynamic>{};
                final String raw =
                    ((data['displayName'] as String?) ?? '').trim();
                final String name = raw.isEmpty ? 'User' : raw;
                final String photo = (data['photoUrl'] as String?) ?? '';
                return ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [
                            Color(0xFFFF4B6E),
                            Color(0xFF9C4DFF),
                            Color(0xFF3A8DFF),
                          ]),
                        ),
                        child: CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.grey[850],
                          backgroundImage:
                              photo.isNotEmpty ? NetworkImage(photo) : null,
                          child: photo.isEmpty
                              ? Text(
                                  name[0].toUpperCase(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                )
                              : null,
                        ),
                      ),
                      if (isUserOnline(data))
                        const Positioned(
                          right: -2,
                          bottom: -2,
                          child: SparkleStarBadge(),
                        ),
                    ],
                  ),
                  title: Text(name,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  onTap: () {
                    // Facebook-style: the person goes into my recents.
                    SearchHistory.instance.addUser(doc.id, name, photo);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PublicProfileScreen(userId: doc.id),
                      ),
                    );
                  },
                );
              }),
            ],
            if (results.posts.isNotEmpty) ...[
              const _SectionTitle('Videos'),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                  childAspectRatio: 0.7,
                ),
                itemCount: results.posts.length,
                itemBuilder: (context, index) {
                  final doc = results.posts[index];
                  final post = doc.data() ?? const <String, dynamic>{};
                  return GestureDetector(
                    onTap: () {
                      // Opening a video keeps the words I searched for.
                      SearchHistory.instance.addText(widget.query);
                      SearchService.logSearch(widget.query);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SingleVideoScreen(
                            postId: doc.id,
                            userId: post['userId'] ?? '',
                            videoUrl: post['videoUrl'] ?? '',
                            caption: post['caption'] ?? '',
                            userEmail: post['userEmail'] ?? 'Unknown user',
                            videoType:
                                (post['videoType'] as String?) ?? 'short',
                          ),
                        ),
                      );
                    },
                    child: _SearchVideoThumbnail(
                      videoUrl: post['videoUrl'] ?? '',
                      postId: doc.id,
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// Friendly empty / error state: soft Fly-gradient bubble + icon, optional
// action button.
class _SearchMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SearchMessage({
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  const Color(0xFFFF4B6E).withValues(alpha: 0.25),
                  const Color(0xFF9C4DFF).withValues(alpha: 0.25),
                  const Color(0xFF3A8DFF).withValues(alpha: 0.25),
                ]),
              ),
              child: Icon(icon, color: Colors.white70, size: 40),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: onAction,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: const LinearGradient(colors: [
                      Color(0xFFFF4B6E),
                      Color(0xFF9C4DFF),
                      Color(0xFF3A8DFF),
                    ]),
                  ),
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Thumbnail tile showing the first frame of a video + its view count
class _SearchVideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String postId;

  const _SearchVideoThumbnail({
    required this.videoUrl,
    required this.postId,
  });

  @override
  State<_SearchVideoThumbnail> createState() => _SearchVideoThumbnailState();
}

class _SearchVideoThumbnailState extends State<_SearchVideoThumbnail> {
  @override
  Widget build(BuildContext context) {
    final String thumbUrl = cloudinaryThumbUrl(widget.videoUrl);

    return Container(
      color: Colors.grey[900],
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumbUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: thumbUrl,
              fit: BoxFit.cover,
              placeholder: (context, url) => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white24),
                ),
              ),
              errorWidget: (context, url, error) => const Center(
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white30, size: 30),
              ),
            )
          else
            const Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white30, size: 30),
            ),
          Positioned(
            left: 6,
            bottom: 6,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(widget.postId)
                  .collection('views')
                  .snapshots(),
              builder: (context, snap) {
                final int views = snap.hasData ? snap.data!.docs.length : 0;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                    const SizedBox(width: 2),
                    Text(
                      _fmtViews(views),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Formats view counts like 1200 -> "1.2K"
String _fmtViews(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

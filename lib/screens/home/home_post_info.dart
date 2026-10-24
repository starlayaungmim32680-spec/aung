// Part of home_screen.dart - split out 13 Oct 2026 (step 3 of breaking up
// the big file, a piece at a time). The text/info overlaid on a video:
// the caption with tappable #hashtags (+ translate) (_CaptionWithHashtags),
// the #hashtag video grid screen (HashtagScreen - public, still reached
// through `import 'home_screen.dart'` as before), and the post owner's
// photo / name / follow button block (_OwnerInfo). Moved unchanged.
part of '../home_screen.dart';

// Renders a caption with any #hashtags shown in a distinct color and
// tappable, opening HashtagScreen for that tag.
class _CaptionWithHashtags extends StatefulWidget {
  final String caption;
  final bool compact;

  const _CaptionWithHashtags({required this.caption, required this.compact});

  @override
  State<_CaptionWithHashtags> createState() => _CaptionWithHashtagsState();
}

class _CaptionWithHashtagsState extends State<_CaptionWithHashtags> {
  String? _translated;
  bool _translating = false;
  bool _showTranslated = false;
  // Set only when a translate attempt comes back genuinely not
  // applicable (already the device's language, or an unsupported
  // language) - hides the link. A failed *attempt* (weak connection,
  // low storage - common on budget phones) does NOT set this, so the
  // link stays put and the user can just tap it again once they have a
  // better connection, instead of the feature silently vanishing.
  bool _translationUnavailable = false;

  Future<void> _onTranslateTap() async {
    // Already translated once - just toggle between the two, no need to
    // hit ML Kit again.
    if (_translated != null) {
      setState(() => _showTranslated = !_showTranslated);
      return;
    }
    setState(() => _translating = true);
    final TranslationOutcome outcome = await TranslationService.instance
        .translateToDeviceLanguage(widget.caption);
    if (!mounted) return;
    setState(() {
      _translating = false;
      switch (outcome.status) {
        case TranslationStatus.success:
          _translated = outcome.text;
          _showTranslated = true;
          break;
        case TranslationStatus.notApplicable:
          _translationUnavailable = true;
          break;
        case TranslationStatus.retry:
          // Leave everything as-is so the link (and a quick explanation)
          // shows again and can be tapped to retry.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Couldn't translate - check your connection "
                    'and try again'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
      }
    });
  }

  List<InlineSpan> _spansFor(BuildContext context, String text) {
    final RegExp hashtagPattern = RegExp(r'#([\p{L}\p{N}_]+)', unicode: true);
    final List<InlineSpan> spans = [];
    int lastEnd = 0;

    for (final match in hashtagPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final String tag = match.group(1)!;
      spans.add(
        TextSpan(
          text: '#$tag',
          style: const TextStyle(
            color: Color(0xFF6FC3FF),
            fontWeight: FontWeight.bold,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HashtagScreen(tag: tag.toLowerCase()),
                ),
              );
            },
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final bool compact = widget.compact;
    final String textToShow =
        _showTranslated && _translated != null ? _translated! : widget.caption;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 12 : 14,
              shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
            ),
            children: _spansFor(context, textToShow),
          ),
          maxLines: compact ? 1 : null,
          overflow: compact ? TextOverflow.ellipsis : TextOverflow.visible,
        ),
        // Skip the translate link in the compact (repost card) layout -
        // there's no room for it there - and once we've established
        // there's nothing useful to translate.
        if (!compact && !_translationUnavailable) ...[
          const SizedBox(height: 3),
          GestureDetector(
            onTap: _translating ? null : _onTranslateTap,
            child: _translating
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Translating\u2026',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  )
                : Text(
                    _showTranslated ? 'See original' : 'See translation',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

// Grid of every video tagged with a given #hashtag.
class HashtagScreen extends StatelessWidget {
  final String tag;
  const HashtagScreen({super.key, required this.tag});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('#$tag', style: const TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .where('hashtags', arrayContains: tag)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            );
          }
          // Hashtag pages are public places: only Everyone videos
          // (24 Oct 2026, post_audience.dart), and never failed ones.
          final String? myId = FirebaseAuth.instance.currentUser?.uid;
          final docs = snapshot.data!.docs.where((d) {
            final Map<String, dynamic> m = d.data() as Map<String, dynamic>;
            return audienceOf(m).isPublic && isVideoVisibleTo(m, myId);
          }).toList();
          if (docs.isEmpty) {
            return const Center(
              child: Text('No videos with this hashtag yet.',
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
              childAspectRatio: 9 / 16,
            ),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final String videoUrl = data['videoUrl'] ?? '';
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SingleVideoScreen(
                        postId: doc.id,
                        userId: data['userId'] ?? '',
                        videoUrl: videoUrl,
                        caption: data['caption'] ?? '',
                        userEmail: data['userEmail'] ?? '',
                        videoType: (data['videoType'] as String?) ?? 'short',
                      ),
                    ),
                  );
                },
                child: Container(
                  color: Colors.grey[900],
                  child: CachedNetworkImage(
                    imageUrl: cloudinaryThumbUrl(videoUrl),
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: Colors.grey[900]),
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey[900]),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// Shows the post owner's profile photo, display name, follow button, and caption
class _OwnerInfo extends StatelessWidget {
  final String userId;
  final String fallbackEmail;
  final String caption;
  final String postId;
  final String? soundId;
  final String soundLabel;
  // "Orbit Ring": how many reactions this video has, drawn as a partial
  // gradient ring around the avatar - a quick, glanceable read on how
  // this specific video is landing, without needing to check the like
  // count separately. Purely visual, computed from data already on hand
  // (no extra reads).
  final int reactionCount;
  // "Reply Video Chain": when this video is itself a reply to someone
  // else's post, these carry who it's replying to, so a small "Replying
  // to @X" chip can link back to the original.
  final String? replyToPostId;
  final String? replyToOwnerId;
  final String? replyToOwnerName;
  // When true, renders a much smaller version (smaller avatar/text, no
  // sound credit or view count, single-line caption) for use inside the
  // repost nested card, where space is tight.
  final bool compact;

  const _OwnerInfo({
    required this.userId,
    required this.fallbackEmail,
    required this.caption,
    required this.postId,
    this.soundId,
    this.soundLabel = '',
    this.reactionCount = 0,
    this.replyToPostId,
    this.replyToOwnerId,
    this.replyToOwnerName,
    this.compact = false,
  });

  // Follows or unfollows the video owner (and notifies them when following)
  Future<void> _toggleFollow(String myId, bool isFollowing) async {
    final firestore = FirebaseFirestore.instance;
    final followersDoc = firestore
        .collection('users')
        .doc(userId)
        .collection('followers')
        .doc(myId);
    final followingDoc = firestore
        .collection('users')
        .doc(myId)
        .collection('following')
        .doc(userId);

    if (isFollowing) {
      // Unfollow - remove both records and stop here
      final batch = firestore.batch();
      batch.delete(followersDoc);
      batch.delete(followingDoc);
      await batch.commit();
      return;
    }

    final batch = firestore.batch();
    batch.set(followersDoc, {'createdAt': FieldValue.serverTimestamp()});
    batch.set(followingDoc, {'createdAt': FieldValue.serverTimestamp()});
    await batch.commit();

    final myProfile = await firestore.collection('users').doc(myId).get();
    final myData = myProfile.data();
    final String myName =
        (myData?['displayName'] as String?)?.trim().isNotEmpty == true
            ? myData!['displayName']
            : 'Someone';
    final String myPhoto = (myData?['photoUrl'] as String?) ?? '';

    await firestore
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .add({
      'type': 'follow',
      'text': '',
      'fromId': myId,
      'fromName': myName,
      'fromPhoto': myPhoto,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Opens the tapped user's public profile
  void _openProfile(BuildContext context) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PublicProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = FirebaseAuth.instance.currentUser?.uid;

    return StreamBuilder<DocumentSnapshot>(
      stream: userId.isEmpty
          ? null
          : FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .snapshots(),
      builder: (context, snapshot) {
        final Map<String, dynamic>? profile =
            snapshot.data?.data() as Map<String, dynamic>?;

        final String displayName =
            (profile?['displayName'] as String?)?.trim().isNotEmpty == true
                ? profile!['displayName']
                : (fallbackEmail.contains('@')
                    ? fallbackEmail.split('@').first
                    : fallbackEmail);
        final String? photoUrl = profile?['photoUrl'] as String?;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Plain avatar (no overlapping badge, so it stays fully
                // visible) with the Follow/Following control as its own
                // small circle right beside it - Fly's own take on the
                // follow control, instead of the pill-shaped button every
                // other app uses. The badge carries Fly's signature
                // blue-cyan gradient (same as the comment icon and orbit
                // menu) so it reads as distinctly "Fly".
                // "Orbit Ring" - a thin gradient arc around the avatar
                // showing how this video's reaction count compares to a
                // rough popularity scale (fuller ring = more reactions).
                // Purely visual, computed from data already streamed to
                // this widget - no extra Firestore reads.
                CustomPaint(
                  painter: _OrbitRingPainter(
                    // sqrt scaling so the ring fills up meaningfully even
                    // at modest reaction counts, instead of looking empty
                    // until a video goes viral.
                    progress: (sqrt(reactionCount.clamp(0, 400)) / 20)
                        .clamp(0.0, 1.0),
                    strokeWidth: compact ? 2 : 2.5,
                  ),
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 4 : 5),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                          ),
                        ),
                        child: CircleAvatar(
                          radius: compact ? 13 : 18,
                          backgroundColor: Colors.grey[850],
                          backgroundImage:
                              (photoUrl != null && photoUrl.isNotEmpty)
                                  ? NetworkImage(photoUrl)
                                  : null,
                          child: (photoUrl == null || photoUrl.isEmpty)
                              ? Text(
                                  displayName.isNotEmpty
                                      ? displayName[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: compact ? 12 : 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                if (myId != null && myId != userId && userId.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(userId)
                        .collection('followers')
                        .doc(myId)
                        .snapshots(),
                    builder: (context, followSnap) {
                      final bool isFollowing = followSnap.data?.exists ?? false;
                      return GestureDetector(
                        onTap: () => _toggleFollow(myId, isFollowing),
                        child: Container(
                          width: compact ? 22 : 26,
                          height: compact ? 22 : 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: isFollowing
                                ? null
                                : const LinearGradient(
                                    colors: [
                                      Color(0xFF2E6BFF),
                                      Color(0xFF35E1F2),
                                    ],
                                  ),
                            color: isFollowing ? const Color(0xFF3A3B3C) : null,
                            border: isFollowing
                                ? Border.all(color: Colors.white38, width: 1)
                                : null,
                          ),
                          child: Icon(
                            isFollowing ? Icons.check : Icons.add,
                            color: Colors.white,
                            size: compact ? 13 : 16,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(width: 10),
                Flexible(
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Text(
                      displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: compact ? 13 : 16,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 6)
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (replyToPostId != null && replyToOwnerName != null) ...[
              SizedBox(height: compact ? 3 : 6),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SingleVideoScreen(
                        postId: replyToPostId!,
                        userId: replyToOwnerId ?? '',
                        videoUrl: '',
                        caption: '',
                        userEmail: '',
                        videoType: 'short',
                      ),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply,
                        color: Colors.white70, size: compact ? 12 : 14),
                    const SizedBox(width: 4),
                    Text(
                      'Replying to @$replyToOwnerName',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: compact ? 10 : 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (caption.isNotEmpty) ...[
              SizedBox(height: compact ? 4 : 8),
              _CaptionWithHashtags(
                caption: caption,
                compact: compact,
              ),
            ],
            // Sound credit and view count take up space we don't have in
            // the compact (repost card) layout, so skip them there.
            if (!compact) ...[
              // Sound credit - tapping it opens every video using this sound
              if (soundId != null && soundId!.isNotEmpty) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SoundScreen(soundId: soundId!),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.music_note,
                          color: Colors.white,
                          size: 15,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 6)
                          ]),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          soundLabel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6)
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // View count below the video (unique viewers)
              if (postId.isNotEmpty) ...[
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('posts')
                      .doc(postId)
                      .collection('views')
                      .snapshots(),
                  builder: (context, viewSnap) {
                    final int viewCount =
                        viewSnap.hasData ? viewSnap.data!.docs.length : 0;
                    return Row(
                      children: [
                        const Icon(
                          Icons.remove_red_eye,
                          color: Colors.white,
                          size: 16,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                        const SizedBox(width: 6),
                        Text(
                          viewCount == 1 ? '1 view' : '$viewCount views',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6)
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ], // end if (!compact)
          ],
        );
      },
    );
  }
}

// Part of home_screen.dart - split out 13 Oct 2026 (step 4 of breaking up
// the big file, a piece at a time). The screen a comment / reaction /
// reply notification opens (PostFromNotificationScreen - public, still
// reached through `import 'home_screen.dart'` as before). Moved unchanged.
part of '../home_screen.dart';

// Opens the video a comment/reaction notification is about (1 Oct 2026).
// Fly's own touches on top of the usual "open the post":
//  - while it loads, the person who did it greets you (their photo in a
//    pulsing Fly ring + what they said) instead of a bare spinner;
//  - a glass banner slides in saying who did what, then tucks away;
//  - a reaction bursts that emoji over the video; a comment opens the
//    comments with that comment spotlighted;
//  - a reply (10 Oct 2026) opens the comments with the thread's comment
//    ([commentId]) spotlighted and its replies already open.
class PostFromNotificationScreen extends StatefulWidget {
  final String postId;
  final String fromId;
  final String fromName;
  final String fromPhoto;
  final String type; // 'comment', 'reply' or 'reaction'
  final String text; // the comment / reply text, or the reaction emoji
  // 'reply' only: the thread's comment id, and 'you' (my comment / I was
  // answered) or 'video' (a reply under a comment on my video).
  final String? commentId;
  final String? replyKind;
  // 'comment_reaction' only (13 Oct 2026): what the reacted comment said.
  final String? commentText;

  const PostFromNotificationScreen({
    super.key,
    required this.postId,
    required this.fromId,
    required this.fromName,
    required this.fromPhoto,
    required this.type,
    required this.text,
    this.commentId,
    this.replyKind,
    this.commentText,
  });

  @override
  State<PostFromNotificationScreen> createState() =>
      _PostFromNotificationScreenState();
}

class _PostFromNotificationScreenState
    extends State<PostFromNotificationScreen> {
  late final Future<DocumentSnapshot> _postFuture =
      FirebaseFirestore.instance.collection('posts').doc(widget.postId).get();
  bool _bannerShown = false;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  void _showBannerOnce() {
    if (_bannerTimer != null) return;
    _bannerTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _bannerShown = true);
      _bannerTimer = Timer(const Duration(milliseconds: 4200), () {
        if (mounted) setState(() => _bannerShown = false);
      });
    });
  }

  String get _actionText {
    if (widget.type == 'reaction') {
      return 'reacted ${widget.text} to your video';
    }
    if (widget.type == 'comment_reaction') {
      final String said = widget.commentText ?? '';
      return said.isEmpty
          ? 'reacted ${widget.text} to your comment'
          : 'reacted ${widget.text} to your comment: $said';
    }
    if (widget.type == 'reply') {
      return widget.replyKind == 'video'
          ? 'replied to a comment on your video: ${widget.text}'
          : 'replied to your comment: ${widget.text}';
    }
    return 'commented: ${widget.text}';
  }

  Widget _avatar(double radius) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF), Color(0xFF3A8DFF)],
        ),
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: Colors.grey[850],
        backgroundImage: widget.fromPhoto.isNotEmpty
            ? CachedNetworkImageProvider(widget.fromPhoto)
            : null,
        child: widget.fromPhoto.isEmpty
            ? Text(
                widget.fromName.isNotEmpty
                    ? widget.fromName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: radius * 0.8,
                ),
              )
            : null,
      ),
    );
  }

  Widget _backButton() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.arrow_back, color: Colors.white),
          ),
        ),
      ),
    );
  }

  // Loading: the person greets you instead of a plain spinner.
  Widget _intro() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.85, end: 1.0),
              duration: const Duration(milliseconds: 900),
              curve: Curves.elasticOut,
              builder: (context, s, child) =>
                  Transform.scale(scale: s, child: child),
              child: _avatar(42),
            ),
            const SizedBox(height: 18),
            Text(
              widget.fromName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                widget.type == 'reaction'
                    ? 'reacted ${widget.text} to your video'
                    : widget.type == 'comment_reaction'
                        ? 'reacted ${widget.text} to your comment'
                        : '“${widget.text}”',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ),
            const SizedBox(height: 26),
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                minHeight: 3,
                color: Color(0xFF9C4DFF),
                backgroundColor: Colors.white12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unavailable() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_outlined, color: Colors.grey[600], size: 56),
          const SizedBox(height: 14),
          const Text(
            'This video is no longer available',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            'It may have been deleted.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Go back',
                style: TextStyle(color: Color(0xFF9C4DFF))),
          ),
        ],
      ),
    );
  }

  // Glass banner: who did what. Slides in, then tucks itself away.
  Widget _banner() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 8, 12, 0),
        child: AnimatedSlide(
          offset: _bannerShown ? Offset.zero : const Offset(0, -1.6),
          duration: const Duration(milliseconds: 420),
          curve: _bannerShown ? Curves.easeOutBack : Curves.easeIn,
          child: AnimatedOpacity(
            opacity: _bannerShown ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: GestureDetector(
              onTap: () => setState(() => _bannerShown = false),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _avatar(14),
                        const SizedBox(width: 8),
                        Flexible(
                          child: RichText(
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: widget.fromName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                TextSpan(
                                  text: ' $_actionText',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<DocumentSnapshot>(
        future: _postFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Stack(children: [_intro(), _backButton()]);
          }
          final Map<String, dynamic>? post =
              snapshot.data?.data() as Map<String, dynamic>?;
          final String videoUrl = (post?['videoUrl'] as String?) ?? '';
          if (snapshot.hasError ||
              post == null ||
              videoUrl.isEmpty ||
              !isVideoVisibleTo(post, myId)) {
            return Stack(children: [_unavailable(), _backButton()]);
          }
          _showBannerOnce();
          final bool isReaction = widget.type == 'reaction';
          // A reaction to my comment opens the comments with that
          // comment's thread spotlighted, just like a reply does.
          final bool isReply =
              widget.type == 'reply' || widget.type == 'comment_reaction';
          return Stack(
            children: [
              _VideoPostItem(
                key: ValueKey(widget.postId),
                postId: widget.postId,
                userId: post['userId'] ?? '',
                videoUrl: videoUrl,
                caption: post['caption'] ?? '',
                userEmail: post['userEmail'] ?? 'Unknown user',
                reactions:
                    (post['reactions'] as Map<String, dynamic>?) ?? const {},
                videoType: (post['videoType'] as String?) ?? 'short',
                videoSpeed: ((post['videoSpeed']) as num?)?.toDouble() ?? 1.0,
                filterType: (post['filterType'] as String?) ?? 'none',
                textOverlays: ((post['textOverlays'] as List<dynamic>?)
                        ?.map((m) =>
                            TextOverlayData.fromMap(m as Map<String, dynamic>))
                        .toList()) ??
                    const [],
                effectsBaked: post['effectsBaked'] as bool? ?? false,
                onVideoEnd: () {},
                openCommentsOnStart: !isReaction,
                highlightCommentFrom:
                    isReaction || isReply ? null : widget.fromId,
                highlightCommentText:
                    isReaction || isReply ? null : widget.text,
                highlightCommentId: isReply ? widget.commentId : null,
                burstEmojiOnStart: isReaction ? widget.text : null,
              ),
              _backButton(),
              _banner(),
            ],
          );
        },
      ),
    );
  }
}

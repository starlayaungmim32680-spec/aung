// Part of home_screen.dart - split out 9 Oct 2026 (step 2 of breaking up
// the big file, a piece at a time). Everything about comments on a video:
// the comments bottom sheet (_CommentsSheet: list, composer, replies,
// reactions, hide/delete/report options, notification spotlight), the
// comment and reply rows (_CommentTile, _ReplyTile), the reaction summary
// chip, the "Hidden" tag, and the visibility helpers for hidden comments.
//
// It's a `part` file: it shares home_screen.dart's imports and its private
// (_) names, so moving the code here changed nothing else. Add new imports
// to home_screen.dart, not here.
part of '../home_screen.dart';

// Comment / reply visibility for the "Hide comment" feature. A hidden
// comment (hidden: true, set by the VIDEO OWNER) is still shown to:
//   - the video owner (dimmed, with a "Hidden" label, so they can unhide),
//   - the person who wrote it (shown normally - like Facebook, the author
//     isn't told, which avoids provoking them into re-posting).
// Everyone else doesn't see it, and it isn't counted.
bool _isCommentVisibleTo(
  Map<String, dynamic> data, {
  required String? myId,
  required String postOwnerId,
}) {
  if (data['hidden'] != true) return true;
  if (myId == null) return false;
  return myId == postOwnerId || myId == data['userId'];
}

// How many comments/replies someone (not the video owner or author) can
// actually see - used for the comment counts, so hidden ones don't count.
int _visibleCommentCount(List<QueryDocumentSnapshot> docs) {
  return docs.where((d) {
    final data = d.data() as Map<String, dynamic>?;
    return data?['hidden'] != true;
  }).length;
}

// Bottom sheet that shows comments, replies, and emoji reactions
class _CommentsSheet extends StatefulWidget {
  final String postId;
  final String ownerId;
  // Opened from a comment notification: that person's comment (matching
  // [highlightText] when possible) gets a short glowing spotlight.
  final String? highlightUserId;
  final String? highlightText;

  const _CommentsSheet({
    required this.postId,
    required this.ownerId,
    this.highlightUserId,
    this.highlightText,
  });

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  String? _replyToCommentId;
  String? _replyToName;

  // Accounts to hide (blocked either way - see block_service.dart): their
  // comments and replies don't show here.
  Set<String> _blockedIds = BlockService.instance.hidden.value;
  void _onBlockedChanged() {
    if (mounted) {
      setState(() => _blockedIds = BlockService.instance.hidden.value);
    }
  }

  // Built once in initState (Fly's stream rule): building it inside build()
  // made every setState create a new stream, which flashed the loading
  // spinner and made the list jump right when a comment was sent.
  late final Stream<QuerySnapshot> _commentsStream;

  // My own name/photo, fetched once when the sheet opens instead of on
  // every send - one less network round trip before a comment appears.
  late final Future<Map<String, String>> _myProfileFuture;

  String? get _myId => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference get _commentsRef => FirebaseFirestore.instance
      .collection('posts')
      .doc(widget.postId)
      .collection('comments');

  @override
  void initState() {
    super.initState();
    final User? me = FirebaseAuth.instance.currentUser;
    _commentsStream =
        _commentsRef.orderBy('createdAt', descending: true).snapshots();
    _myProfileFuture = me == null
        ? Future.value(const {'name': 'User', 'photo': ''})
        : _getMyProfile(me.uid, me.email);

    BlockService.instance.hidden.addListener(_onBlockedChanged);
  }

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    BlockService.instance.hidden.removeListener(_onBlockedChanged);
    super.dispose();
  }

  Future<Map<String, String>> _getMyProfile(String uid, String? email) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      final String name =
          (data?['displayName'] as String?)?.trim().isNotEmpty == true
              ? data!['displayName']
              : (email?.split('@').first ?? 'User');
      final String photo = (data?['photoUrl'] as String?) ?? '';
      return {'name': name, 'photo': photo};
    } catch (_) {
      return {'name': email?.split('@').first ?? 'User', 'photo': ''};
    }
  }

  void _startReply(String commentId, String name) {
    setState(() {
      _replyToCommentId = commentId;
      _replyToName = name;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToCommentId = null;
      _replyToName = null;
    });
  }

  // Base URL of the self-hosted moderation service (Flask on Render.com),
  // which proxies to OpenAI's free, multilingual omni-moderation model.
  static const String _moderationBaseUrl =
      'https://fly-moderation.onrender.com';

  // Calls the moderation service and returns whether the content was
  // flagged. Fails "open" (returns false / not flagged) on any network
  // error or timeout, so a moderation-service outage never blocks
  // comments outright. The free Render instance can take up to ~50s to
  // wake from a cold start - which is exactly why this now runs AFTER the
  // comment is posted (see _sendComment), never before it.
  static Future<bool> _isFlaggedByModerationServer(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_moderationBaseUrl$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) return false;
      final Map<String, dynamic> data = jsonDecode(response.body);
      return data['flagged'] == true;
    } catch (_) {
      return false;
    }
  }

  // Sends a comment (or a reply) instantly.
  //
  // Why it used to feel slow: it waited for the moderation server (a free
  // Render instance that can take ~50s to wake up) and then a profile
  // read, all BEFORE writing anything - and the input stayed locked with a
  // spinner the whole time. Now:
  //   1. the quick on-device word filter still runs first (blocks before
  //      posting, as before);
  //   2. the comment is written straight away and the input clears at
  //      once - Firestore shows it in the list immediately, even before
  //      the server confirms;
  //   3. the moderation-server check runs in the background afterwards;
  //      if it flags the comment, the comment is deleted again and the
  //      author gets a message. The video owner's notification is only
  //      sent once that check passes, so a flagged comment's text never
  //      lands in their notifications.
  Future<void> _sendComment() async {
    final User? user = FirebaseAuth.instance.currentUser;
    final String text = _commentController.text.trim();
    if (user == null || text.isEmpty) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    if (ContentFilter.containsBlockedContent(text)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
              'Your comment contains inappropriate language. Please edit it.'),
        ),
      );
      return;
    }

    final String? replyToId = _replyToCommentId;
    _commentController.clear();
    _cancelReply();

    final Map<String, String> profile = await _myProfileFuture;
    final String displayName = profile['name']!;
    final String photoUrl = profile['photo']!;

    // The doc id is generated locally, so the write shows up in the list
    // right away and the background check below can find it again.
    final DocumentReference ref = replyToId == null
        ? _commentsRef.doc()
        : _commentsRef.doc(replyToId).collection('replies').doc();

    ref.set({
      'userId': user.uid,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'text': text,
      'reactions': <String, dynamic>{},
      'createdAt': FieldValue.serverTimestamp(),
    }).catchError((_) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text("Couldn't send your comment. Please try again.")),
      );
    });

    // Not awaited: runs on even if the sheet is closed meanwhile.
    unawaited(_moderateAfterPost(
      ref: ref,
      text: text,
      isReply: replyToId != null,
      myId: user.uid,
      postId: widget.postId,
      postOwnerId: widget.ownerId,
      displayName: displayName,
      photoUrl: photoUrl,
      messenger: messenger,
    ));
  }

  Future<void> _moderateAfterPost({
    required DocumentReference ref,
    required String text,
    required bool isReply,
    required String myId,
    // Passed in (not read from `widget`) because this can finish after the
    // sheet has been closed and this State disposed.
    required String postId,
    required String postOwnerId,
    required String displayName,
    required String photoUrl,
    required ScaffoldMessengerState messenger,
  }) async {
    final bool flagged =
        await _isFlaggedByModerationServer('/moderate/text', {'text': text});

    if (flagged) {
      try {
        await ref.delete();
      } catch (_) {}
      messenger.showSnackBar(
        const SnackBar(
          content:
              Text('Your comment was removed because it contains inappropriate '
                  'language.'),
        ),
      );
      return;
    }

    // Replies don't notify the video owner (unchanged behaviour).
    if (isReply) return;
    if (postOwnerId.isEmpty || postOwnerId == myId) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(postOwnerId)
          .collection('notifications')
          .add({
        'type': 'comment',
        'text': text,
        'fromId': myId,
        'fromName': displayName,
        'fromPhoto': photoUrl,
        'postId': postId,
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // A missed notification shouldn't bother the commenter.
    }
  }

  Future<void> _setReaction(DocumentReference ref,
      Map<String, dynamic> reactions, String type) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final String? current = reactions[user.uid] as String?;
    if (current == type) {
      await ref.update({'reactions.${user.uid}': FieldValue.delete()});
    } else {
      await ref.update({'reactions.${user.uid}': type});
    }
  }

  void _openReactionPicker(
      DocumentReference ref, Map<String, dynamic> reactions) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF222222),
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: kReactions.entries.map((entry) {
              final int i = kReactions.keys.toList().indexOf(entry.key);
              return _AnimatedEmoji(
                emoji: entry.value,
                delayMs: i * 60,
                onTap: () {
                  Navigator.pop(ctx);
                  _setReaction(ref, reactions, entry.key);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  // Long-press menu for a comment or reply. What shows depends on who you
  // are:
  //   - the author:      Delete
  //   - the video owner: Hide / Unhide, and Delete (for others' comments)
  //   - anyone else:     Report
  void _showCommentOptions(
    DocumentReference ref,
    Map<String, dynamic> data, {
    required bool isReply,
  }) {
    final String? myId = _myId;
    if (myId == null) return;
    final bool isMine = data['userId'] == myId;
    final bool iOwnTheVideo = myId == widget.ownerId;
    final bool isHidden = data['hidden'] == true;
    final String noun = isReply ? 'reply' : 'comment';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final List<Widget> items = [
          if (iOwnTheVideo && !isMine)
            ListTile(
              leading: Icon(
                isHidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: Colors.white,
              ),
              title: Text(
                isHidden ? 'Unhide $noun' : 'Hide $noun',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                isHidden
                    ? 'Everyone will be able to see it again.'
                    : 'Only you and the person who wrote it will see it.',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _setHidden(ref, !isHidden, noun);
              },
            ),
          if (isMine || iOwnTheVideo)
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text('Delete $noun',
                  style: const TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(ref, noun);
              },
            ),
          if (!isMine)
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: Colors.white70),
              title: Text('Report $noun',
                  style: const TextStyle(color: Colors.white70)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showCommentReportSheet(ref, data);
              },
            ),
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: items),
          ),
        );
      },
    );
  }

  Future<void> _setHidden(
      DocumentReference ref, bool hidden, String noun) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.update({
        'hidden': hidden,
        'hiddenAt': hidden ? FieldValue.serverTimestamp() : FieldValue.delete(),
      });
      messenger.showSnackBar(SnackBar(
        content: Text(hidden
            ? 'The $noun is now hidden from others.'
            : 'The $noun is visible to everyone again.'),
      ));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't update it. Please try again.")),
      );
    }
  }

  Future<void> _confirmDelete(DocumentReference ref, String noun) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text('Delete this $noun?',
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          "This can't be undone.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Deleting a top-level comment removes the comment itself; its replies
    // become unreachable in the app (Firestore can't cascade-delete a
    // subcollection without a server).
    try {
      await ref.delete();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't delete it. Please try again.")),
      );
    }
  }

  // Shows a reason picker and writes a 'reports' document for a comment.
  void _showCommentReportSheet(
      DocumentReference commentRef, Map<String, dynamic> data) {
    const List<String> reasons = [
      'Nudity or sexual content',
      'Hate speech or harassment',
      'Violence or dangerous content',
      'Spam or scam',
      'Something else',
    ];
    final String commentOwnerId = data['userId'] ?? '';

    showModalBottomSheet(
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
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Report this comment',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              ...reasons.map((reason) => ListTile(
                    title: Text(reason,
                        style: const TextStyle(color: Colors.white70)),
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      final String? myId =
                          FirebaseAuth.instance.currentUser?.uid;
                      if (myId == null) return;
                      try {
                        await FirebaseFirestore.instance
                            .collection('reports')
                            .add({
                          'targetType': 'comment',
                          'targetId': commentRef.id,
                          'parentPostId': widget.postId,
                          'targetOwnerId': commentOwnerId,
                          'reporterId': myId,
                          'reason': reason,
                          'status': 'pending',
                          'createdAt': FieldValue.serverTimestamp(),
                        });
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Report submitted. Thank you.')),
                          );
                        }
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Could not submit report. Try again.')),
                          );
                        }
                      }
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final String? myId = _myId;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Comments',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _commentsStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  );
                }

                final List<QueryDocumentSnapshot> comments =
                    snapshot.data!.docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final String commentUserId = data['userId'] ?? '';
                  return !_blockedIds.contains(commentUserId) &&
                      _isCommentVisibleTo(data,
                          myId: myId, postOwnerId: widget.ownerId);
                }).toList();

                if (comments.isEmpty) {
                  return Center(
                    child: Text(
                      'No comments yet. Say something!',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                  );
                }

                // The comment the notification was about (newest first, so
                // the first match is the latest one from that person).
                int spotlightIndex = -1;
                final String? hlUser = widget.highlightUserId;
                if (hlUser != null && hlUser.isNotEmpty) {
                  final String hlText = (widget.highlightText ?? '').trim();
                  spotlightIndex = comments.indexWhere((d) {
                    final m = d.data() as Map<String, dynamic>;
                    return m['userId'] == hlUser &&
                        (hlText.isEmpty ||
                            (m['text'] ?? '').toString().trim() == hlText);
                  });
                  if (spotlightIndex < 0) {
                    spotlightIndex = comments.indexWhere((d) =>
                        (d.data() as Map<String, dynamic>)['userId'] == hlUser);
                  }
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: comments.length,
                  itemBuilder: (context, index) {
                    final doc = comments[index];
                    final Widget tile = _CommentTile(
                      // Keyed by doc id so each tile keeps its own state
                      // (open replies, reply stream) when comments are
                      // added, hidden or deleted above it.
                      key: ValueKey(doc.id),
                      commentRef: doc.reference,
                      data: doc.data() as Map<String, dynamic>,
                      myId: myId,
                      postOwnerId: widget.ownerId,
                      blockedIds: _blockedIds,
                      onReply: _startReply,
                      onReact: _openReactionPicker,
                      onOptions: _showCommentOptions,
                    );
                    if (index != spotlightIndex) return tile;
                    return _CommentSpotlight(
                      key: ValueKey('spotlight_${doc.id}'),
                      child: tile,
                    );
                  },
                );
              },
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          if (_replyToName != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.white.withOpacity(0.05),
              child: Row(
                children: [
                  Text(
                    'Replying to $_replyToName',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _cancelReply,
                    child:
                        const Icon(Icons.close, color: Colors.grey, size: 18),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 8 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentController,
                    focusNode: _focusNode,
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: _replyToName != null
                          ? 'Write a reply...'
                          : 'Add a comment...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey[900],
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendComment,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF3A8DFF), Color(0xFF1565C0)],
                      ),
                    ),
                    child:
                        const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Shows the distinct emoji reactions present plus the total count
class _ReactionSummary extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final VoidCallback onTap;
  final double emojiSize;

  const _ReactionSummary({
    required this.reactions,
    required this.onTap,
    this.emojiSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    final List<String> distinctTypes =
        reactions.values.map((e) => e.toString()).toSet().toList();
    final int count = reactions.length;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          if (distinctTypes.isEmpty)
            Icon(Icons.add_reaction_outlined,
                color: Colors.grey[500], size: emojiSize + 2)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: distinctTypes
                  .take(3)
                  .map((type) => Text(
                        kReactions[type] ?? '',
                        style: TextStyle(fontSize: emojiSize),
                      ))
                  .toList(),
            ),
          if (count > 0)
            Text(
              '$count',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// Small "Hidden" tag shown to the video owner on a comment/reply they hid.
class _HiddenCommentTag extends StatelessWidget {
  const _HiddenCommentTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off_outlined, color: Colors.white54, size: 11),
          SizedBox(width: 3),
          Text('Hidden', style: TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ),
    );
  }
}

typedef _CommentOptionsCallback = void Function(
  DocumentReference ref,
  Map<String, dynamic> data, {
  required bool isReply,
});

// A single comment with emoji reactions, a reply button, and its replies
class _CommentTile extends StatefulWidget {
  final DocumentReference commentRef;
  final Map<String, dynamic> data;
  final String? myId;
  final String postOwnerId;
  final Set<String> blockedIds;
  final void Function(String commentId, String name) onReply;
  final void Function(DocumentReference ref, Map<String, dynamic> reactions)
      onReact;
  final _CommentOptionsCallback onOptions;

  const _CommentTile({
    super.key,
    required this.commentRef,
    required this.data,
    required this.myId,
    required this.postOwnerId,
    required this.blockedIds,
    required this.onReply,
    required this.onReact,
    required this.onOptions,
  });

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  bool _showReplies = false;

  // One replies stream per tile, built once (not in build()) - used both
  // for the "View N replies" count and for the reply list itself.
  late final Stream<QuerySnapshot> _repliesStream = widget.commentRef
      .collection('replies')
      .orderBy('createdAt', descending: false)
      .snapshots();

  List<QueryDocumentSnapshot> _visibleReplies(QuerySnapshot? snap) {
    return (snap?.docs ?? []).where((d) {
      final data = d.data() as Map<String, dynamic>;
      return !widget.blockedIds.contains(data['userId'] ?? '') &&
          _isCommentVisibleTo(data,
              myId: widget.myId, postOwnerId: widget.postOwnerId);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final String name = widget.data['displayName'] ?? 'User';
    final String text = widget.data['text'] ?? '';
    final String photoUrl = widget.data['photoUrl'] ?? '';
    final Map<String, dynamic> reactions =
        (widget.data['reactions'] as Map<String, dynamic>?) ?? {};
    // Only the video owner is ever shown the "Hidden" look.
    final bool showAsHidden = widget.data['hidden'] == true &&
        widget.myId != null &&
        widget.myId == widget.postOwnerId;

    return StreamBuilder<QuerySnapshot>(
      stream: _repliesStream,
      builder: (context, repliesSnap) {
        final List<QueryDocumentSnapshot> replies =
            _visibleReplies(repliesSnap.data);
        final int replyCount = replies.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: () => widget
                  .onOptions(widget.commentRef, widget.data, isReply: false),
              child: Opacity(
                opacity: showAsHidden ? 0.5 : 1,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.grey[800],
                        backgroundImage:
                            photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                        child: photoUrl.isEmpty
                            ? Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (showAsHidden) const _HiddenCommentTag(),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              text,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () => widget.onReply(
                                      widget.commentRef.id, name),
                                  child: Text(
                                    'Reply',
                                    style: TextStyle(
                                      color: Colors.grey[400],
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                if (replyCount > 0)
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _showReplies = !_showReplies),
                                    child: Text(
                                      _showReplies
                                          ? 'Hide replies'
                                          : 'View $replyCount ${replyCount == 1 ? "reply" : "replies"}',
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      _ReactionSummary(
                        reactions: reactions,
                        onTap: () =>
                            widget.onReact(widget.commentRef, reactions),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_showReplies)
              Column(
                children: replies.map((replyDoc) {
                  return _ReplyTile(
                    key: ValueKey(replyDoc.id),
                    replyRef: replyDoc.reference,
                    data: replyDoc.data() as Map<String, dynamic>,
                    myId: widget.myId,
                    postOwnerId: widget.postOwnerId,
                    onReact: widget.onReact,
                    onOptions: widget.onOptions,
                  );
                }).toList(),
              ),
          ],
        );
      },
    );
  }
}

// A single reply (indented) with emoji reactions
class _ReplyTile extends StatelessWidget {
  final DocumentReference replyRef;
  final Map<String, dynamic> data;
  final String? myId;
  final String postOwnerId;
  final void Function(DocumentReference ref, Map<String, dynamic> reactions)
      onReact;
  final _CommentOptionsCallback onOptions;

  const _ReplyTile({
    super.key,
    required this.replyRef,
    required this.data,
    required this.myId,
    required this.postOwnerId,
    required this.onReact,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final String name = data['displayName'] ?? 'User';
    final String text = data['text'] ?? '';
    final String photoUrl = data['photoUrl'] ?? '';
    final Map<String, dynamic> reactions =
        (data['reactions'] as Map<String, dynamic>?) ?? {};
    final bool showAsHidden =
        data['hidden'] == true && myId != null && myId == postOwnerId;

    return GestureDetector(
      onLongPress: () => onOptions(replyRef, data, isReply: true),
      child: Opacity(
        opacity: showAsHidden ? 0.5 : 1,
        child: Padding(
          padding:
              const EdgeInsets.only(left: 56, right: 16, top: 6, bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: Colors.grey[800],
                backgroundImage:
                    photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                child: photoUrl.isEmpty
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (showAsHidden) const _HiddenCommentTag(),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      text,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
              _ReactionSummary(
                reactions: reactions,
                onTap: () => onReact(replyRef, reactions),
                emojiSize: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

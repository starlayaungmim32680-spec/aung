// Part of home_screen.dart - split out 9 Oct 2026 (step 2 of breaking up
// the big file, a piece at a time). Everything about comments on a video:
// the comments bottom sheet (_CommentsSheet: list, composer, replies,
// reactions, hide/delete/report options, notification spotlight), the
// comment and reply rows (_CommentTile, _ReplyTile), the reaction summary
// chip, the "Hidden" tag, and the visibility helpers for hidden comments.
//
// 10 Oct 2026 - replies, Facebook style:
//   - every reply row has its own Reply button. Replying to a reply stays
//     in the SAME comment's thread (one level deep, like Facebook/TikTok)
//     and the new reply shows "@Name" in Fly blue in front of the text
//     (stored as replyToUserId / replyToName on the reply doc);
//   - a reply now notifies people (type 'reply' in users/{uid}/
//     notifications), after the moderation check passes: the person
//     replied to, the comment's author and the video owner - each at most
//     once, never yourself, never someone blocked either way. Nobody else
//     in the thread is notified (keeps it cheap and quiet);
//   - opening that notification opens the comments with the thread's
//     comment spotlighted and its replies already open.
//   - 11 Oct 2026: every comment / reply notification also asks the
//     Worker (/activity-push, call_push_service.dart) to ping that
//     person's phone, so it shows in the notification bar even when Fly
//     is closed.
//
// 10 Oct 2026 (later) - TikTok/Facebook-style look:
//   - header "12 comments" + close button;
//   - rows: avatar, grey name (+ gradient "Creator" pill for the video
//     owner), white text, then "2h  Reply" and a Facebook-style emoji chip;
//   - a heart on the right: tap = ❤️ (pop + haptic), long-press = any emoji;
//   - replies tucked under "── View 3 replies ⌄" / "── Hide ⌃";
//   - tap a name/avatar/@mention to open that profile;
//   - quick-emoji bar and my avatar by the composer; send button lights up
//     in the Fly gradient only when there's text.
//
// 21 Oct 2026 - text moderation BEFORE sending: a comment / reply is now
// checked by ModerationService (on-device word list + the Worker's
// /moderate-text, ~0.2 s, Zawgyi/Unicode Burmese) before it is written,
// so a bad comment never appears, not even for a moment. While that runs
// the send button shows a small spinner (_sending, a ValueNotifier, so
// only the button rebuilds). The slower fly-moderation (Render) check
// used to run afterwards; removed the same night (it slept, failed open
// and its OpenAI key had been revoked).
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
  // Opened from a reply notification: spotlight this comment (by id) and
  // open its replies straight away.
  final String? highlightCommentId;

  const _CommentsSheet({
    required this.postId,
    required this.ownerId,
    this.highlightUserId,
    this.highlightText,
    this.highlightCommentId,
  });

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // Who the next send replies to. _replyToCommentId is always the
  // top-level comment (the thread); _replyToUserId is the person actually
  // being answered (the comment's author, or a reply's author when
  // replying to a reply); _replyToCommentOwnerId is the thread owner.
  String? _replyToCommentId;
  String? _replyToName;
  String? _replyToUserId;
  String? _replyToCommentOwnerId;
  // True when answering a reply (not the comment itself) - the new reply
  // then carries "@Name".
  bool _replyIsToReply = false;

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
    _commentCount.dispose();
    _sending.dispose();
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

  void _startReply(
    String commentId,
    String name, {
    required String toUserId,
    required String commentOwnerId,
    bool isReplyToReply = false,
  }) {
    HapticFeedback.selectionClick();
    setState(() {
      _replyToCommentId = commentId;
      _replyToName = name;
      _replyToUserId = toUserId;
      _replyToCommentOwnerId = commentOwnerId;
      _replyIsToReply = isReplyToReply;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToCommentId = null;
      _replyToName = null;
      _replyToUserId = null;
      _replyToCommentOwnerId = null;
      _replyIsToReply = false;
    });
  }

  // True while ModerationService checks a comment before it is sent - the
  // send button shows a spinner and ignores taps.
  final ValueNotifier<bool> _sending = ValueNotifier<bool>(false);

  // Sends a comment (or a reply).
  //
  // Why it used to feel slow: it waited for the moderation server (a free
  // Render instance that can take ~50s to wake up) and then a profile
  // read, all BEFORE writing anything - and the input stayed locked with a
  // spinner the whole time. Now:
  //   1. ModerationService checks the text first (21 Oct 2026: on-device
  //      word list + the Worker's /moderate-text - about 0.2 s, never the
  //      sleeping Render server); a refused comment is never written;
  //   2. the comment is written straight away and the input clears at
  //      once - Firestore shows it in the list immediately, even before
  //      the server confirms;
  //   3. the notifications are sent in the background afterwards
  //      (_moderateAfterPost - the name is historical: the Render
  //      re-check it used to do was removed 21 Oct 2026).
  Future<void> _sendComment() async {
    final User? user = FirebaseAuth.instance.currentUser;
    final String text = _commentController.text.trim();
    if (user == null || text.isEmpty) return;

    if (_sending.value) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    _sending.value = true;
    final ModerationResult check =
        await ModerationService.checkText(text, ModerationKind.comment);
    if (!mounted) return;
    _sending.value = false;
    if (!check.ok) {
      HapticFeedback.mediumImpact();
      messenger.showSnackBar(
        SnackBar(content: Text(check.message!)),
      );
      return;
    }

    final String? replyToId = _replyToCommentId;
    final String? replyToName = _replyToName;
    final String? replyToUserId = _replyToUserId;
    final String? commentOwnerId = _replyToCommentOwnerId;
    final bool replyIsToReply = _replyIsToReply;
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
      // Replying to a reply: shown as "@Name" in front of the text.
      if (replyIsToReply && replyToUserId != null && replyToName != null) ...{
        'replyToUserId': replyToUserId,
        'replyToName': replyToName,
      },
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
      commentId: replyToId,
      commentOwnerId: commentOwnerId,
      replyToUserId: replyToUserId,
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
    // Replies only: the thread's comment id and author, and the person
    // directly answered.
    String? commentId,
    String? commentOwnerId,
    String? replyToUserId,
    required String myId,
    // Passed in (not read from `widget`) because this can finish after the
    // sheet has been closed and this State disposed.
    required String postId,
    required String postOwnerId,
    required String displayName,
    required String photoUrl,
    required ScaffoldMessengerState messenger,
  }) async {
    // (21 Oct 2026: the old fly-moderation / Render re-check that used to
    // run here is gone - the comment was already checked by
    // ModerationService BEFORE it was written. This now only sends the
    // notifications.)
    if (isReply) {
      await _notifyReply(
        text: text,
        myId: myId,
        postId: postId,
        postOwnerId: postOwnerId,
        commentId: commentId ?? '',
        commentOwnerId: commentOwnerId ?? '',
        replyToUserId: replyToUserId ?? '',
        displayName: displayName,
        photoUrl: photoUrl,
      );
      return;
    }
    if (postOwnerId.isEmpty || postOwnerId == myId) return;
    try {
      final DocumentReference notifRef = await FirebaseFirestore.instance
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
      // Phone notification too (works with Fly closed). Best-effort.
      unawaited(sendActivityPush(
          receiverId: postOwnerId, notificationId: notifRef.id));
    } catch (_) {
      // A missed notification shouldn't bother the commenter.
    }
  }

  // Reply notifications (10 Oct 2026). At most three people, each once:
  //   - the person I answered and the thread's comment author -> 'you'
  //     ("replied to your comment"),
  //   - the video owner, if not already one of those -> 'video'
  //     ("replied to a comment on your video").
  // Never me, never anyone blocked either way. Static so it still runs
  // after the sheet is closed. One Firestore write per person.
  static Future<void> _notifyReply({
    required String text,
    required String myId,
    required String postId,
    required String postOwnerId,
    required String commentId,
    required String commentOwnerId,
    required String replyToUserId,
    required String displayName,
    required String photoUrl,
  }) async {
    if (commentId.isEmpty) return;
    final Map<String, String> recipients = {};
    void add(String uid, String kind) {
      if (uid.isEmpty || uid == myId) return;
      if (BlockService.instance.isHidden(uid)) return;
      recipients.putIfAbsent(uid, () => kind);
    }

    add(replyToUserId, 'you');
    add(commentOwnerId, 'you');
    add(postOwnerId, 'video');

    final users = FirebaseFirestore.instance.collection('users');
    for (final MapEntry<String, String> r in recipients.entries) {
      try {
        final DocumentReference notifRef =
            await users.doc(r.key).collection('notifications').add({
          'type': 'reply',
          'replyKind': r.value,
          'text': text,
          'fromId': myId,
          'fromName': displayName,
          'fromPhoto': photoUrl,
          'postId': postId,
          'commentId': commentId,
          'seen': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
        unawaited(
            sendActivityPush(receiverId: r.key, notificationId: notifRef.id));
      } catch (_) {
        // A missed notification shouldn't bother the person replying.
      }
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
      // A NEW reaction (not a swap of my emoji) tells the comment's
      // author (13 Oct 2026). Not awaited - the heart must feel instant.
      if (current == null) {
        final Map<String, String> profile = await _myProfileFuture;
        unawaited(_notifyCommentReaction(
          ref: ref,
          emoji: kReactions[type] ?? '❤️',
          postId: widget.postId,
          myId: user.uid,
          displayName: profile['name']!,
          photoUrl: profile['photo']!,
        ));
      }
    }
  }

  // Comment / reply reaction notifications (13 Oct 2026), Facebook
  // style: "X reacted 😂 to your comment: ...". Goes to the author of the
  // comment or reply I reacted to - never to me, never between blocked
  // people. Each comment notifies at most ONCE per app session, so
  // tapping the heart on / off / on doesn't spam anyone (the 🔔 list also
  // keeps only the newest row per person + comment). Static so it still
  // runs after the sheet is closed.
  static final Set<String> _reactionNotified = <String>{};

  static Future<void> _notifyCommentReaction({
    required DocumentReference ref,
    required String emoji,
    required String postId,
    required String myId,
    required String displayName,
    required String photoUrl,
  }) async {
    if (!_reactionNotified.add(ref.path)) return;
    try {
      // The comment is on screen, so the cached copy is normally there.
      DocumentSnapshot snap;
      try {
        snap = await ref.get(const GetOptions(source: Source.cache));
      } catch (_) {
        snap = await ref.get();
      }
      final Map<String, dynamic>? data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      final String ownerId = (data['userId'] as String?) ?? '';
      if (ownerId.isEmpty || ownerId == myId) return;
      if (BlockService.instance.isHidden(ownerId)) return;

      // A reply lives in comments/{commentId}/replies/{replyId}: the
      // spotlight opens its thread's comment.
      final bool isReplyDoc = ref.parent.id == 'replies';
      final String commentId =
          isReplyDoc ? (ref.parent.parent?.id ?? '') : ref.id;
      String preview = ((data['text'] as String?) ?? '').trim();
      if (preview.length > 80) preview = '${preview.substring(0, 80)}…';

      final DocumentReference notifRef = await FirebaseFirestore.instance
          .collection('users')
          .doc(ownerId)
          .collection('notifications')
          .add({
        'type': 'comment_reaction',
        // `text` = the emoji (like a video 'reaction'), `commentText` =
        // what the comment said.
        'text': emoji,
        'commentText': preview,
        'isReply': isReplyDoc,
        'targetId': ref.id,
        'fromId': myId,
        'fromName': displayName,
        'fromPhoto': photoUrl,
        'postId': postId,
        'commentId': commentId,
        'seen': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      unawaited(
          sendActivityPush(receiverId: ownerId, notificationId: notifRef.id));
    } catch (_) {
      // A missed notification shouldn't bother the person reacting.
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

  // Header count ("12 comments"). A ValueNotifier so only the header
  // rebuilds when the number changes - not the whole sheet (Fly's
  // flicker rule).
  final ValueNotifier<int> _commentCount = ValueNotifier<int>(-1);

  void _publishCount(int n) {
    if (_commentCount.value == n) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commentCount.value = n;
    });
  }

  // TikTok-style heart: one tap = ❤️ (tap again to take it back, or to
  // swap whatever emoji I had for ❤️); long-press = the full emoji picker.
  Future<void> _quickLove(
      DocumentReference ref, Map<String, dynamic> reactions) async {
    final String? mine = reactions[_myId] as String?;
    if (mine != null && mine != 'love') {
      // Had another emoji: tapping the heart removes my reaction.
      await _setReaction(ref, reactions, mine);
      return;
    }
    await _setReaction(ref, reactions, 'love');
  }

  // Quick emojis above the composer - one tap drops it into the text.
  static const List<String> _quickEmojis = [
    '😂',
    '❤️',
    '🔥',
    '👏',
    '😍',
    '😮',
    '😢',
    '🙏'
  ];

  void _insertEmoji(String emoji) {
    HapticFeedback.selectionClick();
    final TextEditingValue v = _commentController.value;
    final int start = v.selection.isValid ? v.selection.start : v.text.length;
    final int end = v.selection.isValid ? v.selection.end : v.text.length;
    final String text = v.text.replaceRange(start, end, emoji);
    _commentController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  void _openProfile(String userId) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PublicProfileScreen(userId: userId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final String? myId = _myId;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header: "12 comments" + close, TikTok style. Full width, so
          // the close button sits at the sheet's right edge instead of on
          // top of the title.
          SizedBox(
            width: double.infinity,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: _commentCount,
                  builder: (context, n, _) => Text(
                    n < 0
                        ? 'Comments'
                        : n == 0
                            ? 'Comments'
                            : '$n ${n == 1 ? "comment" : "comments"}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white70, size: 22),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _commentsStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF9C4DFF), strokeWidth: 2.5),
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
                _publishCount(comments.length);

                if (comments.isEmpty) {
                  return const _EmptyComments();
                }

                // The comment the notification was about (newest first, so
                // the first match is the latest one from that person).
                int spotlightIndex = -1;
                final String? hlComment = widget.highlightCommentId;
                final String? hlUser = widget.highlightUserId;
                if (hlComment != null && hlComment.isNotEmpty) {
                  // A reply notification: the thread's comment, by id.
                  spotlightIndex =
                      comments.indexWhere((d) => d.id == hlComment);
                } else if (hlUser != null && hlUser.isNotEmpty) {
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
                  padding: const EdgeInsets.only(top: 6, bottom: 12),
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
                      onQuickLove: _quickLove,
                      onOptions: _showCommentOptions,
                      onOpenProfile: _openProfile,
                      initiallyShowReplies:
                          hlComment != null && doc.id == hlComment,
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
          const Divider(color: Colors.white10, height: 1),
          // Quick emoji bar (Fly extra) - one tap adds it to the text.
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: _quickEmojis
                  .map((e) => GestureDetector(
                        onTap: () => _insertEmoji(e),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 8),
                          child: Text(e, style: const TextStyle(fontSize: 22)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          if (_replyToName != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              color: Colors.white.withValues(alpha: 0.05),
              child: Row(
                children: [
                  Icon(Icons.reply_rounded, color: Colors.grey[400], size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: 'Replying to ',
                        children: [
                          TextSpan(
                            text: _replyToName,
                            style: const TextStyle(
                              color: Color(0xFF3A8DFF),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ),
                  GestureDetector(
                    onTap: _cancelReply,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, color: Colors.grey, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 6,
              bottom: 8 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                // My own avatar next to the box, like TikTok/Facebook.
                FutureBuilder<Map<String, String>>(
                  future: _myProfileFuture,
                  builder: (context, snap) => _CommentAvatar(
                    name: snap.data?['name'] ?? '',
                    photoUrl: snap.data?['photo'] ?? '',
                    radius: 17,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _commentController,
                    focusNode: _focusNode,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: _replyToName != null
                          ? 'Reply to $_replyToName...'
                          : 'Add a comment...',
                      hintStyle: TextStyle(color: Colors.grey[600]),
                      filled: true,
                      fillColor: const Color(0xFF242424),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Send lights up (Fly gradient) only when there's text;
                // a small spinner while the text is being checked.
                ValueListenableBuilder<bool>(
                  valueListenable: _sending,
                  builder: (context, sending, _) =>
                      ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _commentController,
                    builder: (context, v, _) {
                      final bool ready = v.text.trim().isNotEmpty;
                      return GestureDetector(
                        onTap: ready && !sending
                            ? () {
                                HapticFeedback.lightImpact();
                                _sendComment();
                              }
                            : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ready ? null : const Color(0xFF2A2A2A),
                            gradient: ready
                                ? const LinearGradient(
                                    colors: [
                                      Color(0xFFFF4B6E),
                                      Color(0xFF9C4DFF),
                                      Color(0xFF3A8DFF),
                                    ],
                                  )
                                : null,
                          ),
                          child: sending
                              ? const Padding(
                                  padding: EdgeInsets.all(11),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(Icons.arrow_upward_rounded,
                                  color: ready ? Colors.white : Colors.white38,
                                  size: 22),
                        ),
                      );
                    },
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

// ---------------------------------------------------------------------------
// Small building blocks for the comment rows (10 Oct 2026 redesign,
// TikTok/Facebook style with Fly touches).
// ---------------------------------------------------------------------------

// "now", "5m", "2h", "3d", "2w", then a short date.
String _commentTimeAgo(dynamic ts) {
  if (ts is! Timestamp) return 'now';
  final DateTime t = ts.toDate();
  final Duration d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 35) return '${(d.inDays / 7).floor()}w';
  return '${t.day}/${t.month}/${t.year % 100}';
}

// Shown when a video has no comments yet.
class _EmptyComments extends StatelessWidget {
  const _EmptyComments();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF), Color(0xFF3A8DFF)],
            ).createShader(r),
            child: const Icon(Icons.chat_bubble_outline_rounded,
                color: Colors.white, size: 44),
          ),
          const SizedBox(height: 12),
          const Text(
            'No comments yet',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Be the first to say something ✨',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _CommentAvatar extends StatelessWidget {
  final String name;
  final String photoUrl;
  final double radius;

  const _CommentAvatar({
    required this.name,
    required this.photoUrl,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF2A2A2A),
      backgroundImage:
          photoUrl.isNotEmpty ? CachedNetworkImageProvider(photoUrl) : null,
      child: photoUrl.isEmpty
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: radius * 0.8,
              ),
            )
          : null,
    );
  }
}

// Little "Creator" pill next to the video owner's name (Fly gradient).
class _CreatorTag extends StatelessWidget {
  const _CreatorTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: const LinearGradient(
          colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
        ),
      ),
      child: const Text(
        'Creator',
        style: TextStyle(
            color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700),
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

// Facebook-style chip of the emojis people used (only when it's more
// than plain hearts): "😂❤️ 3".
class _EmojiChip extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final VoidCallback onTap;

  const _EmojiChip({required this.reactions, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final List<String> types =
        reactions.values.map((e) => e.toString()).toSet().toList();
    if (types.isEmpty || (types.length == 1 && types.first == 'love')) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 14),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0xFF242424),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...types.take(3).map((t) => Text(kReactions[t] ?? '',
                style: const TextStyle(fontSize: 11))),
            const SizedBox(width: 3),
            Text('${reactions.length}',
                style: TextStyle(color: Colors.grey[400], fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// TikTok-style heart on the right of each row: tap = ❤️ (with a little
// pop + haptic), long-press = choose any emoji. If I reacted with another
// emoji, that emoji shows instead of the heart.
class _CommentLikeButton extends StatefulWidget {
  final Map<String, dynamic> reactions;
  final String? myId;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool small;

  const _CommentLikeButton({
    required this.reactions,
    required this.myId,
    required this.onTap,
    required this.onLongPress,
    this.small = false,
  });

  @override
  State<_CommentLikeButton> createState() => _CommentLikeButtonState();
}

class _CommentLikeButtonState extends State<_CommentLikeButton> {
  double _scale = 1;

  void _pop() {
    HapticFeedback.lightImpact();
    setState(() => _scale = 1.35);
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) setState(() => _scale = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? mine = widget.reactions[widget.myId] as String?;
    final int count = widget.reactions.length;
    final double size = widget.small ? 16 : 18;

    final Widget icon;
    if (mine == null) {
      icon = Icon(Icons.favorite_border_rounded,
          color: Colors.grey[500], size: size);
    } else if (mine == 'love') {
      icon = ShaderMask(
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
        ).createShader(r),
        child: Icon(Icons.favorite_rounded, color: Colors.white, size: size),
      );
    } else {
      icon =
          Text(kReactions[mine] ?? '❤️', style: TextStyle(fontSize: size - 2));
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _pop();
        widget.onTap();
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        widget.onLongPress();
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 2, top: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _scale,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOutBack,
              child: icon,
            ),
            const SizedBox(height: 2),
            Text(
              count > 0 ? '$count' : '',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _CommentOptionsCallback = void Function(
  DocumentReference ref,
  Map<String, dynamic> data, {
  required bool isReply,
});

// Starts a reply in the composer (see _CommentsSheetState._startReply).
typedef _StartReplyCallback = void Function(
  String commentId,
  String name, {
  required String toUserId,
  required String commentOwnerId,
  bool isReplyToReply,
});

typedef _ReactCallback = void Function(
    DocumentReference ref, Map<String, dynamic> reactions);

// One comment + its replies (TikTok layout: avatar, name, text, then
// "2h  Reply" and the heart on the right; replies tucked under a
// "── View 3 replies ⌄" line).
class _CommentTile extends StatefulWidget {
  final DocumentReference commentRef;
  final Map<String, dynamic> data;
  final String? myId;
  final String postOwnerId;
  final Set<String> blockedIds;
  final _StartReplyCallback onReply;
  final _ReactCallback onReact;
  final _ReactCallback onQuickLove;
  final _CommentOptionsCallback onOptions;
  final void Function(String userId) onOpenProfile;
  // Opened from a reply notification: show this thread's replies at once.
  final bool initiallyShowReplies;

  const _CommentTile({
    super.key,
    required this.commentRef,
    required this.data,
    required this.myId,
    required this.postOwnerId,
    required this.blockedIds,
    required this.onReply,
    required this.onReact,
    required this.onQuickLove,
    required this.onOptions,
    required this.onOpenProfile,
    this.initiallyShowReplies = false,
  });

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  late bool _showReplies = widget.initiallyShowReplies;

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
    final String userId = (widget.data['userId'] as String?) ?? '';
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
              behavior: HitTestBehavior.opaque,
              onLongPress: () => widget
                  .onOptions(widget.commentRef, widget.data, isReply: false),
              child: Opacity(
                opacity: showAsHidden ? 0.5 : 1,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => widget.onOpenProfile(userId),
                        child: _CommentAvatar(
                            name: name, photoUrl: photoUrl, radius: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: GestureDetector(
                                    onTap: () => widget.onOpenProfile(userId),
                                    child: Text(
                                      name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                                if (userId.isNotEmpty &&
                                    userId == widget.postOwnerId)
                                  const _CreatorTag(),
                                if (showAsHidden) const _HiddenCommentTag(),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(
                                  _commentTimeAgo(widget.data['createdAt']),
                                  style: TextStyle(
                                      color: Colors.grey[600], fontSize: 12),
                                ),
                                const SizedBox(width: 16),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => widget.onReply(
                                    widget.commentRef.id,
                                    name,
                                    toUserId: userId,
                                    commentOwnerId: userId,
                                  ),
                                  child: Text(
                                    'Reply',
                                    style: TextStyle(
                                      color: Colors.grey[400],
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                _EmojiChip(
                                  reactions: reactions,
                                  onTap: () => widget.onReact(
                                      widget.commentRef, reactions),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      _CommentLikeButton(
                        reactions: reactions,
                        myId: widget.myId,
                        onTap: () =>
                            widget.onQuickLove(widget.commentRef, reactions),
                        onLongPress: () =>
                            widget.onReact(widget.commentRef, reactions),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_showReplies)
              ...replies.map((replyDoc) {
                final Map<String, dynamic> r =
                    replyDoc.data() as Map<String, dynamic>;
                return _ReplyTile(
                  key: ValueKey(replyDoc.id),
                  replyRef: replyDoc.reference,
                  data: r,
                  myId: widget.myId,
                  postOwnerId: widget.postOwnerId,
                  onReact: widget.onReact,
                  onQuickLove: widget.onQuickLove,
                  onOptions: widget.onOptions,
                  onOpenProfile: widget.onOpenProfile,
                  // Answering a reply stays in this comment's thread.
                  onReply: () => widget.onReply(
                    widget.commentRef.id,
                    (r['displayName'] as String?) ?? 'User',
                    toUserId: (r['userId'] as String?) ?? '',
                    commentOwnerId: userId,
                    isReplyToReply: true,
                  ),
                );
              }),
            if (replyCount > 0)
              _RepliesToggle(
                open: _showReplies,
                count: replyCount,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _showReplies = !_showReplies);
                },
              ),
          ],
        );
      },
    );
  }
}

// "── View 3 replies ⌄" / "── Hide ⌃" under a comment (TikTok style).
class _RepliesToggle extends StatelessWidget {
  final bool open;
  final int count;
  final VoidCallback onTap;

  const _RepliesToggle({
    required this.open,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color c = Colors.grey[500]!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(64, 4, 16, 8),
        child: Row(
          children: [
            Container(width: 24, height: 1, color: Colors.white24),
            const SizedBox(width: 8),
            Text(
              open ? 'Hide' : 'View $count ${count == 1 ? "reply" : "replies"}',
              style: TextStyle(
                  color: c, fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child:
                  Icon(Icons.keyboard_arrow_down_rounded, color: c, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

// A single reply (indented) - same layout as a comment, smaller, with its
// own Reply button and heart. A reply to a reply shows "@Name" in Fly
// blue first (10 Oct 2026).
class _ReplyTile extends StatelessWidget {
  final DocumentReference replyRef;
  final Map<String, dynamic> data;
  final String? myId;
  final String postOwnerId;
  final _ReactCallback onReact;
  final _ReactCallback onQuickLove;
  final _CommentOptionsCallback onOptions;
  final void Function(String userId) onOpenProfile;
  final VoidCallback onReply;

  const _ReplyTile({
    super.key,
    required this.replyRef,
    required this.data,
    required this.myId,
    required this.postOwnerId,
    required this.onReact,
    required this.onQuickLove,
    required this.onOptions,
    required this.onOpenProfile,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final String name = data['displayName'] ?? 'User';
    final String text = data['text'] ?? '';
    final String photoUrl = data['photoUrl'] ?? '';
    final String userId = (data['userId'] as String?) ?? '';
    final String replyToName = (data['replyToName'] as String?) ?? '';
    final String replyToUserId = (data['replyToUserId'] as String?) ?? '';
    final Map<String, dynamic> reactions =
        (data['reactions'] as Map<String, dynamic>?) ?? {};
    final bool showAsHidden =
        data['hidden'] == true && myId != null && myId == postOwnerId;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => onOptions(replyRef, data, isReply: true),
      child: Opacity(
        opacity: showAsHidden ? 0.5 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(64, 6, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => onOpenProfile(userId),
                child:
                    _CommentAvatar(name: name, photoUrl: photoUrl, radius: 12),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: GestureDetector(
                            onTap: () => onOpenProfile(userId),
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ),
                        if (userId.isNotEmpty && userId == postOwnerId)
                          const _CreatorTag(),
                        if (showAsHidden) const _HiddenCommentTag(),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (replyToName.isNotEmpty)
                            TextSpan(
                              text: '@$replyToName ',
                              style: const TextStyle(
                                color: Color(0xFF3A8DFF),
                                fontWeight: FontWeight.w600,
                              ),
                              recognizer: replyToUserId.isEmpty
                                  ? null
                                  : (TapGestureRecognizer()
                                    ..onTap =
                                        () => onOpenProfile(replyToUserId)),
                            ),
                          TextSpan(text: text),
                        ],
                      ),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14, height: 1.3),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          _commentTimeAgo(data['createdAt']),
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 11.5),
                        ),
                        const SizedBox(width: 16),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onReply,
                          child: Text(
                            'Reply',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _EmojiChip(
                          reactions: reactions,
                          onTap: () => onReact(replyRef, reactions),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _CommentLikeButton(
                reactions: reactions,
                myId: myId,
                small: true,
                onTap: () => onQuickLove(replyRef, reactions),
                onLongPress: () => onReact(replyRef, reactions),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

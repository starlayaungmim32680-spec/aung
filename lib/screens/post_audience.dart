// "Who can watch" - post audiences (24 Oct 2026, step A of 4).
//
// Like Facebook (Public / Friends / Only me) and TikTok (Everyone /
// Friends / Only you), every feed post now has an `audience` field:
//
//   everyone  - anyone (the old behaviour; posts without the field count
//               as this)
//   followers - people who follow the owner, plus the owner's friends
//   friends   - the owner's friends only (Fly friends, friend_service.dart)
//   only_me   - the owner only
//
// Step A (this file + the call sites): the audience is chosen on the Post
// screen and saved; the app hides a post from anyone it isn't meant for
// (`canSeeAudience`, used by `isVideoVisibleTo` in video_upload_service
// .dart and by the profile / hashtag / sound / saved grids); only
// Everyone posts go into Search, can share their sound, and can be shared
// or reposted. NOT done yet (see AI_CONTEXT To-do): B - the Home feed
// still downloads every post and filters on the phone; C - Firestore
// rules don't enforce it yet (a modified app could still read a private
// post); D - changing the audience after posting.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../following_service.dart';
import '../friend_service.dart';

enum PostAudience {
  everyone('everyone', 'Everyone', 'Anyone on Fly', '🌍', Icons.public_rounded),
  followers('followers', 'Followers & Friends',
      'People who follow you, and your friends', '👥', Icons.group_rounded),
  friends(
      'friends', 'Friends', 'Only your friends', '🤝', Icons.handshake_rounded),
  onlyMe('only_me', 'Only me', 'Just you - keep it private', '🔒',
      Icons.lock_rounded);

  const PostAudience(
      this.id, this.label, this.description, this.emoji, this.icon);

  /// The value stored in Firestore (`posts/{id}.audience`).
  final String id;
  final String label;
  final String description;
  final String emoji;
  final IconData icon;

  bool get isPublic => this == PostAudience.everyone;

  static PostAudience fromId(Object? id) {
    for (final PostAudience a in PostAudience.values) {
      if (a.id == id) return a;
    }
    return PostAudience.everyone;
  }
}

/// The audience of a post document (missing field = everyone).
PostAudience audienceOf(Map<String, dynamic>? data) =>
    PostAudience.fromId(data?['audience']);

/// Whether [myUid] may see a post with this data, by its audience only.
/// Uses the live friends / following lists, so it is instant (no reads).
bool canSeeAudience(Map<String, dynamic> data, String? myUid) {
  final PostAudience audience = audienceOf(data);
  if (audience.isPublic) return true;
  final String owner = (data['userId'] as String?) ?? '';
  if (myUid != null && owner == myUid) return true;
  switch (audience) {
    case PostAudience.everyone:
      return true;
    case PostAudience.followers:
      return FollowingService.instance.isFollowing(owner) ||
          FriendService.instance.isFriend(owner);
    case PostAudience.friends:
      return FriendService.instance.isFriend(owner);
    case PostAudience.onlyMe:
      return false;
  }
}

const List<Color> _flyGradient = [
  Color(0xFFFF4B6E),
  Color(0xFF9C4DFF),
  Color(0xFF3A8DFF),
];

/// Bottom sheet to pick an audience. Returns null if dismissed.
Future<PostAudience?> showAudiencePicker(
  BuildContext context,
  PostAudience current,
) {
  return showModalBottomSheet<PostAudience>(
    context: context,
    backgroundColor: const Color(0xFF151419),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Who can watch this video?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Only Everyone videos appear in For You and Search and can be shared.',
              style: TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            for (final PostAudience a in PostAudience.values)
              _AudienceOption(
                audience: a,
                selected: a == current,
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.pop(ctx, a);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _AudienceOption extends StatelessWidget {
  final PostAudience audience;
  final bool selected;
  final VoidCallback onTap;

  const _AudienceOption({
    required this.audience,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: selected
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.04),
              border: Border.all(
                color: selected
                    ? const Color(0xFF9C4DFF)
                    : Colors.white.withValues(alpha: 0.08),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Text(audience.emoji, style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        audience.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        audience.description,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                AnimatedScale(
                  scale: selected ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: _flyGradient),
                    ),
                    child: const Icon(Icons.check_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Who can watch" row on the Post screen. Rebuilds only itself.
class AudiencePickerTile extends StatelessWidget {
  final ValueNotifier<PostAudience> audience;

  const AudiencePickerTile({super.key, required this.audience});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PostAudience>(
      valueListenable: audience,
      builder: (context, current, _) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final PostAudience? picked =
                await showAudiencePicker(context, current);
            if (picked != null) audience.value = picked;
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                ShaderMask(
                  shaderCallback: (r) =>
                      const LinearGradient(colors: _flyGradient)
                          .createShader(r),
                  child: Icon(current.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Who can watch',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                const Spacer(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Text(
                    '${current.emoji} ${current.label}',
                    key: ValueKey(current),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small glass chip ("🔒 Only me") shown on a video that isn't public,
/// so its owner can see at a glance who else can watch it. Nothing for
/// Everyone posts.
class AudienceBadge extends StatelessWidget {
  final PostAudience audience;

  const AudienceBadge({super.key, required this.audience});

  @override
  Widget build(BuildContext context) {
    if (audience.isPublic) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(audience.icon, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            audience.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

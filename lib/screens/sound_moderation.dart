// Copyright safeguards for the user-generated sounds catalog (`sounds`
// collection). Everything here runs client-side (Spark plan, no Cloud
// Functions), so the matching Firestore security rules are what actually
// enforce it - see the rules snippet shared alongside this change.
//
//  1. Sharing a sound needs an explicit "I own / have the rights to this
//     audio" confirmation (SoundRightsCheckbox). Unconfirmed uploads still
//     post normally - their audio just never enters the shared library.
//  2. Anyone can report a sound. Reports go to the same `reports`
//     collection posts/comments use (for review in the Firebase Console),
//     and the reporter's uid is added to the sound's `reportedBy` list.
//  3. Once kSoundReportHideThreshold different people report a sound, it
//     is hidden everywhere (library, sound page, story playback) until
//     reviewed. The owner can also remove their own sound at any time.
//
// Review in the Firebase Console (sounds/{id}):
//   status: 'approved'  -> keep showing it, ignoring reports
//   status: 'removed'   -> hide it permanently
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// Different users that must report a sound before it's auto-hidden.
// Hiding is fully automatic - no one has to review anything for it to
// happen. Review is only needed to bring a wrongly hidden sound back
// (status: 'approved' in the Firebase Console).
const int kSoundReportHideThreshold = 5;

// Where rights holders send takedown requests. Fill this in before
// launch - an empty value hides the email line on the policy screen.
const String kCopyrightContactEmail = 'aungnaungkyaw545778@gmail.com';

// Fields written onto every newly shared sound doc.
Map<String, dynamic> newSoundModerationFields() => {
      'status': 'active',
      'rightsConfirmed': true,
      'rightsConfirmedAt': FieldValue.serverTimestamp(),
      'reportedBy': <String>[],
    };

// True when a sound must not be shown or played. Sounds created before
// these fields existed have no status/reportedBy and stay visible.
bool isSoundHidden(Map<String, dynamic>? data) {
  if (data == null) return true;
  final String status = data['status'] as String? ?? 'active';
  if (status == 'removed') return true;
  if (status == 'approved') return false;
  final int reports = (data['reportedBy'] as List<dynamic>?)?.length ?? 0;
  return reports >= kSoundReportHideThreshold;
}

// Looks up a sound and says whether it may still be played. Used by the
// story viewer before playing a story's music; errs on the side of
// playing if the lookup itself fails (e.g. offline with no cache).
Future<bool> isSoundPlayable(String soundId) async {
  if (soundId.isEmpty) return true;
  try {
    final snap = await FirebaseFirestore.instance
        .collection('sounds')
        .doc(soundId)
        .get();
    if (!snap.exists) return false;
    return !isSoundHidden(snap.data());
  } catch (_) {
    return true;
  }
}

// ---------------------------------------------------------------------------
// Rights confirmation checkbox (upload screen + story video editor)
// ---------------------------------------------------------------------------
class SoundRightsCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const SoundRightsCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: const Color(0xFFFF4B6E),
                side: const BorderSide(color: Colors.white54),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Let others use my sound',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11.5),
                      children: [
                        const TextSpan(
                          text: 'I created this audio or have the rights to '
                              'share it. Copyrighted songs will be removed. ',
                        ),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const CopyrightPolicyScreen(),
                              ),
                            ),
                            child: const Text(
                              'Policy',
                              style: TextStyle(
                                color: Color(0xFFFF4B6E),
                                fontSize: 11.5,
                                decoration: TextDecoration.underline,
                                decorationColor: Color(0xFFFF4B6E),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Report a sound
// ---------------------------------------------------------------------------
const List<String> kSoundReportReasons = [
  'This is my music (copyright owner)',
  'Copyrighted song the uploader doesn\'t own',
  'Offensive or inappropriate audio',
  'Spam or misleading',
  'Something else',
];

Future<void> showReportSoundSheet(
  BuildContext context, {
  required String soundId,
  required String ownerId,
}) async {
  final String? myId = FirebaseAuth.instance.currentUser?.uid;
  if (myId == null || soundId.isEmpty) return;

  final String? reason = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Why are you reporting this sound?',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),
          ...kSoundReportReasons.map((r) => ListTile(
                title: Text(r, style: const TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(sheetContext, r),
              )),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (reason == null) return;

  try {
    final db = FirebaseFirestore.instance;
    final batch = db.batch();
    // Review queue entry - same collection as post/comment/user reports.
    batch.set(db.collection('reports').doc(), {
      'targetType': 'sound',
      'targetId': soundId,
      'targetOwnerId': ownerId,
      'reporterId': myId,
      'reason': reason,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
    // arrayUnion means the same person reporting twice still counts once.
    batch.update(db.collection('sounds').doc(soundId), {
      'reportedBy': FieldValue.arrayUnion([myId]),
    });
    await batch.commit();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report submitted. Thank you.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit report. Try again.')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Owner removes their own sound from the library
// ---------------------------------------------------------------------------
Future<bool> confirmRemoveOwnSound(BuildContext context, String soundId) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('Remove this sound?',
          style: TextStyle(color: Colors.white)),
      content: const Text(
        'Others will no longer be able to find or use it. Your own videos '
        'and stories stay up.',
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
              const Text('Remove', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (ok != true) return false;

  try {
    await FirebaseFirestore.instance
        .collection('sounds')
        .doc(soundId)
        .update({'status': 'removed'});
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not remove sound. Try again.')),
      );
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Copyright & sounds policy page (Settings + the checkbox's "Policy" link)
// ---------------------------------------------------------------------------
class CopyrightPolicyScreen extends StatelessWidget {
  const CopyrightPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const TextStyle h = TextStyle(
        color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold);
    const TextStyle p =
        TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.45);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Copyright & Sounds',
            style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const Text('Sharing sounds', style: h),
          const SizedBox(height: 6),
          const Text(
            'Sounds in Fly are uploaded by our users. Only share audio you '
            'created yourself or have permission to share. Do not share '
            'commercial songs, film/TV audio or other people\'s music '
            'without the rights holder\'s permission.',
            style: p,
          ),
          const SizedBox(height: 18),
          const Text('Reporting', style: h),
          const SizedBox(height: 6),
          const Text(
            'Open any sound page and tap the flag icon to report it. Sounds '
            'reported by several people are hidden automatically until '
            'they are reviewed. Accounts that repeatedly share infringing '
            'audio may lose the ability to share sounds or be suspended.',
            style: p,
          ),
          const SizedBox(height: 18),
          const Text('Copyright owners', style: h),
          const SizedBox(height: 6),
          const Text(
            'If you own a song or recording that is being used in Fly '
            'without your permission, report the sound in the app and '
            'choose "This is my music", or contact us. Include the sound '
            'name, the account that shared it and proof of ownership. '
            'We remove infringing audio promptly.',
            style: p,
          ),
          if (kCopyrightContactEmail.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              'Contact: $kCopyrightContactEmail',
              style: const TextStyle(
                  color: Color(0xFFFF4B6E),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 18),
          const Text('Removing your own sound', style: h),
          const SizedBox(height: 6),
          const Text(
            'Open your sound\'s page and tap the delete icon. It will no '
            'longer appear in the sound library.',
            style: p,
          ),
        ],
      ),
    );
  }
}

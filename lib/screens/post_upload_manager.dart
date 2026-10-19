// Background posting (TikTok-style, 18 Oct 2026).
//
// Before: tapping Post kept the person stuck on the Upload screen, watching
// a progress bar, until trim + compress + upload + moderation + the
// Firestore write were all done.
//
// Now: UploadScreen only checks the quick things (a video is chosen, the
// caption passes the offline word list, there is a connection), hands a
// PostJob to PostUploadManager and sends the person straight to Home. The
// manager - an app-wide singleton, so it keeps going whichever screen is
// open - does the whole job and reports to a small "Posting... 42%" pill
// (PostUploadPill, drawn by main_navigation_screen.dart above every tab).
//
// Only one post at a time: while one is posting (or failed and waiting for
// Retry / dismiss) UploadScreen refuses a second one with a clear message.
//
// The Android process stays alive in the background thanks to the presence
// foreground service (PresenceForegroundService.kt), so the upload also
// survives the person leaving the app for a while.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_trimmer_2/video_trimmer_2.dart';
import '../app_config.dart';
import '../search_service.dart';
import 'home_screen.dart' show homeFeedScrollToTopSignal;
import 'local_video_cache.dart';
import 'sound_moderation.dart';
import 'video_upload_service.dart';

// Everything the pipeline needs, copied out of UploadScreen's state at the
// moment Post is tapped (so the screen can reset itself right away).
class PostJob {
  final File videoFile;
  final int? trimStartSeconds;
  final int? trimEndSeconds;
  final String caption;
  final String videoType; // 'short' | 'long'
  final double videoSpeed;
  final String filterType;
  final bool blurBackground;
  final List<Map<String, dynamic>> textOverlays; // already .toMap()'d
  final bool shareSound;
  final String? replyToPostId;
  final String? replyToOwnerId;
  final String? replyToOwnerName;

  // Filled in while the job runs, so a Retry after a late failure does not
  // upload the same video twice or create a second post document.
  String? postDocId;
  String? bunnyVideoId;
  String? uploadedLocalPath;

  PostJob({
    required this.videoFile,
    required this.trimStartSeconds,
    required this.trimEndSeconds,
    required this.caption,
    required this.videoType,
    required this.videoSpeed,
    required this.filterType,
    required this.blurBackground,
    required this.textOverlays,
    required this.shareSound,
    this.replyToPostId,
    this.replyToOwnerId,
    this.replyToOwnerName,
  });
}

enum PostUploadPhase { working, done, failed }

class PostUploadState {
  final PostUploadPhase phase;
  // 0..1 while the file is going up; null = not measurable yet ("Preparing").
  final double? progress;
  final String label;
  final bool canRetry;

  const PostUploadState(
    this.phase, {
    this.progress,
    required this.label,
    this.canRetry = false,
  });
}

// The post was refused on purpose (moderation) - retrying would not help.
class _PostRejected implements Exception {
  final String message;
  const _PostRejected(this.message);
}

class PostUploadManager {
  PostUploadManager._();
  static final PostUploadManager instance = PostUploadManager._();

  // null = nothing going on (pill hidden).
  final ValueNotifier<PostUploadState?> state =
      ValueNotifier<PostUploadState?>(null);

  PostJob? _job;
  Timer? _doneTimer;

  // True while a post is uploading, or failed and still waiting for the
  // person to tap Retry / dismiss it.
  bool get isBusy {
    final PostUploadPhase? p = state.value?.phase;
    return p == PostUploadPhase.working || p == PostUploadPhase.failed;
  }

  // Starts [job]. Returns false (and does nothing) if one is already busy.
  bool start(PostJob job) {
    if (isBusy) return false;
    _doneTimer?.cancel();
    _job = job;
    unawaited(_run(isAutoRetry: false));
    return true;
  }

  void retry() {
    if (_job == null || state.value?.phase != PostUploadPhase.failed) return;
    unawaited(_run(isAutoRetry: false));
  }

  void dismiss() {
    if (state.value?.phase == PostUploadPhase.working) return;
    _doneTimer?.cancel();
    _job = null;
    state.value = null;
  }

  void _set(PostUploadState s) => state.value = s;

  Future<void> _run({required bool isAutoRetry}) async {
    final PostJob? job = _job;
    if (job == null) return;
    _set(const PostUploadState(PostUploadPhase.working, label: 'Preparing...'));
    try {
      await _pipeline(job);
      _set(const PostUploadState(PostUploadPhase.done,
          progress: 1, label: 'Posted - tap to view'));
      _job = null;
      _doneTimer?.cancel();
      _doneTimer = Timer(const Duration(seconds: 5), () {
        if (state.value?.phase == PostUploadPhase.done) state.value = null;
      });
    } on _PostRejected catch (e) {
      _set(PostUploadState(PostUploadPhase.failed, label: e.message));
    } catch (e) {
      final bool network = _isNetworkError(e);
      // One quiet automatic retry for a connectivity blip, like before.
      if (network && !isAutoRetry) {
        _set(const PostUploadState(PostUploadPhase.working,
            label: 'Connection issue - retrying...'));
        await Future.delayed(const Duration(seconds: 3));
        await _run(isAutoRetry: true);
        return;
      }
      _set(PostUploadState(
        PostUploadPhase.failed,
        canRetry: true,
        label: network
            ? "Couldn't reach the internet. Tap Retry."
            : (e is VideoUploadException ? e.message : 'Upload failed: $e'),
      ));
    }
  }

  Future<void> _pipeline(PostJob job) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const VideoUploadException('You must be logged in to upload');
    }

    // Second line of defense for the caption (OpenAI multilingual
    // moderation via fly-moderation). Skipped on a Retry that already got
    // past it (the video is uploaded).
    if (job.bunnyVideoId == null && job.caption.isNotEmpty) {
      final bool flagged = await _isFlaggedByModerationServer(
        '/moderate/text',
        {'text': job.caption},
      );
      if (flagged) {
        throw const _PostRejected(
            'Your caption contains inappropriate language. Please edit it and post again.');
      }
    }

    // ---- trim + compress + upload (skipped when a previous try already
    // uploaded the video) ----
    if (job.bunnyVideoId == null) {
      File uploadFile = job.videoFile;
      final bool hasRealTrimRange = job.trimStartSeconds != null &&
          job.trimEndSeconds != null &&
          job.trimEndSeconds! > job.trimStartSeconds!;
      if (hasRealTrimRange) {
        try {
          final Trimmer trimmer = Trimmer();
          final File trimmedVideo = await trimmer.trimVideo(
            file: uploadFile,
            startMs: job.trimStartSeconds! * 1000,
            endMs: job.trimEndSeconds! * 1000,
          );
          // If trimming turned a camera video the wrong way round, keep
          // the untrimmed original (see video_upload_service.dart).
          uploadFile = await keepVideoOrientation(
            reference: uploadFile,
            candidate: trimmedVideo,
            step: 'trim',
          );
        } catch (_) {
          // Keep going with the untrimmed file - a trim failure should not
          // stop someone from posting.
        }
      }

      uploadFile = await compressVideoForUpload(uploadFile);

      job.uploadedLocalPath = uploadFile.path;
      _set(const PostUploadState(PostUploadPhase.working,
          label: 'Posting... 0%'));
      job.bunnyVideoId = await uploadVideoToBunny(
        file: uploadFile,
        title: 'Fly video',
        onProgress: (p) {
          _set(PostUploadState(
            PostUploadPhase.working,
            progress: p,
            label: p >= 1
                ? 'Finishing up...'
                : 'Posting... ${(p * 100).toStringAsFixed(0)}%',
          ));
        },
      );
    }

    final String bunnyVideoId = job.bunnyVideoId!;
    final String videoUrl =
        'https://${AppConfig.bunnyStreamCdnHost}/$bunnyVideoId/playlist.m3u8';

    _set(const PostUploadState(PostUploadPhase.working,
        progress: 1, label: 'Finishing up...'));

    // Video content check (needs the hosted video's url to sample frames).
    final bool videoFlagged = await _isFlaggedByModerationServer(
      '/moderate/video',
      {'video_url': videoUrl},
    );
    if (videoFlagged) {
      throw const _PostRejected(
          'This video was flagged as inappropriate and could not be posted.');
    }

    // Uploader's display name, so a shared sound can be credited.
    String ownerName = user.email?.split('@').first ?? 'User';
    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final String? displayName = profile.data()?['displayName'] as String?;
      if (displayName != null && displayName.trim().isNotEmpty) {
        ownerName = displayName.trim();
      }
    } catch (_) {
      // Keep the fallback name
    }

    // Same doc id on a Retry, so a late failure never makes a second post.
    job.postDocId ??= FirebaseFirestore.instance.collection('posts').doc().id;
    final DocumentReference<Map<String, dynamic>> postRef =
        FirebaseFirestore.instance.collection('posts').doc(job.postDocId);

    String soundId;
    String soundTitle = 'Original sound';
    final String soundOwnerName = ownerName;
    if (!job.shareSound) {
      // The uploader did not confirm they own this audio: it stays private
      // to this post (no sound doc, no music link in the feed).
      soundId = '';
    } else {
      // A fresh upload also becomes a reusable sound of its own (same id
      // as the post).
      soundId = postRef.id;
      await FirebaseFirestore.instance
          .collection('sounds')
          .doc(postRef.id)
          .set({
        'ownerId': user.uid,
        'ownerName': ownerName,
        'title': 'Original sound',
        'sourceUrl': videoUrl,
        'sourcePostId': postRef.id,
        'usageCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        ...newSoundModerationFields(),
      });
    }

    // Lowercased so hashtag lookups are case-insensitive.
    final List<String> hashtags = RegExp(r'#([\p{L}\p{N}_]+)', unicode: true)
        .allMatches(job.caption)
        .map((m) => m.group(1)!.toLowerCase())
        .toSet()
        .toList();

    await postRef.set({
      'userId': user.uid,
      'userEmail': user.email,
      'videoUrl': videoUrl,
      'caption': job.caption,
      'hashtags': hashtags,
      // 'short' = full-screen vertical, 'long' = landscape (YouTube style)
      'videoType': job.videoType,
      'videoSpeed': job.videoSpeed,
      'filterType': job.filterType,
      'blurBackground': job.blurBackground,
      'textOverlays': job.textOverlays,
      'soundId': soundId,
      'soundTitle': soundTitle,
      'soundOwnerName': soundOwnerName,
      // See video_upload_service.dart / the Worker's /bunny-webhook.
      ...newVideoReadinessFields(bunnyVideoId),
      if (job.replyToPostId != null) ...{
        'replyToPostId': job.replyToPostId,
        'replyToOwnerId': job.replyToOwnerId,
        'replyToOwnerName': job.replyToOwnerName,
      },
      'createdAt': FieldValue.serverTimestamp(),
    });

    // The uploader watches the new video instantly from the file on this
    // phone - no waiting for Bunny's encoding.
    final String? localPath = job.uploadedLocalPath;
    if (localPath != null) LocalVideoCache.register(videoUrl, localPath);
    unawaited(syncVideoReady(postRef, bunnyVideoId));
    // Searchable straight away (not only after Bunny's webhook).
    unawaited(SearchService.indexPost(postRef.id));
  }

  // Base URL of the self-hosted moderation service (Flask on Render.com).
  static const String _moderationBaseUrl =
      'https://fly-moderation.onrender.com';

  // Fails "open" (not flagged) on any network error or timeout - the free
  // Render instance can take ~50s to wake up - so an outage of the
  // moderation service never blocks posting.
  Future<bool> _isFlaggedByModerationServer(
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

  // True for a plain connectivity failure, as opposed to something the
  // server explicitly rejected (which retrying would never fix).
  bool _isNetworkError(Object e) {
    if (e is VideoUploadException) return e.isNetworkIssue;
    if (e is SocketException || e is TimeoutException) return true;
    if (e is http.ClientException) return true;
    final String s = e.toString();
    return s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection closed') ||
        s.contains('Connection reset') ||
        s.contains('TimeoutException');
  }
}

// The small pill shown at the top of the app (all tabs) while a post is
// uploading, finished, or failed. Hidden when there is nothing to show.
class PostUploadPill extends StatelessWidget {
  const PostUploadPill({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PostUploadState?>(
      valueListenable: PostUploadManager.instance.state,
      builder: (context, s, _) {
        if (s == null) return const SizedBox.shrink();
        final bool done = s.phase == PostUploadPhase.done;
        final bool failed = s.phase == PostUploadPhase.failed;

        final Widget leading;
        if (done) {
          leading = const Icon(Icons.check_circle_rounded,
              color: Color(0xFF24D17E), size: 22);
        } else if (failed) {
          leading = const Icon(Icons.error_rounded,
              color: Colors.redAccent, size: 22);
        } else {
          leading = SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: s.progress,
              strokeWidth: 2.4,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          );
        }

        return SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: const Color(0xEE1E1E1E),
                shape: const StadiumBorder(
                  side: BorderSide(color: Colors.white12),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: done
                      ? () {
                          homeFeedScrollToTopSignal.value++;
                          PostUploadManager.instance.dismiss();
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        leading,
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            s.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (failed && s.canRetry)
                          TextButton(
                            onPressed: PostUploadManager.instance.retry,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 30),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            child: const Text('Retry'),
                          ),
                        if (failed)
                          IconButton(
                            onPressed: PostUploadManager.instance.dismiss,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close,
                                color: Colors.white54, size: 18),
                            tooltip: 'Dismiss',
                          )
                        else
                          const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

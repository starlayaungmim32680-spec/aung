// One place for getting a video from the phone onto Bunny Stream, shared
// by feed uploads (upload_screen.dart) and video stories (story_screen.dart)
// so both get the same fixes:
//
//  - compression happens on the FINAL file (after any trim), and a failed
//    compression is logged instead of silently swallowed;
//  - the file is streamed from disk (never loaded fully into memory);
//  - the timeout scales with the file size, so a slow connection gets
//    enough time instead of being cut off at a fixed 2 minutes;
//  - on timeout the HTTP client is CLOSED, which really aborts the
//    request - a Dart .timeout() alone only stops waiting while the old
//    upload keeps eating bandwidth in the background (and left 0-byte
//    videos on Bunny when a retry started on top of it).
//
// The Worker (livekit_token_worker.js, /upload-video) creates the Bunny
// video slot, relays the body with a fixed Content-Length, and deletes
// the slot again if anything goes wrong - so a failed upload no longer
// leaves a stuck 0-byte "Processing" video behind.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_compress/flutter_compress.dart';
import 'package:http/http.dart' as http;
import 'video_call_screen.dart' show kTokenServerUrl;
import 'worker_auth.dart';

// Cloudflare's request-body limit on the free Workers plan is 100 MB.
const int kMaxVideoUploadBytes = 95 * 1024 * 1024;

// ---------------------------------------------------------------------------
// "Is this video ready yet?" (Bunny encoding)
// ---------------------------------------------------------------------------
// A new video post/story is saved with videoReady: false. The Worker's
// /bunny-webhook flips it to true once Bunny can play it (and records it
// in videoStatus/{bunnyVideoId}). Until then only the uploader sees it -
// played from the local file (see local_video_cache.dart).

// Fields for a brand-new video post/story doc.
Map<String, dynamic> newVideoReadinessFields(String bunnyVideoId) => {
      'bunnyVideoId': bunnyVideoId,
      'videoReady': false,
    };

// Covers the race where Bunny finished encoding BEFORE the post/story doc
// existed (so the webhook had nothing to flag yet): check the status the
// webhook left behind and flag the doc ourselves.
Future<void> syncVideoReady(DocumentReference ref, String bunnyVideoId) async {
  try {
    final snap = await FirebaseFirestore.instance
        .collection('videoStatus')
        .doc(bunnyVideoId)
        .get();
    if (snap.data()?['ready'] == true) {
      await ref.update({'videoReady': true});
    }
  } catch (_) {
    // Not critical - the webhook normally does this anyway.
  }
}

// Whether a post/story should be shown to [myUid]. Only an explicit
// `videoReady: false` hides it (older posts have no such field), and the
// uploader always sees their own.
bool isVideoVisibleTo(Map<String, dynamic> data, String? myUid) {
  if (data['videoReady'] != false) return true;
  return myUid != null && data['userId'] == myUid;
}

class VideoUploadException implements Exception {
  final String message;
  // True for connectivity problems (worth retrying), false for problems
  // retrying the same request won't fix (file too big, server rejected).
  final bool isNetworkIssue;

  const VideoUploadException(this.message, {this.isNetworkIssue = false});

  @override
  String toString() => message;
}

// Shrinks [file] for upload. Returns the compressed file, or [file] itself
// if compression fails or wouldn't make it smaller - a bad format should
// never block posting.
Future<File> compressVideoForUpload(File file) async {
  try {
    final int originalSize = await file.length();
    final VideoCompressResult result = await FlutterCompress.instance.compress(
      file.path,
      const VideoCompressConfig(
        qualityPercent: 60,
        maxWidth: 1280,
        maxHeight: 1280,
        keepOriginalIfLarger: true,
      ),
    );
    final File out = File(result.outputPath);
    if (!await out.exists()) {
      debugPrint('[video_upload] compression produced no file - '
          'uploading original ($originalSize bytes)');
      return file;
    }
    final int outSize = await out.length();
    if (outSize <= 0 || outSize >= originalSize) {
      debugPrint('[video_upload] compression did not shrink the video '
          '($originalSize -> $outSize bytes) - uploading original');
      return file;
    }
    debugPrint('[video_upload] compressed $originalSize -> $outSize bytes');
    return out;
  } catch (e) {
    debugPrint('[video_upload] compression failed, uploading original: $e');
    return file;
  }
}

// Time allowed for the whole upload: 90s base plus enough for a slow
// ~40 KB/s connection, between 2 and 25 minutes.
Duration uploadTimeoutFor(int bytes) {
  final int seconds = 90 + bytes ~/ (40 * 1024);
  return Duration(seconds: seconds.clamp(120, 25 * 60));
}

// Uploads [file] to Bunny Stream through the Worker and returns the new
// Bunny video id. [onProgress] gets 0..1 as the file is read out (an
// approximation of network progress).
Future<String> uploadVideoToBunny({
  required File file,
  required String title,
  void Function(double progress)? onProgress,
}) async {
  final int totalBytes = await file.length();
  if (totalBytes <= 0) {
    throw const VideoUploadException(
        'This video file is empty (0 bytes). Please record or pick it again.');
  }
  if (totalBytes > kMaxVideoUploadBytes) {
    final String mb = (totalBytes / (1024 * 1024)).toStringAsFixed(0);
    throw VideoUploadException(
        'This video is too large to upload ($mb MB). Please trim it shorter.');
  }

  // Signed-in user's Firebase ID token (see worker_auth.dart) - fetched
  // before anything is opened, so a sign-in problem fails fast.
  final Map<String, String> authHeaders;
  try {
    authHeaders = await workerAuthHeaders();
  } on WorkerAuthException catch (e) {
    throw VideoUploadException(e.message);
  }

  final http.Client client = http.Client();
  StreamSubscription<List<int>>? fileSub;
  try {
    final http.StreamedRequest request = http.StreamedRequest(
      'POST',
      Uri.parse('$kTokenServerUrl/upload-video'),
    )
      ..headers.addAll(authHeaders)
      // Header values must be plain ASCII - never a user caption.
      ..headers['X-Video-Title'] = title
      ..headers['Content-Type'] = 'video/mp4'
      ..contentLength = totalBytes;

    int sent = 0;
    fileSub = file.openRead().listen(
          (chunk) {
            request.sink.add(chunk);
            sent += chunk.length;
            onProgress?.call((sent / totalBytes).clamp(0.0, 1.0));
          },
          onDone: () => request.sink.close(),
          onError: (Object e) {
            request.sink.addError(e);
            request.sink.close();
          },
          cancelOnError: true,
        );

    final http.StreamedResponse response =
        await client.send(request).timeout(uploadTimeoutFor(totalBytes));
    final String body = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw VideoUploadException('Upload failed (${response.statusCode}): '
          '${body.length > 200 ? body.substring(0, 200) : body}');
    }
    final Map<String, dynamic> result = jsonDecode(body);
    final String? videoId = result['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      throw const VideoUploadException('Upload failed: no video id returned');
    }
    return videoId;
  } on VideoUploadException {
    rethrow;
  } on TimeoutException {
    throw const VideoUploadException(
      'The upload took too long. Check your connection and try again.',
      isNetworkIssue: true,
    );
  } on SocketException catch (e) {
    throw VideoUploadException('Connection problem: ${e.message}',
        isNetworkIssue: true);
  } on http.ClientException catch (e) {
    throw VideoUploadException('Connection problem: ${e.message}',
        isNetworkIssue: true);
  } finally {
    // Closing the client aborts an upload that's still running (e.g.
    // after a timeout) instead of leaving it going in the background.
    await fileSub?.cancel();
    client.close();
  }
}

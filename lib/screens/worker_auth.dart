// Authentication for every call the app makes to our Cloudflare Worker
// (cloudflare/livekit_token_worker.js).
//
// The app used to send a fixed shared secret (kAppSharedSecret) in an
// X-App-Secret header. That value lived in this public GitHub repo, so
// anyone could call the Worker - upload videos/images to Fly's Bunny
// account (costing Ko money) or mint LiveKit tokens. Instead, every
// request now carries the signed-in user's **Firebase ID token**, which
// the Worker verifies against Google's public keys. A token can only be
// obtained by actually signing in to Fly, expires after an hour, and is
// refreshed automatically by FirebaseAuth - nothing secret ships inside
// the app any more.
import 'package:firebase_auth/firebase_auth.dart';

class WorkerAuthException implements Exception {
  final String message;
  const WorkerAuthException(this.message);

  @override
  String toString() => message;
}

// Headers proving who is calling the Worker. Merge them into a request's
// own headers:
//   headers: {...await workerAuthHeaders(), 'Content-Type': '...'}
// Throws WorkerAuthException when nobody is signed in.
Future<Map<String, String>> workerAuthHeaders() async {
  final User? user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    throw const WorkerAuthException('Please sign in again.');
  }
  // Cached by FirebaseAuth and refreshed only when close to expiry, so
  // calling this before every request is cheap.
  final String? idToken = await user.getIdToken();
  if (idToken == null || idToken.isEmpty) {
    throw const WorkerAuthException('Could not verify your sign-in.');
  }
  return {'Authorization': 'Bearer $idToken'};
}

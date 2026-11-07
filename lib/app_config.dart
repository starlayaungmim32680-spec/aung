// Dev / prod split (5 Oct 2026). Fly is built in two "flavors":
//
//   prod - the real app: package com.aungdev.fly, label "fly", Firebase
//          project aung-1756e, Worker livekit-token-worker.
//          flutter build apk --release --flavor prod
//   dev  - for testing: package com.aungdev.fly.dev (installs NEXT TO the
//          real app), label "Fly Dev", a red DEV ribbon, its own Firebase
//          project fly-dev and its own Worker fly-dev-worker (own D1 + Bunny
//          library). Nothing done in dev can touch real users' data.
//          flutter build apk --release --flavor dev
//
// The flavor comes from Gradle (android/app/build.gradle.kts,
// productFlavors) through Flutter's `appFlavor` constant. Plain
// `flutter build apk --release` builds prod (pubspec.yaml default-flavor).
//
// Firebase: prod uses firebase_options.dart as before. Dev passes no
// options, so on Android Firebase reads android/app/src/dev/
// google-services.json (the google-services Gradle plugin picks the
// flavor's file automatically) - no second firebase_options file needed.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'firebase_options.dart';

class AppConfig {
  AppConfig._();

  /// True in the "Fly Dev" test app.
  static const bool isDev = appFlavor == 'dev';

  /// Our Cloudflare Worker (LiveKit tokens, pushes, uploads, search...).
  static const String workerUrl = isDev
      ? 'https://fly-dev-worker.chakaboycom.workers.dev'
      : 'https://livekit-token-worker.chakaboycom.workers.dev';

  /// Fly's link host = the Firebase Hosting site of each flavor's own
  /// project. Android opens these links in Fly itself (App Links,
  /// AndroidManifest.xml + firebase_hosting/public/.well-known/
  /// assetlinks.json): /__/auth/action (password reset) and, since 7 Nov
  /// 2026, `/u/<uid>` (a profile - the QR on the Fly Pass).
  static const String linkHost =
      isDev ? 'fly-dev-58b29.firebaseapp.com' : 'aung-1756e.firebaseapp.com';

  /// The link to a person's Fly profile.
  static String profileLink(String uid) => 'https://$linkHost/u/$uid';

  /// Both flavors' link hosts (a dev pass scanned in the real app, or the
  /// other way round, is recognised but can't be opened there).
  static const List<String> allLinkHosts = [
    'aung-1756e.firebaseapp.com',
    'fly-dev-58b29.firebaseapp.com',
  ];

  /// The uid in a Fly profile link (https://<host>/u/<uid>), else null.
  /// [anyFlavor] = also accept the other flavor's host.
  static String? profileUidFromLink(String text, {bool anyFlavor = false}) {
    final Uri? uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https') return null;
    if (anyFlavor ? !allLinkHosts.contains(uri.host) : uri.host != linkHost) {
      return null;
    }
    final List<String> parts = uri.pathSegments;
    if (parts.length < 2 || parts[0] != 'u') return null;
    final String uid = parts[1];
    return RegExp(r'^[A-Za-z0-9]{10,40}$').hasMatch(uid) ? uid : null;
  }

  /// Bunny Stream CDN (videos). Each flavor has its own Bunny library:
  /// prod 756617, dev 771031 ("fly-dev", 6 Oct 2026). Photos share the
  /// prod Storage zone (fly-images-aungdev756617) in both flavors - they
  /// are only files, and dev's Firestore never points real users at them.
  static const String bunnyStreamCdnHost =
      isDev ? 'vz-6cc91834-d0e.b-cdn.net' : 'vz-a6ab9346-730.b-cdn.net';

  /// Options for Firebase.initializeApp - null in dev (read from the dev
  /// google-services.json instead).
  static FirebaseOptions? get firebaseOptions =>
      isDev ? null : DefaultFirebaseOptions.currentPlatform;
}

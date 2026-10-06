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

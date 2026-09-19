# Fly — AI Assistant Context File

> **Purpose of this file:** If you are an AI assistant helping with this project,
> read this file first. It gives you the full picture of the app, the tech stack,
> the coding conventions, and where every file lives. To edit any file, fetch its
> **current** content from the raw GitHub URL (pattern below), then reply with a
> **full-file rewrite** (not a diff).

---

## 1. What the app is

**Fly** is a TikTok / Facebook-style short-video **social + chat app** built in
**Flutter**. It has a full-screen vertical video feed, Stories, chat (text /
image / voice / video call), profiles, follow, reactions, comments, live
streaming, gifting, a cute animated mascot guide, online presence, and more.

- **GitHub repo:** https://github.com/starlayaungmim32680-spec/aung
- **Default branch:** `main`
- **Raw file URL pattern (fetch current code from here):**
  `https://raw.githubusercontent.com/starlayaungmim32680-spec/aung/main/<path>`
  - Example: `https://raw.githubusercontent.com/starlayaungmim32680-spec/aung/main/lib/screens/home_screen.dart`
- **Android package name:** `com.aungdev.fly` (this was renamed at some point
  from the Flutter default `com.example.fly` — always confirm the current
  value from `android/app/src/main/kotlin/<package-path>/MainActivity.kt`'s
  directory path or `android/app/build.gradle.kts`'s `namespace`/`applicationId`
  rather than assuming).

---

## 2. Owner & working style (please follow)

- The owner is **Ko** and communicates in **Burmese**. Please reply in Burmese.
  Ko addresses the assistant as "ဆရာ" (teacher).
- **Always provide a FULL file rewrite** (the entire file, top to bottom), never
  a diff or partial snippet.
- **All code comments and strings must be in English** (only chat replies are in
  Burmese).
- Ko develops on **Windows + VS Code**, and tests by building a release APK and
  side-loading it on an Android phone (`flutter build apk --release`). Ko also
  sometimes runs `flutter run` for quicker debug-mode iteration. Ko has no
  physical/emulated device or Flutter SDK on the assistant's own side — always
  hand Ko the exact commands (`flutter pub get`, `flutter analyze` first, then
  `flutter build apk --release`) and wait for his pasted terminal output before
  claiming anything works.
- Ko builds **one feature at a time** and tests before moving on. Prefer small,
  isolated, verifiable steps — especially for anything touching layout,
  navigation, video playback, calls, or native Android (Kotlin/Manifest) code.
  A recent case study in why: a video-upload migration (see §3, Bunny Stream)
  went through three different upload mechanisms before landing on one that
  actually worked, because each intermediate approach _looked_ correct but
  failed in a way only visible after Ko tested on a real device.
- After a change is confirmed working, Ko asks to commit and push. Give him the
  exact `git add` (naming the specific changed files, not `git add .`),
  `git status` (to confirm), `git commit -m "..."`, and `git push` commands,
  one block at a time, and wait for his pasted terminal output before
  continuing. If `flutter pub get` caused `pubspec.lock` to also show as
  modified, tell him to add and commit that too (a separate small commit is
  fine if he already pushed without it).
- When adding a new pubspec dependency, mention the risk of a transitive
  version conflict (e.g. a package pinned to an old major version of `http` or
  similar) and have Ko run `flutter pub get` before writing any code against
  it — this has come up multiple times (connectivity_plus vs livekit_client,
  tus_client vs the app's http ^1.2.2).
- Ko likes a **playful, colorful, mascot-driven UI** (see "Flyla" the bird
  mascot, gradient logos, sparkle animations) and cares about small UX details
  (confirmation dialogs before destructive actions, friendly error messages
  instead of raw error text, cute reactions instead of plain state changes).
  Default to this style for new UI unless told otherwise.
- Ko is also thinking about a possible logo redesign: a "FLY" wordmark
  stylized as a bird (tail feathers before the F, wings sprouting near the Y,
  a round head+beak+eye after it) — inspired by wordmark-as-object techniques
  (e.g. "BEE" drawn as an actual bee). Not finalized into app-icon assets yet.
- The assistant (Claude) typically has **no Flutter SDK, emulator, or physical
  device** in its own environment — it cannot run `flutter analyze`,
  `flutter build`, or `flutter run` itself. Always give Ko the exact commands
  to run and wait for his results; never claim something was built, tested, or
  verified without him actually running it.

---

## 3. Tech stack & configuration

- **Flutter** (Android target, package `com.aungdev.fly`).
- **Firebase** — project ID `aung-1756e`. Uses **Firestore** + **Email/Password
  Auth**. On the **free Spark plan** (NO Cloud Functions / no Blaze) — Ko has
  no card, so anything requiring Blaze is avoided; the Cloudflare Worker (see
  below) fills the "need a trusted server" role instead.
  - No `firestore.rules` file is version-controlled in this repo — security
    rules are managed directly in the **Firebase Console → Firestore → Rules**.
    If you add a new collection/field the client reads or writes, remind Ko to
    check/update the rules in the Console; you cannot inspect or confirm the
    current rules yourself.
  - Firestore offline persistence is explicitly configured in `main.dart`
    (`Settings(persistenceEnabled: true, cacheSizeBytes:
Settings.CACHE_SIZE_UNLIMITED)`) — writes queue locally when offline and
    sync automatically when back online; `chat_screen.dart`'s message list
    surfaces this via each message's `metadata.hasPendingWrites` (shows
    "Sending..." instead of "Sent"/"Seen" for a still-queued message — this
    only reflects the _sender's_ own connection, not the recipient's).
- **Video hosting: Bunny Stream** (migrated from Cloudinary in a later
  session — Cloudinary's account was disabled for exceeding its free-plan
  usage quota, and a cost-scaling discussion showed Cloudinary's per-GB
  bandwidth would be far too expensive at real scale vs. a dedicated CDN).
  - Library ID `756617`, CDN hostname `vz-a6ab9346-730.b-cdn.net`.
  - The real Bunny API key lives ONLY as a Cloudflare Worker secret
    (`BUNNY_API_KEY`/`BUNNY_LIBRARY_ID`) — never in the Flutter app.
  - **Upload flow:** `upload_screen.dart` POSTs the (already client-side
    compressed) video bytes as a plain streamed request body straight to the
    Worker's `/upload-video` endpoint (headers: `X-App-Secret`,
    `X-Video-Title` — always a fixed ASCII string like `"Fly video"`, never
    the user's real caption, since HTTP header values can't contain non-ASCII
    text like emoji or Burmese script and this threw a real
    `FormatException` in testing). The Worker creates the Bunny video slot
    and relays the request body straight through to Bunny's direct PUT
    upload API — it never buffers the whole file in memory. Two earlier
    upload mechanisms were tried and abandoned: a resumable TUS-based flow
    (a `/create-video` endpoint + a client-side TUS library) turned out to
    silently produce 0-byte videos on Bunny in practice across two different
    TUS packages — the plain streamed-POST-to-Worker-proxy above is what
    actually works, confirmed on-device.
  - **Playback:** the stored `videoUrl` for a Bunny post is the HLS playlist,
    `https://vz-a6ab9346-730.b-cdn.net/<videoId>/playlist.m3u8` —
    `video_player`'s underlying ExoPlayer/AVPlayer plays this as real
    adaptive-bitrate streaming with no extra code, so `playableVideoUrl()` in
    `media_utils.dart` (see §4) doesn't need to do the manual network-based
    quality-URL-swapping it still does for old Cloudinary posts.
  - **Thumbnails:** `cloudinaryThumbUrl()` (kept its old name for git-blame
    continuity, but now handles both) detects a Bunny URL (`b-cdn.net`) and
    returns the sibling `.../<videoId>/thumbnail.jpg` path instead of trying
    to re-extension the URL the Cloudinary way.
  - **Bunny library security setting:** "Block direct url file access" must
    stay **OFF** — when it was accidentally left on, the app's own HTTP
    requests (no browser `Referer` header) were rejected even though Bunny's
    own dashboard player worked fine (browser requests do send a referer).
  - **Known limitation:** an HLS `.m3u8` URL is a small manifest that
    references separate segment files by URL, not a single self-contained
    file — so `VideoDiskCache` (see §4, Recently-Watched Video Local Cache)
    explicitly skips any `videoUrl` containing `.m3u8`. Caching just the
    manifest to disk actively broke playback when reloaded from a local path
    (the manifest's relative segment references can't resolve against a
    `file://` path the way they resolve against the real CDN URL). Bunny
    videos always stream directly for now; true offline HLS caching would
    need downloading every segment and rewriting the manifest to point at
    them locally — not built.
  - **Known limitation:** Trim and "Borrowed Sound" (using someone else's
    audio track) were both implemented as Cloudinary URL-transform hacks with
    no Bunny equivalent yet. Borrowed Sound is blocked at upload time with a
    clear message. Trim could **not** be gated the same way, since every
    video (camera or gallery) is unavoidably routed through
    `TrimEditorScreen` with no way to skip it — gating on it blocked every
    single upload. Trim currently just silently no-ops instead (the full,
    untrimmed video posts) rather than blocking anything.
  - Old Cloudinary-hosted posts are unaffected by any of the above (all the
    Cloudinary-specific URL transforms already safely no-op on a non-
    Cloudinary/Bunny URL) but remain unplayable unless/until that Cloudinary
    account itself gets reactivated — it's currently still disabled.
- **LiveKit** (video/voice calls + live streaming) — Cloud project (NOT
  self-hosted), free "Build" plan, **no card on file** (5,000 WebRTC
  participant-minutes + 50GB data transfer per month, hard cap since there's
  no billing to overflow into — requests just start failing past that). Live
  streaming with many viewers burns through this far faster than 1:1 calls,
  since minutes are counted per participant (e.g. 1 host + 50 viewers for 30
  minutes ≈ 1,530 minutes in one stream). Actual usage checked in a later
  session: ~49 minutes / ~12MB over 7 days — nowhere near the limit at
  current (testing-scale) usage.
  - The token server is a **Cloudflare Worker**
    (`livekit-token-worker.chakaboycom.workers.dev`, source file
    `livekit_token_worker.js`, chosen specifically to avoid needing Firebase
    Blaze billing) with four routes, all requiring an `X-App-Secret` header
    matching the `APP_SHARED_SECRET` secret:
    - `POST /token` — mints a LiveKit access token (`LIVEKIT_API_KEY`/
      `LIVEKIT_API_SECRET`/`LIVEKIT_URL` secrets).
    - `POST /call-push` — sends an FCM push (Google service-account OAuth2
      flow; `FIREBASE_PROJECT_ID`/`FIREBASE_CLIENT_EMAIL`/
      `FIREBASE_PRIVATE_KEY_B64` secrets) to wake a phone for an incoming
      call even if Fly is fully closed — see `firebaseMessagingBackgroundHandler`
      in `main.dart`.
    - `POST /create-video` — kept for potential future use (mints a
      presigned Bunny TUS signature) but **not currently called** by the app.
    - `POST /upload-video` — the video upload proxy described above.
  - Confirm the current token-fetch code path in `video_call_screen.dart`
    (constants `kTokenServerUrl`/`kAppSharedSecret`, both plain top-level
    `const` in that file, imported with a `show` clause by other files that
    need them) before changing call logic.
  - **Caller ring-back tone:** while the caller is waiting for the callee to
    pick up, `video_call_screen.dart` plays a code-generated "beep beep beep"
    WAV tone (same generated-WAV-bytes approach as the chat "ding" in
    `main_navigation_screen.dart`) via `audioplayers`, starting once the
    caller's own room connection succeeds and stopping once the callee joins
    or the call ends. Only the caller hears it — the callee has their own,
    separate incoming-ringtone via CallKit. Needed an explicit
    `AndroidUsageType.voiceCommunicationSignalling` `AudioContext` — some
    Android OEM skins (confirmed: Vivo/Funtouch) silently mute a plain
    media-stream sound during an active voice-communication-mode call unless
    it's tagged as an in-call signalling tone specifically.
  - **Speaker toggle:** the in-call speaker button used to do nothing
    audibly — root cause was calling `Helper.setSpeakerphoneOn()`
    (flutter_webrtc's old API), which LiveKit's client SDK disables/bypasses
    now that it owns the platform audio session itself. Fixed by switching to
    LiveKit's own `AudioManager.instance.setSpeakerOutputPreferred(enabled,
force: enabled)` — used for both the video-call default-to-speaker
    behavior and the manual toggle button. If any other audio-routing issue
    comes up in calls, check for `Helper.*` calls first; they may be silent
    no-ops now.
  - **Known, not-yet-fixed call bugs** (found in a later session):
    1. If the callee's Fly app is **fully closed** (not just backgrounded)
       when they tap Decline on the native incoming-call UI, the caller is
       never notified (Firestore never gets the `status: 'declined'` write).
       Confirmed as a known, actively-unresolved limitation of the
       `flutter_callkit_incoming` plugin itself when the app process isn't
       running — there's no Dart isolate alive to receive the event. The
       existing 45s no-answer timer in `video_call_screen.dart` is the only
       current mitigation (the caller gives up automatically, just not
       instantly).
    2. If the caller hangs up before the callee answers, the callee's phone
       keeps ringing for the full 45s regardless, since nothing signals
       their native ringing screen to stop. `main_navigation_screen.dart`'s
       `_listenForIncomingCalls` never handles Firestore's
       `DocumentChangeType.removed` case (which fires when a doc's `status`
       changes away from `'ringing'`, the value that Firestore query
       filters on) — so even the app-open/backgrounded case isn't handled
       yet, and it's the more tractable of the two bugs to fix (no plugin
       limitation involved). A full fix for the fully-killed case would also
       need a new FCM push type (mirroring the existing incoming-call push)
       handled in `main.dart`'s background handler to call
       `FlutterCallkitIncoming.endCall()` directly.
- **Rendering engine: Impeller is explicitly DISABLED.**
  `android/app/src/main/AndroidManifest.xml` sets
  `io.flutter.embedding.android.EnableImpeller` to `false`. This was a
  deliberate, confirmed fix for a long-investigated bug where
  `FullScreenVideoScreen` (opened by tapping a Home video) showed ghost/
  duplicated Like/Comment/Share/Save/View/Sound UI — traced to an Impeller GPU
  compositing artifact during page navigation (a known Impeller issue class,
  not a Fly code bug). **Do not re-enable Impeller or remove this manifest
  entry without re-testing that screen specifically** — many other hypotheses
  (SafeArea, Firestore stream recreation, VideoPreloadCache, route transition
  animation, Positioned/RenderBox layout) were exhaustively investigated and
  ruled out first; the home_screen.dart layout code itself was confirmed
  correct via a temporary debug-border diagnostic.
- **Network resilience:** Fly has an explicit set of behaviors for a poor/no
  connection, all already built (see `network_service.dart` and the file
  list in §4 for exactly what each piece does): a live network-status banner,
  adaptive video quality (Cloudinary posts only — Bunny's HLS is naturally
  adaptive), load-error retry UI, upload retry-on-blip, Firestore offline
  persistence, and disk caching of recently-watched (Cloudinary) videos for
  offline replay.
- **Local storage:** `shared_preferences` is used for small, device-local,
  non-sensitive data only — currently the "recent accounts" quick-switch list
  on the login screen (`recent_accounts.dart`; stores name/email/photo, **never
  a password**). Anything that should sync across a user's devices or survive
  a reinstall goes in Firestore instead (e.g. `hasSeenOnboarding`,
  `sawSwipeHint`, presence fields — all on the user's Firestore doc, not in
  shared_preferences).
- **Native Android foreground services** (Kotlin, under
  `android/app/src/main/kotlin/com/aungdev/fly/`), both started/stopped from
  Dart via the shared `kBackgroundChannel` (`MethodChannel('fly/background')`,
  declared in `video_call_screen.dart`) and handled in `MainActivity.kt`:
  - `CallForegroundService.kt` — keeps the app alive for the duration of a
    call (`setCallActive`/`clearCallActive`), so Android doesn't suspend Fly
    just because the person switched apps mid-call.
  - `PresenceForegroundService.kt` — keeps the app alive for as long as
    someone is logged in (`startPresenceService`/`stopPresenceService`,
    started in `main_navigation_screen.dart`'s `initState()`), so the online-
    status heartbeat keeps refreshing `lastActive` in Firestore even with the
    screen off/locked. Both are independent of each other and both require a
    persistent, low-priority ("Silent") notification — this is a real Android
    OS requirement for any foreground service, not something that can be
    hidden entirely.
  - Both mirror the same pattern: `startForeground()` with an
    `IMPORTANCE_MIN` notification channel, `START_STICKY`, and a safety-net
    stop in `MainActivity.onDestroy()`.
  - **Cost flag for later:** the 20s presence heartbeat writes to Firestore
    per online user is cheap at current testing scale but was flagged in a
    cost-scaling discussion as a real secondary cost risk once user count
    grows meaningfully (est. $1-3K/month at ~300K DAU) — worth reconsidering
    (e.g. moving to Realtime Database's `onDisconnect()`) well before that
    point, not urgent now.

### Key packages (pubspec.yaml)

firebase_core, firebase_auth, firebase_storage, cloud_firestore,
connectivity_plus, http, image_picker, video_player, flutter_compress,
cached_network_image, flutter_cache_manager, video_editor, share_plus,
flutter_local_notifications, livekit_client, flutter_webrtc, audioplayers,
path_provider, flutter_sound, permission_handler, shared_preferences,
url_launcher, camera, google_mlkit_face_mesh_detection,
google_mlkit_translation, google_mlkit_language_id, firebase_messaging,
device_info_plus, flutter_callkit_incoming, proximity_sensor, gal.

No `bunny_dart`, `tus_client`, `tusc`, or `cross_file` — all were tried and
removed during the upload-mechanism debugging described above; the final
Bunny upload path only needs the `http` package, already present.

### Build toolchain (bleeding-edge but working)

AGP 8.9.1, Gradle 9.1.0, JDK 25, compileSdk 36.
⚠️ Never edit gradle/dart/XML files with Notepad or PowerShell here-strings
(they inject a BOM / strip characters). Use VS Code only.
⚠️ A one-time gotcha unrelated to this project's own code: Windows's "Smart
App Control" security feature can block Flutter's own bundled tools (e.g.
`font-subset.exe`) from running at all, surfacing as a generic
`ProcessException`/"Application Control policy has blocked this file"
during `flutter build`. Fix is on Ko's machine (Windows Security → App &
browser control → turn Smart App Control off, then restart) — not a code
issue if this comes up again.

---

## 4. File structure (all under `lib/`, unless noted)

- `main.dart` — app entry, Firebase init (+ explicit Firestore offline-
  persistence settings, see §3), auth gate / auto-login (`_ensureUserDoc`
  creates the user's Firestore doc on first login),
  `firebaseMessagingBackgroundHandler` for incoming-call push data messages,
  starts `NetworkService.instance.init()` after `runApp()`.
- `network_service.dart` — app-wide `NetworkService` singleton
  (`ValueNotifier<NetworkStatus>` with offline/weak/good), probes
  `https://www.gstatic.com/generate_204` periodically for real latency (not
  just "is an interface connected"). Read by `media_utils.dart`'s
  `playableVideoUrl()` (Cloudinary posts only) and by `upload_screen.dart`
  (fail-fast if offline before attempting an upload). Also drives the top-of-
  screen status banner in `main_navigation_screen.dart` (red=offline,
  amber=weak, via a `_TopBars` widget stacked above the existing minimized-
  call bar).
- `video_disk_cache.dart` — `VideoDiskCache` singleton wrapping
  `flutter_cache_manager` (7-day stale period, max 60 cached videos). Used by
  `home_screen.dart`'s `_initializeVideo()` to check for/save a previously-
  watched **Cloudinary** video on disk for instant/fully-offline replay —
  explicitly skipped for any Bunny (`.m3u8`) URL, see §3.
- `screens/login_screen.dart` — auth. Has: a gradient, glowing, sparkle-
  animated "Fly" logo; **"Flyla"** the bird mascot (bouncing animation) that
  reacts contextually — different emoji/speech-bubble message depending on
  which field is focused, or shows the login error in its speech bubble
  instead of a plain red error line; a **"Continue as"** row of recent-
  account chips (see `recent_accounts.dart`) that pre-fill the email field
  (never the password) when tapped; and a **"Forgot password?"** link that
  opens a dialog collecting an email, calls Firebase Auth's
  `sendPasswordResetEmail()`, and offers an **"Open Gmail"** action
  (`url_launcher`, deep-links to `https://mail.google.com/mail/u/0/#inbox`)
  once the link is sent. Password reset itself always happens on Firebase's
  own hosted page (opened from the emailed link), not inside the app — no
  custom code/token flow was built for this, to stay on the Spark plan.
- `screens/signup_screen.dart` — account creation.
- `screens/recent_accounts.dart` — local-only (`shared_preferences`) store of
  previously logged-in accounts' name/email/photo, capped at 5, for the login
  screen's quick-switch chips. Deliberately never stores a password.
- `screens/onboarding_screen.dart` — **"Flyla"** mascot's 4-step onboarding
  tour (bouncing emoji + speech-bubble cards, swipeable, Skip button), shown
  to a brand-new user exactly once after their first login. Triggered from
  `main_navigation_screen.dart`'s `_maybeShowOnboardingOnce()`, which checks/
  sets a `hasSeenOnboarding` flag on the user's Firestore doc (same pattern as
  the pre-existing `sawSwipeHint` flag) — chained so it always finishes before
  the swipe hint gets its turn.
- `screens/main_navigation_screen.dart` — the shell.
  - Bottom section: Home and Chat are swipeable via a `PageView` (both stay
    mounted simultaneously — needed so the swipe feels responsive); Upload,
    Profile, Live, and Gifting are separate, non-swipeable tabs. **Not**
    `IndexedStack` (that was deliberately removed previously because it kept
    every tab's videos alive/competing for playback).
  - Draggable rainbow floating button that toggles a frosted-glass bottom nav
    pill; shows an **X** when open, a rotating rainbow ≡ when closed.
  - `_TopBars`: stacks the network-status banner above the minimized-call bar
    at the top of the screen (see `network_service.dart` above).
  - In-app "ding" sound on new messages; incoming-call listening/UI (see the
    known call bugs in §3 — this is where a Firestore `removed`-doc-change
    handler for a caller-cancelled call would need to be added).
  - Runs the **online-presence heartbeat**: on `initState()`, writes
    `isOnline: true` + `lastActive: serverTimestamp()` to the user's Firestore
    doc, refreshes it every 20s via a `Timer.periodic`, and starts
    `PresenceForegroundService.kt` so the heartbeat keeps running with the
    screen off/locked. Deliberately does **not** write `isOnline: false` on
    backgrounding (only on the rare case `dispose()` runs) — a user is
    considered online purely by whether `lastActive` is recent (see
    `presence_badge.dart`), so briefly backgrounding the app doesn't cause a
    flicker to "offline". This also means: someone who has never opened Fly at
    least once (even with their phone's internet on) can never show as
    online — there is no way around this on any app, not just Fly.
- `screens/presence_badge.dart` — shared `SparkleStarBadge` widget (a
  rotating/twinkling gold star, deliberately not the usual plain green dot)
  and the `isUserOnline(userData)` helper (`isOnline == true` **and**
  `lastActive` within the last 60 seconds) used by both the Chat list and
  Profile screens.
- `screens/settings_screen.dart` — small settings hub (currently just links to
  Blocked accounts; a natural place to add future settings instead of piling
  onto `profile_screen.dart`'s 3-dot menu). Opened via a gear icon in
  `profile_screen.dart`'s AppBar.
- `screens/blocked_users_screen.dart` — lists everyone the current user has
  blocked (reads `users/{myId}/blocked`), each with an **Unblock** button.
  The actual "Block user" action lives in `public_profile_screen.dart` (a
  profile's 3-dot menu) and in a similar spot inside `home_screen.dart` (a
  video's "More" menu) — both write into the same
  `users/{myId}/blocked/{blockedUserId}` subcollection, which
  `home_screen.dart`'s feed queries already read to filter out blocked users'
  posts. **Blocking does not yet stop a blocked/blocking user from sending
  chat messages** — `chat_screen.dart` has no block-check — this is a known,
  not-yet-closed gap Ko is aware of.
- `screens/home_screen.dart` — the main video feed (very large file; several
  screens live here as separate classes rather than separate files — always
  check here first before assuming a screen doesn't exist):
  - `HomeScreen` / `_HomeScreenState` — the main vertical feed.
  - `FullScreenVideoScreen` — opened by tapping a Home video; a dedicated
    `PageView` host with its own explicit `_activeIndex`
    (`ValueNotifier<int>`) coordinating which page is active, and an
    `isActive` parameter on `_VideoPostItem` (default `true`, so
    Home/other screens that never pass it are unaffected) gating autoplay
    and reusing the existing `_pauseForNavigation`/`_resumeAfterNavigation`
    methods on activation changes. This explicit coordination was added as
    architecture hygiene (Design A from a prior investigation) — it is
    **not** what fixed the ghost/duplicate-UI bug (Impeller was); don't
    assume touching this area fixes rendering bugs.
  - `SingleVideoScreen`, `UserVideoFeedScreen`, `ShortsScreen` — other
    `_VideoPostItem`-reusing viewers (repost detail, one user's post grid
    viewer, a shorts-shelf, respectively).
  - `_VideoPostItem` — the shared per-video Stack: Smart-Fit video sizing
    (cover vs. letterbox based on aspect-ratio mismatch), caption panel,
    OwnerInfo, Like/Comment/Share/Save/More action dock (or a compact
    horizontal row for reposts), sound/view-count row, the "Fly Frame"
    cinematic top/bottom gradient bands, reaction picker, flying-emoji
    animation, report/block entry point, hashtag handling, translation.
    Accepts `onTapToExpand` (only Home passes this — its absence is how the
    code tells "already fullscreen" contexts apart from Home) and `isActive`.
    `_initializeVideo()` here is also where the network-aware timeout/retry
    UI ("Couldn't load - tap to retry", `_hasError` flag) and the
    Cloudinary-only disk-cache logic (see `video_disk_cache.dart` above)
    live — both apply per-instance, so the _same_ video can hit disk cache
    in one `_VideoPostItem` instance (e.g. Home) and not another (e.g.
    `FullScreenVideoScreen`) depending on timing; this is expected, not a
    bug, for Cloudinary posts, and moot for Bunny posts (cache skipped
    entirely).
  - `_FeedSlots` / `_FeedItem` — feed ordering/pagination helpers, including
    periodic "Shorts shelf" slots inserted into the display sequence.
  - `VideoPreloadCache` lives in its own file (see below) but is used
    extensively from here for neighbor-video preloading — the preload
    window is next-2/prev-1 (not just next-1) across all 5 feed screens
    (Home, FullScreenVideoScreen, ShortsScreen, UserVideoFeedScreen,
    SingleVideoScreen), for smoother fast-swipe playback.
- `screens/video_preload_cache.dart` — static, URL-keyed cache used by
  `home_screen.dart` to preload upcoming videos' controllers ahead of a
  swipe (next-2/prev-1 window). Has its own 12s init timeout so a stuck
  preload can't permanently block that URL from being retried. Only
  preloads **neighbors**, never the currently-displayed video.
- `screens/media_utils.dart` — small, pure (non-Flutter-widget) string/URL
  helper functions: `playableVideoUrl()` (network-aware Cloudinary quality
  transform; passes Bunny URLs through unchanged) and `cloudinaryThumbUrl()`
  (Cloudinary still-frame URL, or Bunny's sibling `thumbnail.jpg` path — see
  §3). Keep pure utilities here rather than in a screen file; don't add
  widgets to this file.
- `screens/upload_screen.dart` — upload flow. First a chooser (📱 Short =
  full-screen vertical / ▶️ Video = landscape), then pick + trim + caption +
  upload to **Bunny Stream** (see §3 for the exact mechanism and the
  Trim/Borrowed-Sound limitations), writing `videoType` ('short'/'long') to
  the post. Also handles filters, text overlays, and speed via
  `text_overlay_style.dart` and `video_effects_baker.dart` (baked-in
  effects, so playback code doesn't need to re-apply speed/filters at watch
  time for baked posts). Client-side compresses the video (flutter_compress,
  1280px cap, ~60% bitrate) before upload to cut file size/bandwidth cost.
  Network-aware: fails fast with a friendly message if offline before
  starting, has a 120s send timeout, does one quiet auto-retry (3s delay) on
  a classified network error before giving up, and relabels the button
  "Retry Upload" after a failure — the picked video/caption state is
  preserved either way.
- `screens/trim_editor_screen.dart` — video trim UI (video_editor). Every
  picked video (camera or gallery) is unconditionally routed through here —
  see the Trim limitation note in §3.
- `screens/text_overlay_style.dart`, `screens/video_effects_baker.dart` —
  text-overlay styling and baking video effects (filters/speed) into the
  exported file at upload time.
- `screens/content_filter.dart` — content/keyword filtering helper.
- `screens/profile_screen.dart` — own profile: avatar, name, Edit Profile,
  stats (Posts / Followers / Following), video grid (tap = open viewer,
  long-press = delete own post), TikTok-style view count on each thumbnail.
  AppBar has Wallet, **Logout** (behind a confirmation dialog), a
  **Settings** gear icon (→ `settings_screen.dart`), and a 3-dot menu
  (**Delete account** — has a confirmation dialog + password
  re-authentication). Also contains `EditProfileScreen` (edit name + profile
  photo via Camera or Gallery → **still uploads to Cloudinary, not yet
  migrated to Bunny** — profile photos are images, not video, so this
  wasn't touched by the Bunny migration and will still fail while
  Cloudinary is disabled).
- `screens/public_profile_screen.dart` — another user's profile: photo
  (with the sparkle-star online badge), name, Follow / Message buttons,
  stats, video grid, and a 3-dot menu with **Block user**
  (`_confirmBlockUser`, writes `users/{myId}/blocked/{blockedUserId}`).
- `screens/story_screen.dart` — Stories. Facebook-style story cards bar,
  add-story flow (photo/video → **still uploads to Cloudinary, not yet
  migrated to Bunny** — same caveat as profile photos above) → 14-hour
  expiry, full-screen viewer with segmented progress bars + auto-advance,
  floating reactions that rise up, and a "See who reacted" list for the
  story owner.
- `screens/chat_screen.dart` — chat list (`ChatScreen`/`_ChatScreenState`,
  actually lists **all other users**, not just existing conversations — it's
  also how you start a brand-new chat) + `ChatThreadScreen` (text / image /
  voice messages, typing/recording indicators, read receipts, video-call
  button; each message's "Sent"/"Seen" row shows "Sending..." instead while
  `metadata.hasPendingWrites` is true — see §3). The list:
  - Shows the sparkle-star online badge per user (`presence_badge.dart`).
  - Shows an **"online now"** horizontal strip above the main list (users
    currently online; hidden while searching or when nobody is online).
  - Is **sorted by most recent activity** — whoever you most recently
    messaged (`chats/{chatId}.lastMessageAt`) or called
    (`chats/{chatId}.lastCallAt`, written by `_startVideoCall()` alongside
    the pre-existing `calls/{chatId}` doc) moves to the top. Users with no
    chat/call history yet sort after, in a stable (not random) order.
- `screens/video_call_screen.dart`, `screens/incoming_call_screen.dart`,
  `call_kit_service.dart`, `screens/call_push_service.dart`,
  `active_call.dart` — LiveKit calls (voice/video via a shared
  `_startVideoCall({required bool withCamera})`), CallKit-style incoming-call
  UI/push (FCM data message → `showWhenLocked`/`turnScreenOn` so the ringing
  screen surfaces over a locked screen; `requestDismissKeyguard()` lets a
  swipe-only/no-lock phone go straight into the call — a phone with an actual
  PIN/pattern/password still requires it, which is an OS guarantee no app can
  bypass), the caller-only ring-back tone and the speaker-toggle fix (both
  §3), `CallForegroundService.kt` (see §3), Picture-in-Picture on leaving Fly
  mid-call, and a shared drawing overlay. `kTokenServerUrl`/
  `kAppSharedSecret` (the Worker URL and shared secret) are defined here as
  top-level `const`s and imported with a `show` clause elsewhere. See §3 for
  the two known, not-yet-fixed call bugs.
- `screens/live_screen.dart` — live streaming.
- `screens/gifting.dart` — virtual gifting.
- `screens/wallet_screen.dart` — in-app wallet/coins.
- `screens/sound_screen.dart`, `screens/sounds_library_screen.dart` — sound/
  music attached to posts and a browsable sound library.
- `screens/face_filter_camera_screen.dart` — AR face-filter camera capture.
- `screens/notifications_screen.dart` — notifications list.
- `notification_service.dart` — flutter_local_notifications wrapper;
  `registerAndSaveToken()` saves the device's `fcmToken` onto the user's
  Firestore doc.

### Native Android (`android/app/src/main/`)

- `AndroidManifest.xml` — see the Impeller note above; also declares both
  foreground services and their `FOREGROUND_SERVICE_*` permissions.
- `kotlin/com/aungdev/fly/MainActivity.kt` — hosts the `fly/background`
  `MethodChannel` (`moveToBackground`, `setCallActive`/`clearCallActive`,
  `startPresenceService`/`stopPresenceService`), Picture-in-Picture handling,
  and `requestDismissKeyguard()`.
- `kotlin/com/aungdev/fly/CallForegroundService.kt`,
  `PresenceForegroundService.kt` — see §3.

### Outside the Flutter repo

- **Cloudflare Worker** (`livekit_token_worker.js`) — not in this git repo;
  lives in the Cloudflare dashboard (Workers & Pages →
  `livekit-token-worker` → Edit code). If you need to change it, ask Ko to
  paste the current content (there's no raw-URL fetch for it the way there
  is for the Flutter repo), and always give him the full file back to paste
  over the whole thing, same as any other file here.
- **Bunny.net Stream dashboard** — Library ID 756617,
  `vz-a6ab9346-730.b-cdn.net`. Video processing status ("Processing" →
  "Finished") is visible per-video here; useful to check first if a newly-
  uploaded video won't play yet (may just still be transcoding, not broken).

_(If a path differs slightly, list the repo tree via the GitHub API or fetch the
directory to confirm before editing. Given how large `home_screen.dart` is,
always grep/search within it for a class name before assuming a "missing"
screen needs to be created from scratch — it may already exist there.)_

---

## 5. Firestore data model

- `users/{uid}`: { displayName, photoUrl, email, fcmToken, isOnline,
  lastActive, hasSeenOnboarding, sawSwipeHint }
  - `users/{uid}/followers/{id}`, `users/{uid}/following/{id}`: { createdAt }
  - `users/{uid}/notifications/{id}`: { type, text, fromId, fromName, fromPhoto,
    postId?, seen, createdAt }
  - `users/{uid}/blocked/{blockedUserId}`: { createdAt } — who this user has
    blocked; read by `home_screen.dart`'s feed queries to filter out blocked
    users' posts, and by `blocked_users_screen.dart` to list/unblock. Not yet
    enforced in chat (see `blocked_users_screen.dart` note above).
- `posts/{id}`: { userId, userEmail, videoUrl (Bunny HLS playlist for new
  posts, Cloudinary mp4 for old ones — see §3), caption,
  reactions:{uid→type}, videoType('short'|'long'), createdAt, videoSpeed,
  filterType, blurBackground, textOverlays, effectsBaked, plus repost fields
  (repostByName, repostByUserId, repostByPhoto, repostNote) when the item is
  a repost }
  - `posts/{id}/comments/{id}` (+ `.../replies/{id}`): { userId, displayName,
    photoUrl, text, reactions, createdAt }
  - `posts/{id}/views/{uid}`, `posts/{id}/saves/{uid}`, `posts/{id}/shares/{uid}`
    — one doc per user, used for counting.
- `stories/{id}`: { userId, userName, userPhoto, mediaUrl, mediaType('image'|
  'video'), createdAt, expiresAt } — filtered client-side by `expiresAt > now`
  (14-hour lifetime).
  - `stories/{id}/reactions/{uid}`: { uid, type, userName, userPhoto, createdAt }
- `chats/{chatId}` (chatId = sorted `{uidA}_{uidB}`): { participants: [uidA,
  uidB], lastMessage, lastMessageAt, lastSenderId, lastCallAt }, plus
  `messages`/`activity` subcollections.
- `calls/{chatId}`: { callerId, callerName, callerPhoto, calleeId, roomName,
  status ('ringing'/...), createdAt } — call signaling. See §3 for the two
  known bugs around this doc's lifecycle (decline-while-killed,
  cancel-while-ringing).

**Firestore security rules** are managed in the **Firebase Console → Firestore →
Rules** (NOT auto-deployed from this repo, and not readable by the assistant).
If you add a new collection or subcollection that the client reads/writes,
remind Ko to update and publish the rules in the Console.

---

## 6. Current features (already built)

Auth + auto-login (with a mascot-guided login screen, recent-account
quick-switch, and Forgot Password) · Flyla mascot onboarding tour for
first-time users · full-screen video feed (short vs landscape, Smart-Fit
sizing) · media controls + scrub slider + mute · reactions / comments /
replies · follow · view / like / comment / share / save counts · profile
stats + video viewer + delete own posts · camera/gallery profile photo ·
video filters/speed/text-overlays baked at upload time · sounds library ·
face-filter camera · hashtags · content/keyword filtering · translation ·
report/block a post or a user, with a Settings → Blocked-accounts screen to
unblock · chat (text/image/voice) + typing indicators + read receipts, sorted
by most recent message/call activity, with an "online now" strip · video/voice
calls (LiveKit, via a Cloudflare Worker token server) + CallKit-style
incoming-call UI/push + caller ring-back tone + working speaker toggle +
shared drawing + Picture-in-Picture · online-presence system (sparkle-star
badge, Firestore heartbeat, a foreground service so it survives the screen
locking) · live streaming · gifting · in-app wallet · notifications ·
**Stories** (FB-style cards, 14h expiry, floating reactions, "who reacted"
list) · **network resilience** (status banner, adaptive quality, load-error
retry, upload retry, offline-persisted chat/feed, disk-cached recently-
watched Cloudinary videos) · video hosting on **Bunny Stream** (migrated
from Cloudinary; auto-transcoding/adaptive HLS/thumbnails).

### Known, deliberately-not-yet-fixed gaps

- Blocking a user does not currently stop them from sending chat messages
  (only feed visibility is filtered).
- No true real-time "offline the instant they lose connection" presence
  (Fly has no Realtime Database) — presence is heartbeat + a 60s staleness
  window, which is accurate enough for the UI's purposes but not instant.
- Trim and Borrowed Sound don't work for new (Bunny-hosted) video posts —
  see §3. Trim silently no-ops (posts the full video); Borrowed Sound is
  blocked at upload time with a message.
- Profile photos and Stories still upload to Cloudinary, not Bunny — they'll
  fail while that account stays disabled, and weren't in scope for the
  video-focused Bunny migration.
- Offline replay of a previously-watched video only works for old
  Cloudinary posts, not new Bunny (HLS) ones — see §3.
- Two call-lifecycle bugs (decline-while-app-killed not reaching the
  caller; caller-cancel not dismissing the callee's still-ringing screen) —
  see §3 for the full explanation and what a fix would need.
- Cloudinary account (cloud_name `dwx402gy4`) is currently **disabled**
  (usage-quota exceeded) — all old Cloudinary-hosted content (videos,
  profile photos, stories) is unplayable/unloadable until Ko either
  upgrades the plan or enough of the rolling 30-day usage window rolls off.

---

## 7. How to help (workflow)

1. Read this file to understand the project.
2. When Ko asks to change something, **fetch the current file(s)** from the raw
   GitHub URL(s) so you edit the real, up-to-date code — don't rely on this
   file's descriptions for exact code content, only for orientation. The
   Cloudflare Worker is the one exception — it's not in this repo (see §4,
   "Outside the Flutter repo"); ask Ko to paste its current content instead.
3. For anything nontrivial (layout/rendering bugs, navigation, native Android
   code, anything touching video playback or calls), prefer a short read-only
   investigation and a stated plan before editing, and keep changes as small
   and isolated as possible — this is how Ko prefers to work and de-risks
   bleeding-edge-toolchain surprises. When a mechanism doesn't work as
   expected (e.g. a third-party package silently failing), don't assume the
   next attempt is right either — ask Ko to actually test before declaring it
   fixed; today's Bunny upload work needed three attempts before one worked.
4. Reply in Burmese with a **full-file rewrite** (English comments/strings).
5. If a new collection/field is added, tell Ko to update **Firestore rules** in
   the Firebase Console.
6. After changes, remind Ko to run `flutter pub get` (if a dependency
   changed), then **`flutter analyze` before building** (catches type/import
   errors immediately instead of burning a full APK build cycle on them),
   then `flutter build apk --release` (or `flutter run` for a quicker debug
   loop), and once tested, walk him through `git add <specific files>`,
   `git status`, `git commit -m "..."`, `git push` one step at a time.
7. Keep this file itself updated after a significant batch of new features —
   Ko has asked for this to be kept current so future sessions don't have to
   rediscover the same context from scratch.

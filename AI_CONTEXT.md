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
  sometimes runs `flutter run` for quicker debug-mode iteration.
- Ko builds **one feature at a time** and tests before moving on. Prefer small,
  isolated, verifiable steps — especially for anything touching layout,
  navigation, video playback, or native Android (Kotlin/Manifest) code, where
  Ko has previously asked for careful, staged, read-only-investigation-first
  workflows before any code change.
- After a change is confirmed working, Ko asks to commit and push. Give him the
  exact `git add` (naming the specific changed files, not `git add .`),
  `git status` (to confirm), `git commit -m "..."`, and `git push` commands,
  one block at a time, and wait for his pasted terminal output before
  continuing. If `flutter pub get` or a native/Gradle change caused
  `pubspec.lock`, `macos/Flutter/GeneratedPluginRegistrant.swift`, or similar
  generated files to also show as modified, tell him to add and commit those
  too.
- Ko likes a **playful, colorful, mascot-driven UI** (see "Flyla" the bird
  mascot, gradient logos, sparkle animations) and cares about small UX details
  (confirmation dialogs before destructive actions, friendly error messages
  instead of raw error text, cute reactions instead of plain state changes).
  Default to this style for new UI unless told otherwise.
- The assistant (Claude) typically has **no Flutter SDK, emulator, or physical
  device** in its own environment — it cannot run `flutter analyze`,
  `flutter build`, or `flutter run` itself. Always give Ko the exact commands
  to run and wait for his results; never claim something was built, tested, or
  verified without him actually running it.

---

## 3. Tech stack & configuration

- **Flutter** (Android target, package `com.aungdev.fly`).
- **Firebase** — project ID `aung-1756e`. Uses **Firestore** + **Email/Password
  Auth**. On the **free Spark plan** (NO Cloud Functions / no Blaze), so anything
  requiring a backend/Cloud Functions (e.g. push notifications when the app is
  closed, deleting Cloudinary assets, server-generated codes/tokens) is
  intentionally avoided. Ko has explicitly said he wants to avoid moving to
  Blaze — always mention this trade-off before suggesting a feature that would
  require it, and offer a Spark-compatible alternative first.
  - No `firestore.rules` file is version-controlled in this repo — security
    rules are managed directly in the **Firebase Console → Firestore → Rules**.
    If you add a new collection/field the client reads or writes, remind Ko to
    check/update the rules in the Console; you cannot inspect or confirm the
    current rules yourself.
- **Cloudinary** (media hosting) — cloud name `dwx402gy4`, unsigned upload preset
  `fly_unsigned`.
  - Image upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/image/upload`
  - Video/audio upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/video/upload`
  - Trim transform: insert `so_<start>,eo_<end>` after `/upload/`.
  - Video first-frame thumbnail: insert `so_0/` after `/upload/` and change the
    extension to `.jpg`.
- **LiveKit** (video/voice calls) — server `wss://fly-iv33xo63.livekit.cloud`.
  The token server was moved to a **Cloudflare Worker** (to avoid needing
  Firebase Blaze billing) — do not assume a LiveKit sandbox connection-details
  endpoint or a Firebase Cloud Function is issuing tokens; confirm the current
  token-fetch code path in `video_call_screen.dart`/`call_push_service.dart`
  before changing call logic. (API secret is NOT stored in this repo.)
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

### Key packages (pubspec.yaml)

firebase_core, firebase_auth, firebase_storage, cloud_firestore, http,
image_picker, video_player, cached_network_image, video_editor, share_plus,
flutter_local_notifications, livekit_client, audioplayers, path_provider,
flutter_sound, permission_handler, shared_preferences, url_launcher.

### Build toolchain (bleeding-edge but working)

AGP 8.9.1, Gradle 9.1.0, JDK 25, compileSdk 36.
⚠️ Never edit gradle/dart/XML files with Notepad or PowerShell here-strings
(they inject a BOM / strip characters). Use VS Code only.

---

## 4. File structure (all under `lib/`, unless noted)

- `main.dart` — app entry, Firebase init, auth gate / auto-login
  (`_ensureUserDoc` creates the user's Firestore doc on first login),
  `firebaseMessagingBackgroundHandler` for incoming-call push data messages.
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
  - In-app "ding" sound on new messages; incoming-call listening/UI.
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
  - `_FeedSlots` / `_FeedItem` — feed ordering/pagination helpers, including
    periodic "Shorts shelf" slots inserted into the display sequence.
  - `VideoPreloadCache` lives in its own file (see below) but is used
    extensively from here for neighbor-video preloading.
- `screens/video_preload_cache.dart` — static, URL-keyed cache used by
  `home_screen.dart` to preload the next/previous video's controller ahead of
  a swipe. Only preloads **neighbors**, never the currently-displayed video —
  relevant if investigating cold-start/flicker issues on freshly-opened video
  screens.
- `screens/media_utils.dart` — small, pure (non-Flutter-widget) string/URL
  helper functions (e.g. building a Cloudinary thumbnail URL). Keep pure
  utilities here rather than in a screen file; don't add widgets to this file.
- `screens/upload_screen.dart` — upload flow. First a chooser (📱 Short =
  full-screen vertical / ▶️ Video = landscape), then pick + trim + caption +
  upload to Cloudinary, writing `videoType` ('short'/'long') to the post. Also
  handles filters, text overlays, and speed via `text_overlay_style.dart` and
  `video_effects_baker.dart` (baked-in effects, so playback code doesn't need
  to re-apply speed/filters at watch time for baked posts).
- `screens/trim_editor_screen.dart` — video trim UI (video_editor).
- `screens/text_overlay_style.dart`, `screens/video_effects_baker.dart` —
  text-overlay styling and baking video effects (filters/speed) into the
  exported file at upload time.
- `screens/content_filter.dart` — content/keyword filtering helper.
- `screens/profile_screen.dart` — own profile: avatar, name, Edit Profile,
  stats (Posts / Followers / Following), video grid (tap = open viewer,
  long-press = delete own post), TikTok-style view count on each thumbnail.
  AppBar has Wallet, **Logout** (now behind a confirmation dialog explaining
  that switching accounts means logging out and signing back in with a
  different email — logout used to be a single un-confirmed tap), a
  **Settings** gear icon (→ `settings_screen.dart`), and a 3-dot menu
  (**Delete account** — already had a confirmation dialog + password
  re-authentication before this; that flow was not changed). Also contains
  `EditProfileScreen` (edit name + profile photo via Camera or Gallery →
  Cloudinary → Firestore `photoUrl`).
- `screens/public_profile_screen.dart` — another user's profile: photo
  (with the sparkle-star online badge), name, Follow / Message buttons,
  stats, video grid, and a 3-dot menu with **Block user**
  (`_confirmBlockUser`, writes `users/{myId}/blocked/{blockedUserId}`).
- `screens/story_screen.dart` — Stories. Facebook-style story cards bar,
  add-story flow (photo/video → Cloudinary → 14-hour expiry), full-screen
  viewer with segmented progress bars + auto-advance, floating reactions that
  rise up, and a "See who reacted" list for the story owner.
- `screens/chat_screen.dart` — chat list (`ChatScreen`/`_ChatScreenState`,
  actually lists **all other users**, not just existing conversations — it's
  also how you start a brand-new chat) + `ChatThreadScreen` (text / image /
  voice messages, typing/recording indicators, read receipts, video-call
  button). The list:
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
  bypass), `CallForegroundService.kt` (see Tech Stack), Picture-in-Picture on
  leaving Fly mid-call, and a shared drawing overlay.
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
  `PresenceForegroundService.kt` — see Tech Stack section above.

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
- `posts/{id}`: { userId, userEmail, videoUrl, caption, reactions:{uid→type},
  videoType('short'|'long'), createdAt, videoSpeed, filterType, blurBackground,
  textOverlays, effectsBaked, plus repost fields (repostByName, repostByUserId,
  repostByPhoto, repostNote) when the item is a repost }
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
  status ('ringing'/...), createdAt } — call signaling.

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
incoming-call UI/push + shared drawing + Picture-in-Picture · online-presence
system (sparkle-star badge, Firestore heartbeat, a foreground service so it
survives the screen locking) · live streaming · gifting · in-app wallet ·
notifications · **Stories** (FB-style cards, 14h expiry, floating reactions,
"who reacted" list).

### Known, deliberately-not-yet-fixed gaps

- Blocking a user does not currently stop them from sending chat messages
  (only feed visibility is filtered).
- No true real-time "offline the instant they lose connection" presence
  (Fly has no Realtime Database) — presence is heartbeat + a 60s staleness
  window, which is accurate enough for the UI's purposes but not instant.

---

## 7. How to help (workflow)

1. Read this file to understand the project.
2. When Ko asks to change something, **fetch the current file(s)** from the raw
   GitHub URL(s) so you edit the real, up-to-date code — don't rely on this
   file's descriptions for exact code content, only for orientation.
3. For anything nontrivial (layout/rendering bugs, navigation, native Android
   code, anything touching video playback or calls), prefer a short read-only
   investigation and a stated plan before editing, and keep changes as small
   and isolated as possible — this is how Ko prefers to work and de-risks
   bleeding-edge-toolchain surprises.
4. Reply in Burmese with a **full-file rewrite** (English comments/strings).
5. If a new collection/field is added, tell Ko to update **Firestore rules** in
   the Firebase Console.
6. After changes, remind Ko to build (`flutter build apk --release`, or
   `flutter run` for a quicker debug loop) and, once tested, walk him through
   `git add <specific files>`, `git status`, `git commit -m "..."`, `git push`
   one step at a time.
7. Keep this file itself updated after a significant batch of new features —
   Ko has asked for this to be kept current so future sessions don't have to
   rediscover the same context from scratch.

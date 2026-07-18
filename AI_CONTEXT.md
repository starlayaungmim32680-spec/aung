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
image / voice / video call), profiles, follow, reactions, comments, and more.

- **GitHub repo:** https://github.com/starlayaungmim32680-spec/aung
- **Default branch:** `main`
- **Raw file URL pattern (fetch current code from here):**
  `https://raw.githubusercontent.com/starlayaungmim32680-spec/aung/main/<path>`
  - Example: `https://raw.githubusercontent.com/starlayaungmim32680-spec/aung/main/lib/screens/home_screen.dart`

---

## 2. Owner & working style (please follow)

- The owner is **Ko** and communicates in **Burmese**. Please reply in Burmese.
  Ko addresses the assistant as "ဆရာ" (teacher).
- **Always provide a FULL file rewrite** (the entire file, top to bottom), never
  a diff or partial snippet.
- **All code comments and strings must be in English** (only chat replies are in
  Burmese).
- Ko develops on **Windows + VS Code**, and tests by building a release APK and
  side-loading it on an Android phone (`flutter build apk --release`).
- Ko builds **one feature at a time** and tests before moving on. Prefer small,
  verifiable steps.

---

## 3. Tech stack & configuration

- **Flutter** (Android target, package `com.example.fly`).
- **Firebase** — project ID `aung-1756e`. Uses **Firestore** + **Email/Password
  Auth**. On the **free Spark plan** (NO Cloud Functions / no Blaze), so anything
  requiring a backend/Cloud Functions (e.g. push notifications when the app is
  closed, deleting Cloudinary assets) is intentionally avoided.
- **Cloudinary** (media hosting) — cloud name `dwx402gy4`, unsigned upload preset
  `fly_unsigned`.
  - Image upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/image/upload`
  - Video/audio upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/video/upload`
  - Trim transform: insert `so_<start>,eo_<end>` after `/upload/`.
  - Video first-frame thumbnail: insert `so_0/` after `/upload/` and change the
    extension to `.jpg`.
- **LiveKit** (video/voice calls) — server `wss://fly-iv33xo63.livekit.cloud`;
  token fetched from the LiveKit sandbox connection-details endpoint. (API secret
  is NOT stored in this repo.)

### Key packages (pubspec.yaml)

firebase_core, firebase_auth, firebase_storage, cloud_firestore, http,
image_picker, video_player, cached_network_image, video_editor, share_plus,
flutter_local_notifications, livekit_client, audioplayers, path_provider,
flutter_sound, permission_handler.

### Build toolchain (bleeding-edge but working)

AGP 8.9.1, Gradle 9.1.0, JDK 25, compileSdk 36.
⚠️ Never edit gradle/dart files with Notepad or PowerShell here-strings (they
inject a BOM / strip characters). Use VS Code only.

---

## 4. File structure (all under `lib/`)

- `main.dart` — app entry, Firebase init, auth gate / auto-login.
- `screens/login_screen.dart`, `screens/signup_screen.dart` — auth.
- `screens/main_navigation_screen.dart` — the shell. Draggable rainbow
  floating button that toggles a frosted-glass bottom nav pill
  (Home / Chat / Upload / Profile via IndexedStack). The rainbow button shows an
  **X** when the menu is open and a rotating rainbow ≡ when closed. Also handles
  in-app "ding" sound on new messages and incoming-call listening.
- `screens/home_screen.dart` — the main video feed (large file). Full-screen
  vertical PageView; short videos fill the screen (BoxFit.cover), landscape
  videos show natural aspect ratio. Tap = show media controls (rewind10 /
  play-pause / forward10) + a bottom control bar (time / scrub slider / mute);
  tap again = hide + play. Right rail: Like (thumbs-up + long-press reactions),
  Comment, Share, Save — each with a count. View count is recorded per user.
  Also contains the reusable `_VideoPostItem`, the comments sheet, the top
  Stories bar, and `UserVideoFeedScreen` (a full-screen swipeable viewer of one
  user's posts, opened from a profile grid).
- `screens/upload_screen.dart` — upload flow. First a chooser (📱 Short =
  full-screen vertical / ▶️ Video = landscape), then pick + trim + caption +
  upload to Cloudinary, writing `videoType` ('short'/'long') to the post.
- `screens/trim_editor_screen.dart` — video trim UI (video_editor).
- `screens/profile_screen.dart` — own profile: avatar, name, Edit Profile,
  stats (Posts / Followers / Following), video grid (tap = open viewer,
  long-press = delete own post), TikTok-style view count on each thumbnail.
  Also contains `EditProfileScreen` (edit name + profile photo via Camera or
  Gallery → Cloudinary → Firestore `photoUrl`).
- `screens/public_profile_screen.dart` — another user's profile: photo, name,
  Follow / Message buttons, stats, video grid (tap = open viewer).
- `screens/story_screen.dart` — Stories. Facebook-style story cards bar,
  add-story flow (photo/video → Cloudinary → 14-hour expiry), full-screen viewer
  with segmented progress bars + auto-advance, floating reactions that rise up,
  and a "See who reacted" list for the story owner.
- `screens/chat_screen.dart` — chat list + thread (text / image / voice
  messages, typing/recording indicators, read receipts, video-call button).
- `screens/video_call_screen.dart`, `screens/incoming_call_screen.dart` —
  LiveKit calls (voice-call style, shared drawing overlay, code-generated
  ringtone).
- `screens/notifications_screen.dart` — notifications list.
- `notification_service.dart` — flutter_local_notifications wrapper.

_(If a path differs slightly, list the repo tree via the GitHub API or fetch the
directory to confirm before editing.)_

---

## 5. Firestore data model

- `users/{uid}`: { displayName, photoUrl, email }
  - `users/{uid}/followers/{id}`, `users/{uid}/following/{id}`: { createdAt }
  - `users/{uid}/notifications/{id}`: { type, text, fromId, fromName, fromPhoto,
    postId?, seen, createdAt }
- `posts/{id}`: { userId, userEmail, videoUrl, caption, reactions:{uid→type},
  videoType('short'|'long'), createdAt }
  - `posts/{id}/comments/{id}` (+ `.../replies/{id}`): { userId, displayName,
    photoUrl, text, reactions, createdAt }
  - `posts/{id}/views/{uid}`, `posts/{id}/saves/{uid}`, `posts/{id}/shares/{uid}`
    — one doc per user, used for counting.
- `stories/{id}`: { userId, userName, userPhoto, mediaUrl, mediaType('image'|
  'video'), createdAt, expiresAt } — filtered client-side by `expiresAt > now`
  (14-hour lifetime).
  - `stories/{id}/reactions/{uid}`: { uid, type, userName, userPhoto, createdAt }
- `chats/{chatId}` (chatId = sorted `{uidA}_{uidB}`) with `messages`, `activity`
  subcollections; `calls/{chatId}` for call signaling.

**Firestore security rules** are managed in the **Firebase Console → Firestore →
Rules** (NOT auto-deployed from this repo). If you add a new collection or
subcollection that the client reads/writes, remind Ko to update and publish the
rules in the Console.

---

## 6. Current features (already built)

Auth + auto-login · full-screen video feed (short vs landscape) · media controls

- scrub slider + mute · reactions / comments / replies · follow · view / like /
  comment / share / save counts · profile stats + video viewer + delete own posts ·
  camera/gallery profile photo · chat (text/image/voice) + typing indicators + read
  receipts · video/voice calls (LiveKit) + shared drawing · notifications ·
  **Stories** (FB-style cards, 14h expiry, floating reactions, "who reacted" list).

---

## 7. How to help (workflow)

1. Read this file to understand the project.
2. When Ko asks to change something, **fetch the current file(s)** from the raw
   GitHub URL(s) so you edit the real, up-to-date code.
3. Reply in Burmese with a **full-file rewrite** (English comments/strings).
4. If a new collection/field is added, tell Ko to update **Firestore rules** in
   the Firebase Console.
5. After changes, remind Ko to build (`flutter build apk --release`) and, once
   tested, to `git add . && git commit && git push`.

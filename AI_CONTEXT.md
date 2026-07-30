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
It's intended as a **global (worldwide-use) app**, not limited to one country
or language.

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
- When pasting code blocks in chat that contain `<...>` (e.g. Dart generics like
  `resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()`),
  copy-paste from chat has repeatedly corrupted/dropped the angle brackets.
  Prefer phrasing that avoids explicit generic type arguments where possible
  (e.g. declare the variable's type instead so Dart infers the generic).

---

## 3. Tech stack & configuration

- **Flutter** (Android target, package `com.example.fly`).
- **Firebase** — project ID `aung-1756e`. Uses **Firestore** + **Email/Password
  Auth**. Currently on the **free Spark plan**. Ko is in the process of
  upgrading to **Blaze** (pay-as-you-go) specifically to unlock **Cloud
  Functions** for two things: (a) sending FCM push notifications for incoming
  calls when the app is fully killed, and (b) triggering the self-hosted
  content-moderation service (see section 8). The Blaze upgrade is **not yet
  complete** — Google is requiring a one-time refundable prepayment
  (MYR 120) before enabling billing, and Ko is waiting until there are funds
  on the card before completing it. Until Blaze is active, avoid suggesting
  anything that requires Cloud Functions.
- **Cloudinary** (media hosting) — cloud name `dwx402gy4`, unsigned upload preset
  `fly_unsigned`.
  - Image upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/image/upload`
  - Video/audio upload endpoint: `https://api.cloudinary.com/v1_1/dwx402gy4/video/upload`
  - Trim transform: insert `so_<start>,eo_<end>` after `/upload/`.
  - Video first-frame thumbnail: insert `so_0/` after `/upload/` and change the
    extension to `.jpg`. (More generally, `so_<second>/` grabs the frame at
    that timestamp — used by the moderation service to sample multiple frames.)
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

⚠️ Windows PowerShell's `curl` is aliased to `Invoke-WebRequest`, which does not
accept curl-style `-H`/`-d` flags. For quick API tests, prefer
`Invoke-RestMethod -Uri ... -Method POST -ContentType "application/json" -Body '...'`
(single-quoted JSON body) over `curl`/`curl.exe`.

---

## 4. File structure (all under `lib/`)

- `main.dart` — app entry, Firebase init, auth gate / auto-login.
- `screens/login_screen.dart`, `screens/signup_screen.dart` — auth.
- `screens/main_navigation_screen.dart` — the shell. Draggable rainbow
  floating button that toggles a frosted-glass bottom nav pill
  (Home / Chat / Upload / Profile via IndexedStack). The rainbow button shows an
  **X** when the menu is open and a rotating rainbow ≡ when closed. Also handles
  in-app "ding" sound on new messages, and incoming-call listening
  (`_showIncomingCall` — see section 6, now also fires a full-screen
  notification so the call screen surfaces even if the phone is locked).
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
  **Posts are currently video-only** — there is no photo/image post type yet.
  Adding a "Photo" option to this chooser (single photo to start) is a planned
  next feature; when built, it should also call the image-moderation endpoint
  from section 8.
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
  ringtone). `incoming_call_screen.dart` now also cancels the full-screen
  incoming-call notification on accept/decline/dispose (see section 6).
- `screens/notifications_screen.dart` — notifications list (in-app list UI;
  do not confuse with `notification_service.dart`).
- `notification_service.dart` — flutter_local_notifications wrapper. Handles
  (a) regular chat-message notifications and (b) a full-screen, high-priority
  "incoming call" notification used to wake the screen / surface the call UI
  over the lock screen (`showIncomingCallNotification` /
  `cancelIncomingCallNotification`).

_(If a path differs slightly, list the repo tree via the GitHub API or fetch the
directory to confirm before editing.)_

---

## 5. Firestore data model

- `users/{uid}`: { displayName, photoUrl, email }
  - `users/{uid}/followers/{id}`, `users/{uid}/following/{id}`: { createdAt }
  - `users/{uid}/notifications/{id}`: { type, text, fromId, fromName, fromPhoto,
    postId?, seen, createdAt }
- `posts/{id}`: { userId, userEmail, videoUrl, caption, reactions:{uid→type},
  videoType('short'|'long'), createdAt } — video-only for now (see section 4,
  `upload_screen.dart`).
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
  **Stories** (FB-style cards, 14h expiry, floating reactions, "who reacted" list) ·
  **full-screen incoming-call notification** so a call still rings/surfaces even
  if the phone's screen is off or locked, as long as the app itself hasn't been
  fully killed (this was shipped and pushed to `main` — commit `39f57cc`,
  "Add full-screen incoming call notification for locked screen"). True
  Messenger-style ringing when the app is **fully killed** would additionally
  need FCM push + a Cloud Function — planned but blocked on Blaze billing
  (see section 3).

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

---

## 8. In progress: self-hosted AI content moderation (separate project)

Ko wants to auto-detect and remove bad text/images/videos from Fly (nudity,
toxicity, hate speech, etc.), and specifically chose a **self-hosted
open-source** approach over paid APIs (Google Vision/Video Intelligence,
Cloudinary's Rekognition add-on) to keep costs near-zero at Fly's current
scale, in exchange for doing more of the setup work himself.

**This lives in a separate folder/repo, NOT yet inside the Fly Flutter repo:**
`C:\Users\AUNG\Desktop\fly-moderation` on Ko's machine (not yet pushed to any
git remote as of this writing).

### Status: local prototype works end-to-end; not yet deployed or wired to Fly

What's built and tested successfully so far, all in
`C:\Users\AUNG\Desktop\fly-moderation`:

- **Python 3.11** + a venv (`venv\Scripts\activate`). Ko is new to Python — on
  his machine, Windows Device Guard/Smart App Control blocks `pip.exe`
  directly, so **always use `python -m pip ...`**, never bare `pip ...`.
- **Text moderation**: `detoxify` package, `Detoxify('original')` model —
  works well for **English only**. Returns toxicity/severe_toxicity/obscene/
  threat/insult/identity_attack scores.
- **Image moderation**: Hugging Face `transformers` pipeline with model
  `Falconsai/nsfw_image_detection` — works on any image regardless of
  language/caption (visual-only). Returns normal/nsfw scores.
- **Video moderation**: no dedicated video model — instead, sample 3-4 frames
  from the Cloudinary video URL using the `so_<second>/...jpg` trick (see
  section 3) and run each frame through the same image model, taking the
  worst (highest nsfw) score across frames. This avoids Google Video
  Intelligence's expensive per-minute billing.
- **`app.py`** — a Flask app wrapping all three as HTTP endpoints:
  `POST /moderate/text` `{"text": "..."}`,
  `POST /moderate/image` `{"image_url": "..."}`,
  `POST /moderate/video` `{"video_url": "...", "sample_seconds": [1,3,6,9]}`,
  plus `GET /` health check. Each returns a `flagged` boolean (score > 0.7
  threshold) plus the raw scores.
- **Dockerfile** (`python:3.11-slim` base, installs `requirements.txt`, runs
  via `gunicorn`) + `requirements.txt` + `.dockerignore` — built and run
  successfully locally (`docker build -t fly-moderation .` /
  `docker run -p 8080:8080 fly-moderation`), verified against all three
  endpoints with matching results to the non-Docker local run.

### Known limitation: language coverage for text moderation

Detoxify's English-only model is the main gap for a **global app**. Options
discussed, not yet implemented:

- `Detoxify('multilingual')` — adds French/Spanish/Italian/Portuguese/
  Turkish/Russian (7 languages total incl. English).
- **NVIDIA Nemotron Safety Guard** (Llama-3.1-8B based, open-source) — broader
  coverage (~20 languages), considered as an upgrade but not yet swapped in.
- Burmese (and most other languages) aren't well covered by either — the
  agreed mitigation is a 3-layer approach mirroring what Facebook/TikTok
  actually do: AI as first-pass filter → a user "Report" button (not yet
  built) → Ko (or a future moderator) reviewing an admin queue (not yet
  built). Image/video moderation is language-agnostic and unaffected by this
  gap.
- Google's **Perspective API** was considered and rejected — it's free but
  Google has announced it's **sunsetting Dec 31, 2026**, so not worth
  building on for a project this new.

### Blocked step: deploying to Cloud Run

The plan is to deploy this Docker image to **Google Cloud Run** (generous
free tier: 2M requests + 180,000 vCPU-seconds + 360,000 GB-seconds/month) and
call it from a Cloud Function that triggers on new `posts`/comments. This
requires Firebase **Blaze** billing to be active first (see section 3) —
currently blocked on Ko completing a one-time MYR 120 prepayment once there
are funds on his card.

**Recommended Cloud Run setting once deployed:** `min-instances=0` (do not
keep it warm 24/7). Moderation runs asynchronously after a post is already
live, so a 5-30 second cold-start delay on the first request after idle time
is acceptable — and this keeps cost near $0 for low/moderate traffic, since
idle time isn't billed at all in this mode. (`min-instances=1` would avoid
cold starts but bills for idle memory 24/7, roughly $6-15/month minimum
regardless of traffic — not worth it for this use case.)

### Not yet done (next steps for this sub-project, in order)

1. Complete Blaze billing upgrade (blocked on funds).
2. `gcloud` CLI install + `gcloud auth login` + deploy the Docker image to
   Cloud Run.
3. Write a Firestore-triggered Cloud Function (on new post/comment) that
   calls the deployed moderation endpoints and auto-hides/flags high-score
   content.
4. Build the user "Report" button + an admin review queue in Fly, as the
   backup layer for languages/content the AI model misses.
5. Consider upgrading the text model to `Detoxify('multilingual')` or
   NVIDIA Nemotron Safety Guard for broader language coverage.
6. Once the photo-upload feature (section 4) is built, wire it to
   `/moderate/image` too.

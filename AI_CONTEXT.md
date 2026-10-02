# Fly — AI Assistant Context File

> **Purpose of this file:** If you are an AI assistant helping with this project,
> read this file first. It gives you the full picture of the app, the tech stack,
> the coding conventions, and where every file lives. To edit any file, fetch its
> **current** content from the raw GitHub URL (pattern below), then reply with a
> **full-file rewrite** (not a diff).
>
> _Last major update: 26 Sep 2026 (photo-story effects, story music, sound
> copyright safeguards, full Firestore rules, Bunny upload fixes + "video
> ready" webhook). Sections marked **(Sep 2026)** describe that batch._
> _Latest small update: 1 Oct 2026 — chat photos/voice notes moved from
> Cloudinary to Bunny Storage; chat streams built once; note on networks
> that can't reach Firestore; Messenger-style Sent/Delivered/Seen and
> message reactions (`chat_delivery_service.dart`); AGP 8.9.1 → 8.11.1;
> chat message push (notification + "Delivered" with Fly closed) and
> tappable in-app notifications; comment/reaction notifications open the
> video (`PostFromNotificationScreen`); story replies push too._
> _2 Oct 2026: §2 and §7 rewritten as the exact working loop Ko wants
> every new chat to follow._
> _3 Oct 2026: public account-deletion page for Google Play (Worker
> `GET /delete-account` + `POST /delete-request` → `deletionRequests`)._
> _Last checked against the code: 27 Sep 2026 (commit `5955a16`) — fixed
> the nav-bar description, package list and feature list, and added Sky
> Note, Fly Memories, Reaction Pulse, Timeline Highlights, the 13+ age gate
> and back-button behavior, which were built but missing from this file._

> 🧭 **New chat with Ko? Read §2 (who Ko is, how he likes to work) and
> §7 (the exact step-by-step loop every task follows) before anything
> else.** Ko asked (2 Oct 2026) that every new chat works exactly the way
> the long Sep–Oct 2026 sessions did - §7 is that recipe.

> ℹ️ **This file is long (~1,400 lines).** Some web-fetch tools return only a
> short summary or a stale cached copy of it. If what you got has no
> "Bunny Stream" section or no To-do list near the end, you did **not** get
> the real file — fetch it again (or clone the repo) before relying on it.

> ⚠️ **Keep deployed code and the repo in sync (Ko's standing rule).**
> Two things run outside the Flutter app and are deployed **by hand**:
> the **Cloudflare Worker** (repo copy: `cloudflare/livekit_token_worker.js`)
> and the **Firestore security rules** (repo copy: `firestore.rules`).
> Every time either one is changed and Deployed (Cloudflare) or Published
> (Firebase Console), the **same file must also be committed and pushed**
> to this repo in the same session. Otherwise the repo copy silently drifts
> from what's actually live, and the next assistant will edit an outdated
> version. As the assistant: after giving Ko a new Worker or rules file,
> always finish with the `git add` / `commit` / `push` steps for it, and
> before editing either file, ask Ko to confirm the repo copy still matches
> what's live.

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
  Ko addresses the assistant as "ဆရာ" (teacher); call him "Ko". Keep the tone
  warm and encouraging (he signs off with 🥰 - a 🥰 back is fine), short
  paragraphs, simple words, bold for the key point. He often types fast with
  typos - read for meaning, don't correct him.
- When Ko asks **"ဘယ်လို အလုပ်လုပ်တာလဲ" (how does it work?)** about a planned
  feature, explain it BEFORE coding: what happens today, what will change,
  a small arrow flow (`A sends → Worker → FCM → B's phone`), an everyday
  analogy if it helps (post office / postman / address), edge cases, which
  files change, and whether rules/Worker change. Then ask "လုပ်မလား Ko?".
  If he already said "let's do it", explain briefly and deliver the code in
  the same reply.
- For UI, Ko's standing request is \*\*"like Facebook/TikTok, but not identical
  - cooler and prettier than them"\*\* (ပိုမိုက် ပိုလန်း). Add a Fly touch:
    Fly gradient (#FF4B6E → #9C4DFF → #3A8DFF), glass/blur banners, small
    spring/scale animations, haptics, friendly empty/error states - and say
    in the reply exactly what is "extra" compared to Facebook.
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
- **Fly is a global (worldwide) app.** Every user-facing text - in the
  app AND on web pages (e.g. `/delete-account`) - is **English only**. Don't
  add Burmese text or language toggles to the product (Ko asked to remove a
  Myanmar toggle on 3 Oct 2026). Burmese is only for chat replies to Ko.
- Ko is also thinking about a possible logo redesign: a "FLY" wordmark
  stylized as a bird (tail feathers before the F, wings sprouting near the Y,
  a round head+beak+eye after it) — inspired by wordmark-as-object techniques
  (e.g. "BEE" drawn as an actual bee). Not finalized into app-icon assets yet.
- When walking Ko through a web dashboard (Cloudflare, Bunny, Firebase
  Console), give **click-by-click steps** and have him send a screenshot
  when unsure. Before any **Delete** button, tell him to read the dialog's
  title first — in Sep 2026 a "Delete secret APP_SHARED_SECRET" dialog
  opened by mistake while he was trying to delete a different variable (it
  was cancelled in time; deleting it would have broken calls, uploads and
  live streaming). Never ask him to paste secrets/tokens into the chat.
- Ko plans to **earn money from the app later** (ads/coins), so treat
  licensing, copyright, security and cost-at-scale as real requirements, not
  nice-to-haves.
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
  - **(Sep 2026)** The full security rules now live in **`firestore.rules`
    at the repo root**, written from an audit of every Firestore read/write
    in `lib/`. They are still **published by hand** (Firebase Console →
    Firestore → Rules → paste the whole file → Publish) — nothing deploys
    them automatically. Treat the repo file as the source of truth: edit it,
    give Ko the full file, and remind him to paste + Publish. If something
    fails with `permission-denied` after a change, the rules are the first
    suspect. Highlights: owners-only edits for posts/stories/comments/
    profile; others may only toggle their own entry in a `reactions` map;
    chats/calls readable only by the two uids in the room id; `reports` is
    write-only; `videoStatus` is read-only for the app (the Worker writes it
    with a service account, which bypasses rules); `sounds` rules stop anyone
    undoing the report auto-hide (see the Sounds note below); coins may rise
    by at most 10 per write and never go negative.
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
  - **Upload flow (rewritten Sep 2026):** both feed posts
    (`upload_screen.dart`) and video stories (`story_screen.dart`) now go
    through **`video_upload_service.dart`**:
    1. trim (feed only - stories are cut earlier) → `compressVideoForUpload()`
       on the **final, trimmed file** (flutter_compress, 1280px, ~60%; falls
       back to the original if compression fails or doesn't shrink it, and
       logs why via `debugPrint`) — before this, a failed compression on a
       trimmed feed video uploaded the **untrimmed** original, and story
       videos were never compressed at all (a 16s clip was 65 MB on Bunny);
    2. `uploadVideoToBunny()` streams the file **from disk** (not memory) as
       a plain POST to the Worker's `/upload-video` with a real
       `Content-Length`, headers `Authorization` (Firebase ID token, see
       `worker_auth.dart`) + `X-Video-Title` (fixed
       ASCII like `"Fly video"`/`"Fly story"` — HTTP headers can't carry
       Burmese/emoji); rejects 0-byte files and anything over **95 MB**
       (Cloudflare free-plan body limit is 100 MB); timeout **scales with
       file size** (2–25 min, sized for a ~40 KB/s link) and on timeout the
       HTTP client is **closed**, which really aborts the request (a bare
       Dart `.timeout()` only stops waiting while the old upload keeps
       running in the background).
       **Orientation guard (Sep 2026):** unedited phone-camera videos (stored
       sideways + a rotate-90° flag) came out as a LANDSCAPE frame with the
       portrait picture shrunk between black bars — baked into the uploaded
       file (Bunny thumbnails showed the bars), so they looked tiny in the feed
       and stories. Edited videos were fine. The culprit was trim
       (`video_trimmer_2`) and/or compression (`flutter_compress`, whose docs
       say nothing about rotation) — not isolated. `keepVideoOrientation()`
       now compares each step's output with its input using
       `VideoPlayerController.value.size` (already rotation-corrected) and
       keeps the earlier file if portrait/landscape flipped. Videos uploaded
       before this fix stay tiny; re-upload them.
       The Worker creates the Bunny video slot, then relays the body through a
       `FixedLengthStream(Content-Length)` to Bunny's PUT API — so a phone that
       drops mid-upload makes the relay **fail** instead of Bunny silently
       accepting a short/empty file — and **deletes the slot** if anything goes
       wrong, returning an error so the app never creates a post for it.
       **Root cause of the stuck "Processing / 0 Bytes" videos seen on Bunny
       (Sep 2026):** a very slow phone connection (9 KB/s was observed) plus the
       old Worker neither checking the length nor cleaning up. It was not Bunny
       being slow (status.bunny.net showed no incident that day).
       Earlier history: a resumable TUS flow (`/create-video` + a client TUS
       library) was tried before the Worker proxy and produced 0-byte videos
       across two TUS packages; the cause was never pinned down. TUS remains an
       option for true resume-after-disconnect on bad connections, but only if
       the current path still fails in practice.
  - **"Video ready" flow (Sep 2026)** — so nobody but the uploader ever sees
    "Processing" while Bunny encodes: - New video posts/stories are written with `bunnyVideoId` +
    `videoReady: false` (`newVideoReadinessFields()`). - Bunny calls the Worker's
    **`/bunny-webhook?token=<BUNNY_WEBHOOK_TOKEN>`** (set in Bunny →
    Stream → library → Webhook URL; the token is a Worker secret, never
    commit or paste it). On status 3/4 (finished / first resolution
    playable) it writes `videoStatus/{bunnyGuid}` `{ready, failed,
status, updatedAt}` and sets `videoReady: true` on any post/story
    whose `bunnyVideoId` matches (status 5 → `videoFailed: true`). It
    uses the same Firebase service account as `/call-push`, with the
    Datastore OAuth scope, via Firestore's REST API. - Race-proofing: the app creates the doc and **then** calls
    `syncVideoReady()`, which checks `videoStatus/{id}` and flips the
    flag itself if encoding already finished first. - `isVideoVisibleTo(data, myUid)`: only an explicit `videoReady: false`
    hides a doc, and never from its own uploader. Applied to the **Home
    feed** (both post streams in `home_screen.dart`) and the **Stories
    bar**. Old docs without the field stay visible. - The uploader plays their fresh video **instantly from the local
    file** via `LocalVideoCache` (`local_video_cache.dart`, keyed by
    videoUrl, in-memory only). If the app restarts before encoding ends,
    playback falls back to the network and `_VideoPostItem` shows a
    **"Processing video..."** card that silently retries every 5s for
    Bunny (`.m3u8`) posts under 30 minutes old, instead of "Couldn't
    load". - Confirmed working end-to-end on two phones on 26 Sep 2026. - Encoding speed tip given to Ko: in Bunny → Stream → library →
    Encoding, keep only **360p/480p/720p** (fewer renditions = faster
    encoding and less storage cost).
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
  - **Trim now actually works** (this used to be a no-op - the note below
    is history, kept for context): every picked video is unavoidably routed
    through `TrimEditorScreen` with no way to skip it, so gating uploads on
    "was something trimmed" would've blocked every single upload. Instead,
    right before compression, `upload_screen.dart` (and, for stories,
    `story_screen.dart`) physically cuts the file to the selected range
    using **`video_trimmer_2`** (native MediaExtractor+MediaMuxer on
    Android / AVFoundation on iOS - deliberately not FFmpeg: the
    actively-maintained FFmpeg-for-Flutter forks are GPL-licensed, a real
    risk for a closed-source commercial app). Two earlier packages were
    tried and dropped first: `flutter_native_video_trimmer` lost the
    video's rotation metadata during its trim (trimmed videos rendered
    tiny/wrong-aspect-ratio), and `video_trimmer_2` itself initially failed
    to even build (its own `android/build.gradle` pins an old Gradle
    version incompatible with this project's - that specific failure
    turned out to be a transient network/download issue, not a real
    incompatibility, and building again worked). `TrimEditorScreen` takes
    an optional `maxDurationSeconds` (default 90, used by post uploads;
    stories pass 15 - see below) that caps how large a range
    `VideoEditorController` lets someone select in the first place.
  - **"Borrowed Sound" still has no Bunny equivalent** and is still blocked
    at upload time with a clear message (unlike trim, this genuinely has no
    workaround yet - it needs real audio/video muxing, which nothing in the
    app does client-side today).
  - Old Cloudinary-hosted posts are unaffected by any of the above (all the
    Cloudinary-specific URL transforms already safely no-op on a non-
    Cloudinary/Bunny URL) but remain unplayable unless/until that Cloudinary
    account itself gets reactivated — it's currently still disabled.
- **Profile photos and story images/videos are now on Bunny too**
  (migrated in a later session, after the feed-video migration above).
  - Profile photos (`profile_screen.dart`'s `EditProfileScreen`) and story
    images (`story_screen.dart`) go to **Bunny Storage** (a Storage Zone,
    not Stream - no transcoding needed for a still image) via the Worker's
    `/upload-image` endpoint: a plain PUT pass-through, mirroring
    `/upload-video`'s pattern. Story videos go to **Bunny Stream** via the
    existing `/upload-video`, exactly like feed posts.
  - **Chat photos and voice notes (1 Oct 2026, confirmed on phones)** use
    the same `/upload-image` path (`chat_screen.dart`'s
    `_uploadChatFile()`): file name `{uid}_chat_{ms}.jpg` / `.m4a` (etc.),
    Content-Type `image/jpeg` or the matching audio type, and the message
    stores `https://fly-images-aungdev756617.b-cdn.net/{fileName}`. They
    used to go to Cloudinary (disabled), so sending either failed. Old chat
    photos/voice notes on Cloudinary stay broken. No Worker/rules change.
  - Bunny Storage zone: `fly-images-aungdev756617` (Singapore region -
    its API host is the **region-specific** `sg.storage.bunnycdn.com`, not
    the generic `storage.bunnycdn.com` — using the generic one caused a
    401 Unauthorized that looked like a bad password but wasn't). Its Pull
    Zone's actual hostname is `fly-images-aungdev756617.b-cdn.net` — note
    the dashes are preserved from the storage zone name; an earlier
    hostname without dashes
    (`flyimagesaungdev756617.b-cdn.net`) was a wrong assumption that cost a
    debugging round (Bunny showed "Domain suspended or not configured"
    for the wrong host). Its "Block direct url file access" security
    setting must stay **OFF** - Fly's own HTTP requests carry no browser
    `Referer` header, so turning that on rejects the app while still
    letting Bunny's own dashboard player work (which is what made this one
    confusing to diagnose).
  - Worker secrets for this: `BUNNY_STORAGE_ZONE`, `BUNNY_STORAGE_PASSWORD`
    (the Storage Zone's non-read-only password - the read-only one can't
    upload and returns a 401 too if used by mistake).
  - Like the video-title header before it, an uploaded image's filename is
    sent as an `X-File-Name` header, so it's built server-side-safe (ASCII
    only, e.g. `{uid}_{timestamp}.jpg`) rather than derived from anything
    user-entered.
  - **Story videos are capped to 15 seconds** - both a snappier,
    Stories-like viewing experience and a hard bound on per-story Bunny
    cost. `TrimEditorScreen(maxDurationSeconds: 15)` enforces this at
    selection time (see the Trim note above).
  - **Story videos also get the same speed/filter/text-overlay effects
    step as feed posts** (`VideoEffectsScreen`, reused as-is), run on the
    already-trimmed file with `startSeconds: 0` (unlike
    `upload_screen.dart`, where trim is applied later and effects preview
    against the untrimmed original with an offset). Saved as the same
    `videoSpeed`/`filterType`/`textOverlays` fields on the `stories` doc.
    The story **viewer** (`_StoryViewerScreenState`) applies them at watch
    time exactly like `home_screen.dart` does for feed posts: a
    `ColorFiltered` wrapper (skipped entirely for `filterType: 'none'`,
    same reasoning as the feed - some devices tint even an identity
    filter), positioned text-overlay widgets, and `setPlaybackSpeed` (with
    the progress-bar segment's duration divided by speed, so it still
    finishes in step with the actual sped-up/slowed-down playback).
    **Story photos (Sep 2026)** get their own `PhotoEffectsScreen`
    (`photo_effects_screen.dart`): the same filter presets
    (`kVideoFilterMatrices`) with live thumbnails, text overlays (same
    style/animation/color dialog) and emoji/Klipy stickers, plus music.
    Nothing is baked into the pixels — the original JPEG is uploaded and the
    effects are stored on the story doc (`filterType`, `textOverlays`,
    `imageAspectRatio`). The viewer lays the image out in an `AspectRatio`
    box with that saved ratio so overlays land exactly where they were
    placed; old photo stories without the ratio keep the plain
    `BoxFit.contain` display. The filter uses a `ValueNotifier` so switching
    filters doesn't rebuild the overlays (Ko's flicker rule).
  - **Story music (Sep 2026)** — photo and video stories can pick a sound
    from the existing user-generated `sounds` library (see Sounds below)
    and choose a 15s window (`sound_sync_sheet.dart`). Unlike feed posts,
    nothing is muxed into the file: the story doc stores `soundId`,
    `soundTitle`, `soundOwnerName`, `soundSourceUrl`, `soundStartOffset`, and
    the viewer plays that window on a separate looping player
    (`StoryMusicPlayer` in `story_music.dart`) while muting the video. A
    photo story with music stays up 15s instead of 6s. A "♪ Title · Owner"
    chip under the author opens `SoundScreen` (story pauses, resumes on
    return). Hidden/removed sounds are checked (`isSoundPlayable`) before
    playing. A video story without music can share its own audio as an
    "Original sound" (doc id = story id) if the rights box is ticked.
  - **Stories can now be deleted** by their owner: a delete icon next to
    the viewer's close button (shown only when
    `data['userId'] == the signed-in user's uid`), behind the same
    confirm-dialog pattern `profile_screen.dart` uses for deleting a post.
    Deletes the Firestore doc only (no Bunny-side cleanup - same
    "best-effort" scope as the rest of the app's delete flows) and removes
    it from the viewer's local list so browsing the rest of that batch
    keeps working without reopening the viewer.
- **Sounds & copyright (Sep 2026)** — Fly has **no licensed music**. The
  only music source is the user-generated `sounds` collection (every
  video's own audio can become an "Original sound"). Ko wants to monetize
  later, so the library carries safeguards (`sound_moderation.dart`):
  - **Opt-in sharing:** a "Let others use my sound — I created this audio or
    have the rights to share it" checkbox (`SoundRightsCheckbox`), **off by
    default**, on feed uploads and video stories. Unticked → the video posts
    normally but no `sounds` doc is created (feed `soundId` is `''`).
  - **Report:** flag icon on `SoundScreen` (owner sees a delete icon
    instead). Writes a `reports` doc (`targetType: 'sound'`) and adds the
    reporter's uid to `sounds/{id}.reportedBy` (arrayUnion, so one person
    counts once).
  - **Auto-hide:** `kSoundReportHideThreshold = 5` distinct reporters →
    hidden from the library, sound page and story playback, with no manual
    step. Review in the Firebase Console by setting `status`: `'approved'`
    (show again, ignore reports) or `'removed'` (hide for good). Owners can
    set their own sound to `'removed'`; only the Console can approve.
  - **Policy page:** Settings → "Copyright & Sounds"
    (`CopyrightPolicyScreen`), with a takedown contact email from
    `kCopyrightContactEmail` (set by Ko; the repo is public, so it's visible).
  - Discussed but **not built yet**: a strike system (block sharing after 3
    removed sounds), automatic song recognition before sharing (AudD API,
    ~$5 per 1,000 checks after 300 free), and direct MP3 upload (only
    planned after recognition exists). Licensed catalogs were ruled out for
    now: Jamendo's API is free only for non-commercial use; Epidemic Sound's
    Partner API is free to prototype but going live is paid (price via
    sales). A lawyer should review the Terms before monetizing.
- **Bunny billing (Sep 2026):** Bunny is prepaid, not free: encoding is free,
  storage from $0.01/GB, delivery from $0.005/GB, **$1/month minimum**. Ko's
  account was on a **14-day free trial ($20 credit) ending around 3 Oct
  2026**, with $0.00 real balance — trial credit disappears when the trial
  ends, and a $0 balance can suspend Stream/Storage (all videos, photos,
  stories). He needs to add billing info and recharge (~$10 lasts months at
  current usage); paying from Myanmar may need a foreign card, PayPal or
  crypto. Cloudflare Worker stays on its free plan either way — keeping calls
  and push working even if Bunny lapses was one reason not to move the
  Worker to Bunny Edge Scripting.
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
    (`livekit-token-worker.chakaboycom.workers.dev`; source now copied into
    this repo at **`cloudflare/livekit_token_worker.js`**, chosen
    specifically to avoid needing Firebase Blaze billing). **Auth (Sep
    2026):** every route except the Bunny webhook requires
    `Authorization: Bearer <Firebase ID token>`; the Worker verifies the
    RS256 signature against Google's public JWKs
    (`securetoken@system.gserviceaccount.com`, cached per Cache-Control)
    and checks `aud`/`iss` = `FIREBASE_PROJECT_ID`, `exp`, `iat`, `sub`.
    The app gets the header from `workerAuthHeaders()` in
    `lib/screens/worker_auth.dart`. The old `X-App-Secret` header is only
    accepted while the `APP_SHARED_SECRET` Worker secret still exists
    (transition for old app builds) — once every phone runs the new build,
    **delete that secret** and the leaked value becomes useless.
    `/upload-image` also requires `X-File-Name` to start with the caller's
    own `uid_` (token callers). Routes:
    - `POST /token` — mints a LiveKit access token (`LIVEKIT_API_KEY`/
      `LIVEKIT_API_SECRET`/`LIVEKIT_URL` secrets).
    - `POST /call-push` — sends an FCM push (Google service-account OAuth2
      flow; `FIREBASE_PROJECT_ID`/`FIREBASE_CLIENT_EMAIL`/
      `FIREBASE_PRIVATE_KEY_B64` secrets) to wake a phone for an incoming
      call even if Fly is fully closed — see `firebaseMessagingBackgroundHandler`
      in `main.dart`. Body field `type` (Sep 2026): omitted/`'incoming_call'`
      = ring (needs `callerName`); `'call_cancelled'` = stop ringing (needs
      only `fcmToken` + `roomName`). Defaulting to incoming keeps old app
      builds working. `'chat_message'` (1 Oct 2026, confirmed) = new chat
      message (needs `fcmToken`, `chatId`, `senderName`; optional
      `senderPhoto`, `text`); the Worker rejects it (403) unless the
      verified caller uid is one of the two ids in `chatId`, sets
      `senderId` to that uid itself, and trims text (300) / name (80) to
      stay under FCM's 4 KB data limit.
    - `POST /create-video` — kept for potential future use (mints a
      presigned Bunny TUS signature) but **not currently called** by the app.
    - `POST /upload-video` — the video upload proxy described above
      (length-checked, cleans up failed slots).
    - `GET /delete-account` (3 Oct 2026, confirmed) — public, no sign-in,
      English-only page required by Google Play ("delete your account
      without the app"): how to delete in the app (Profile → ⋮ → Delete
      account), a request form (email\*, Fly name, reason, "I understand"
      checkbox), and what is deleted / what may remain. Fly gradient,
      glass cards, waving 🐦, confetti on success. The HTML lives in the
      Worker as `DELETE_ACCOUNT_PAGE_HTML` (a `String.raw` template, so
      keep it free of backticks and `${`). Live URL:
      `https://livekit-token-worker.chakaboycom.workers.dev/delete-account`
      — this is the link for Play Console → App content → Data safety
      (data deletion questions). The page promises deletion within 30
      days and backups cleared within 90 days.
    - `POST /delete-request` — the page's form, no sign-in. Only STORES a
      request (`deletionRequests/{uuid}`, status `pending`) via the
      service account; never deletes anything. Bot guards: hidden
      `website` honeypot and a <2.5s-on-page check both "succeed"
      silently without storing; body ≤4 KB; email validated.
    - `POST /bunny-webhook?token=...` — called by Bunny, not the app;
      authenticated by the `BUNNY_WEBHOOK_TOKEN` secret in the URL; sets
      `videoReady` (see "Video ready" flow above).
    - `POST /upload-image` — plain pass-through PUT to Bunny Storage, used
      for profile photos, story images and chat photos/voice notes (see the profile/story note
      further down in this section).
  - Confirm the current token-fetch code path in `video_call_screen.dart`
    (constant `kTokenServerUrl`, a plain top-level `const` imported with a
    `show` clause by other files; auth headers come from
    `worker_auth.dart`) before changing call logic.
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
    2. **Caller hangs up before the callee answers — FIXED for app
       open/backgrounded (27 Sep 2026, confirmed on two phones).**
       `_listenForIncomingCalls` in `main_navigation_screen.dart` now
       handles Firestore's `DocumentChangeType.removed` (fires when the
       call doc's `status` leaves `'ringing'`) via
       `_handleCallLeftRinging()`. The doc inside a `removed` change can
       still hold the OLD data, so it re-reads the doc with a plain
       `get()` and only dismisses when the status is `'ended'` (or the doc
       is gone) — never on `'accepted'`, which would kill the call being
       answered. It dismisses with `CallKitService.dismissIncomingCall()`
       (`FlutterCallkitIncoming.endCall(id)` only — deliberately **not**
       `endAllCalls()`, which would also end another active call). The
       caller's 45s no-answer timer also writes `'ended'`, so both phones
       now stop together. Gotcha: `GetOptions(source: Source.server)`
       doesn't compile in that file — `audioplayers` also exports a
       `Source` class (ambiguous import).
       **App fully swiped away — also FIXED (28 Sep 2026, confirmed on
       two phones):** when the caller ends a call the other side never
       joined (`!fromIncomingCall && !_remoteJoined` in
       `video_call_screen.dart`'s `_endCall()` — covers hanging up and the
       45s timer), it also calls `sendCallCancelledPush(roomName)`
       (`call_push_service.dart`; reads `calleeId` from `calls/{roomName}`,
       then their `fcmToken`) → Worker `/call-push` with
       `type: 'call_cancelled'` → high-priority data message →
       `firebaseMessagingBackgroundHandler` in `main.dart` calls
       `dismissIncomingCall()` (no Firebase init needed for that). If the
       app is still running, both the Firestore path and the push fire;
       dismissing twice is harmless. Best-effort: a late push or an OEM
       battery restriction falls back to the 45s ring duration.
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

(Checked against `pubspec.yaml` on 27 Sep 2026.)

firebase_core, firebase_auth, firebase_storage, cloud_firestore,
firebase_messaging, shared_preferences, http, connectivity_plus,
image_picker, video_player, flutter_compress, video_trimmer_2,
cached_network_image, flutter_cache_manager, video_editor, share_plus,
flutter_local_notifications, livekit_client, flutter_webrtc, audioplayers,
path_provider, flutter_sound, permission_handler, wakelock_plus, camera,
google_mlkit_face_mesh_detection, google_mlkit_translation,
google_mlkit_language_id, device_info_plus, android_intent_plus,
flutter_callkit_incoming, proximity_sensor, uuid, url_launcher, gal,
cupertino_icons.

- `google_mlkit_translation` / `google_mlkit_language_id` are pinned to
  **0.13.x** on purpose: 0.14 needs `google_mlkit_commons ^0.12`, which
  conflicts with `google_mlkit_face_mesh_detection ^0.4.2` (needs commons
  ^0.11). Don't bump one ML Kit package alone.
- `connectivity_plus` must stay on **^7.x** (`livekit_client` >= 2.6
  requires it).
- `wakelock_plus` keeps the screen on while watching videos, in calls and
  on live screens.
- No `bunny_dart`, `tus_client`, `tusc`, or `cross_file` — all were tried
  and removed during the upload-mechanism debugging described above; the
  final Bunny upload path only needs the `http` package.
- No FFmpeg package on purpose (GPL licensing risk for a closed-source
  commercial app) — see the Trim note in §3.

### Build toolchain (bleeding-edge but working)

AGP 8.11.1 (upgraded from 8.9.1 on 1 Oct 2026, confirmed — only the
`com.android.application` version in `android/settings.gradle.kts`
changed; Gradle 9.1.0 already met AGP 8.11's minimum of 8.13), Gradle
9.1.0, JDK 25, compileSdk 36.
⚠️ **Don't run `flutter upgrade` casually.** Builds warn that 11 plugins
still apply the Kotlin Gradle Plugin (camera_android_camerax,
device_info_plus, flutter_callkit_incoming, flutter_compress,
flutter_webrtc, livekit_client, package_info_plus, proximity_sensor,
share_plus, video_trimmer_2, wakelock_plus) and that "future versions of
Flutter will fail to build" with them. Upgrade Flutter only after those
plugins ship Built-in Kotlin versions (or be ready to roll back).
Other build warnings (`source value 8 is obsolete`, deprecated API notes,
`restricted method in java.lang.System`) come from plugins/Gradle and are
harmless.
⚠️ Never edit gradle/dart/XML files with Notepad or PowerShell here-strings
(they inject a BOM / strip characters). Use VS Code only.
`.gitignore` ignores `/build/` and (since Sep 2026) `/android/build/`. Git on
Ko's Windows machine prints harmless "LF will be replaced by CRLF" warnings
for files the assistant writes.
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
  `firebaseMessagingBackgroundHandler` for incoming-call and
  `call_cancelled` push data messages,
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
- `block_service.dart` **(30 Sep 2026, confirmed on two phones)** —
  app-wide two-way blocking, like Facebook/Messenger. `block(uid)` writes
  in ONE batch `users/{me}/blocked/{them}` + a mirror
  `users/{them}/blockedBy/{me}` (and removes my follow of them);
  `unblock(uid)` deletes both. `BlockService.instance.start()` (called in
  `main_navigation_screen.dart` initState, follows auth changes) listens to
  both lists and exposes `blockedByMe`, `blockedMe` and `hidden` (union)
  as ValueNotifiers + `isHidden(uid)` (`hidden` only notifies when the set
  really changes — `setEquals`, 1 Oct 2026); old blocks get their mirror
  back-filled on start. Everything reads `hidden`, so BOTH people vanish
  for each other: Home feed + Reels + comments/replies (`home_screen.dart`,
  listener instead of their old per-screen `blocked` streams), Stories bar
  (and so the viewer), chat list + online strip, search/discover,
  notifications, public profile (`_BlockedProfileView`: blocker sees "You
  blocked this account" + Unblock, the blocked person just "This account
  isn't available"). A chat thread with a blocked person replaces the input
  with a banner (Unblock for the blocker) and hides the call buttons.
  **Rules enforce it too:** `blockedInRoom(roomId)` (uses `otherInRoom`)
  denies new `chats/*/messages` and any call doc going to 'ringing'
  between blocked people; `blockedBy` is readable only by its owner,
  creatable/deletable only by the blocker. Follow isn't restored on unblock
  (same as Facebook).
- `chat_delivery_service.dart` **(1 Oct 2026, confirmed on two phones)** —
  Messenger-style "Delivered". `ChatDeliveryService.instance.start()`
  (called next to `BlockService.instance.start()` in
  `main_navigation_screen.dart`, follows auth changes) listens to my
  `chats` (participants array-contains me); when a chat's
  `lastSenderId` is the other person and `lastMessageAt` is new, it
  fetches their messages with `seen == false` (two equality filters, no
  composite index) and sets `delivered: true`. Only messages actually on
  this phone get marked. `ChatDeliveryService.markChatDelivered(chatId)`
  (static, waits up to 5s for the restored auth user) is what the
  background push handler uses when Fly is closed.
- **Chat message push (1 Oct 2026, confirmed on two phones)** — like the
  call push. Sender: `chat_screen.dart`'s `_notifyOther()` (new message
  AND reactions) calls `sendChatPush()` (`call_push_service.dart`) →
  Worker `/call-push` `type: 'chat_message'` → FCM data message →
  receiver's `firebaseMessagingBackgroundHandler` (`main.dart`, runs only
  while Fly isn't in the foreground, including fully closed) shows the
  notification and marks the chat delivered. Notifications use one id
  per conversation (`NotificationService.chatNotificationId(chatId)`),
  so a newer message replaces the older one; payload
  `{userId,name,photo}` → tap sets `NotificationService.pendingChat` (also
  from `getNotificationAppLaunchDetails` on a cold start) →
  `MainNavigationScreen._openPendingChat` opens `ChatThreadScreen`.
  `MainNavigationScreen._listenForNewMessages` (the in-app alert) now:
  alerts only for a NEW `lastMessageAt` (a call's `lastCallAt` update
  used to re-alert the old message), also on brand-new chat docs, skips
  blocked people and the chat on screen (`currentOpenChatId`, a
  top-level var in `chat_screen.dart`), dings only in the foreground,
  and in the background waits 4s and shows its own notification only if
  the push's isn't in the tray (`isChatNotificationShowing`) - no double
  alerts. Opening a chat cancels its notification. Story replies
  (`story_screen.dart`'s `_sendReply`) send the same push too (1 Oct 2026,
  confirmed) and are created with `delivered: false`. vivo phones may need
  Settings → Battery → Fly → allow background activity.
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
- `screens/signup_screen.dart` — account creation, with a **date-of-birth
  picker and a 13+ age gate** (signup is blocked under 13 — needed for Play
  Store, given chat, live streaming and gifting; checked in the app only,
  the birth date is not saved to Firestore). Has a show/hide password
  eye icon like the login screen.
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
  - Tabs (checked 27 Sep 2026): **Home, Chat, Upload, Profile, Live**.
    Home and Chat are swipeable via a `PageView` (both stay mounted
    simultaneously — needed so the swipe feels responsive), with a one-time
    swipe hint (`sawSwipeHint`). Upload, Profile and Live are tap-only;
    Live opens a "Go Live" dialog → `GoLiveScreen`. The old standalone
    Shorts/Reels tab was **removed** — videos only live on Home. **Not**
    `IndexedStack` (that was deliberately removed previously because it kept
    every tab's videos alive/competing for playback). Gifting and the
    wallet are not tabs (wallet opens from the Profile AppBar).
  - Draggable circular **"orbit" menu button** (glass look, cyan glow,
    orbit-ring + sparkle icon that swaps to an **X** when open) that can be
    placed anywhere on screen, including over the video. It toggles the
    small tab pill fixed at the very bottom (horizontally scrollable). The
    active tab has **no background box** — a small satellite dot orbits the
    active icon instead (deliberately, so less of the video is covered).
  - **Back button:** from any tab, the phone's back button returns to Home
    first; on Home, pressing back again within 2 seconds exits
    (`PopScope`).
  - `_TopBars`: stacks the network-status banner above the minimized-call bar
    at the top of the screen (see `network_service.dart` above).
  - In-app "ding" sound on new messages; incoming-call listening/UI (see the
    call bugs in §3 — `_handleCallLeftRinging()` here stops the callee's
    ringing screen when the caller hangs up first).
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
- `screens/settings_screen.dart` — small settings hub (Blocked accounts and,
  since Sep 2026, "Copyright & Sounds"; a natural place to add future settings instead of piling
  onto `profile_screen.dart`'s 3-dot menu). Opened via a gear icon in
  `profile_screen.dart`'s AppBar.
- `screens/blocked_users_screen.dart` — lists everyone the current user has
  blocked (reads `users/{myId}/blocked`), each with an **Unblock** button.
  The actual "Block user" action lives in `public_profile_screen.dart` (a
  profile's 3-dot menu) and in a similar spot inside `home_screen.dart` (a
  video's "More" menu) — both write into the same
  `users/{myId}/blocked/{blockedUserId}` subcollection, which
  `home_screen.dart`'s feed queries already read to filter out blocked users'
  posts. **(30 Sep 2026)** Blocking is now two-way and complete — see
  `block_service.dart` below; unblocking here goes through
  `BlockService.unblock`.
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
    viewer, a shorts-shelf, respectively). **(Sep 2026)**
    `SavedVideosFeedScreen` — the same kind of viewer for the Saved grid;
    takes the already-loaded post docs + `initialIndex` instead of running
    its own query.
  - `_toggleSave()` writes/deletes **two docs in one batch**:
    `posts/{postId}/saves/{uid}` (the count on the video) and
    `users/{uid}/saved/{postId}` (the private Saved list).
  - `_VideoPostItem` — the shared per-video Stack: Smart-Fit video sizing
    (cover vs. letterbox based on aspect-ratio mismatch), caption panel,
    OwnerInfo, Like/Comment/Share/Save/More action dock (or a compact
    horizontal row for reposts), sound/view-count row, the "Fly Frame"
    cinematic top/bottom gradient bands, reaction picker, flying-emoji
    animation, report/block entry point, hashtag handling, translation.
    **Playback lifecycle (29 Sep 2026, confirmed on Ko's phone):** - Pause/resume tracks two separate "away" reasons, `_routeCovered`
    (didPushNext/didPopNext) and `_appBackgrounded` (lifecycle). Only the
    FIRST away-reason records `_wasPlayingBeforeLeaving`. Bug it fixed:
    the phone's Home button fires inactive → hidden → paused in a row;
    the 2nd event overwrote the flag with false, so returning via
    Recents left the Home video black and silent. - Returning to a video that was **paused on purpose**: `seekTo(same
position)` — Android drops the video surface in the background and a
    paused player never draws a new frame by itself (it came back black). - `_FirstFrameCover`: thumbnail until the first frame shows, spinner
    while (re)buffering — a ValueListenableBuilder on the controller, so
    only it rebuilds. - Stall watchdog (`_startStallWatchdog`, 8s): playback requested but
    the position never moved → `_reloadAt(position, autoPlay:)` rebuilds
    the controller at the same spot (max 2 tries, then "Couldn't load").
    Also used after resuming. A dead player on resume is rebuilt too. - The layout rebuilds when `controller.value.size` changes (HLS can
    report 0x0 at initialize and the real size a moment later).
    **Comments sheet (`_CommentsSheet`, 28 Sep 2026, confirmed on phones):** - **Instant send:** only the on-device `ContentFilter` runs before
    posting; the comment is written at once with a locally generated doc
    id (input clears immediately, profile is pre-fetched in initState).
    The moderation-server check (`fly-moderation.onrender.com`, free
    Render — up to ~50s cold start, which is what made sending feel
    slow) now runs in the background **after** posting
    (`_moderateAfterPost`); if flagged, the comment is deleted again and
    the author told. The owner's notification is only sent after the
    check passes. Don't move moderation back in front of the write. - The comments stream and each tile's replies stream are built once
    (initState / `late final`), and tiles are keyed by doc id — the old
    in-`build()` stream flashed a spinner on every send. - **Long-press menu** (`_showCommentOptions`, comments and replies):
    author → Delete; video owner → Hide/Unhide + Delete (others'
    comments); anyone else → Report. Delete has a confirm dialog. - **Hide:** `hidden: true` (+ `hiddenAt`) on the comment/reply, set only
    by the video owner. `_isCommentVisibleTo()` shows it to the owner
    (dimmed, "Hidden" tag) and to its author (normally, like Facebook —
    not told), and filters it out for everyone else. Comment counts use
    `_visibleCommentCount()` (hidden not counted). It's a client-side
    filter — the doc is still readable via the API.
    **Action dock look (28 Sep 2026, approved by Ko):** Facebook-Reels
    style — Comment (`_FlyCommentIcon`) is a white outline oval speech
    bubble with **three white dots inside** (Ko's must-keep detail), Share
    (`_FlySwooshShareIcon`, name kept from the old paper-plane) is a white
    outline forward arrow; both 28px with a soft black shadow, no gradient.
    Compact spacing: 46x40 tap boxes, count 2px under each icon
    (`_countLabel`), 6px between buttons. 12px gaps + 46px-tall boxes were
    tried and rejected as too spread out.
    Accepts `onTapToExpand` (only Home passes this — its absence is how the
    code tells "already fullscreen" contexts apart from Home) and `isActive`.
    `_initializeVideo()` here is also where the network-aware timeout/retry
    UI ("Couldn't load - tap to retry", `_hasError` flag) and the
    Cloudinary-only disk-cache logic (see `video_disk_cache.dart` above)
    live — both apply per-instance, so the _same_ video can hit disk cache
    in one `_VideoPostItem` instance (e.g. Home) and not another (e.g.
    `FullScreenVideoScreen`) depending on timing; this is expected, not a
    bug, for Cloudinary posts, and moot for Bunny posts (cache skipped
    entirely). **(Sep 2026)** `_initializeVideo()` first checks
    `LocalVideoCache` (uploader's own fresh video → play the local file),
    and on a failed load of a Bunny post under 30 minutes old shows
    "Processing video..." with a 5s auto-retry (`_isProcessing`,
    `_processingRetryTimer`, cancelled in `dispose()`) instead of the error.
    The two Home feed streams drop not-yet-ready videos via
    `isVideoVisibleTo()`.
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
  full-screen vertical / ▶️ Video = landscape), then pick + trim + effects +
  caption + upload to **Bunny Stream** (see §3 for the exact mechanism and
  the Borrowed-Sound limitation), writing `videoType` ('short'/'long') to
  the post. Speed/color-filter/text-overlays are picked via
  `video_effects_screen.dart`/`text_overlay_style.dart` and saved as plain
  Firestore fields (`videoSpeed`/`filterType`/`textOverlays`) - they are
  **not** baked into the video file itself; `home_screen.dart`'s
  `_VideoPostItem` re-applies them live at watch time (a `ColorFiltered`
  wrapper + positioned overlay widgets + `setPlaybackSpeed`), and
  `story_screen.dart`'s viewer does the same for story videos. The video is
  physically trimmed to the selected range (see §3's Trim note) and
  client-side compressed, then uploaded via `video_upload_service.dart`
  (see §3 for compression, size-based timeout, 95 MB cap). Network-aware:
  fails fast with a friendly message if offline before starting, does one
  quiet auto-retry (3s delay) on a network error
  (`VideoUploadException.isNetworkIssue`) before giving up, and relabels the
  button "Retry Upload" after a failure — the picked video/caption state is
  preserved either way. Writes `bunnyVideoId`/`videoReady: false`, registers
  the local file with `LocalVideoCache`, and shows the "Let others use my
  sound" rights checkbox (only when no borrowed sound is picked).
- `screens/trim_editor_screen.dart` — video trim UI (video_editor). Every
  picked video (camera or gallery) is unconditionally routed through here.
  Takes an optional `maxDurationSeconds` (default 90; stories pass 15 - see
  §3) that caps how large a range can be selected.
- `screens/video_effects_screen.dart` — speed/color-filter/text-overlay
  picker, used by both `upload_screen.dart` and (for videos only)
  `story_screen.dart`. Returns a `VideoEffectsResult` (plus `music` and
  `shareSound` when opened with `enableMusic: true`, which only stories do).
  Also home of the **`TextOverlayData`** model, `kVideoFilterMatrices`, the
  Klipy sticker search, and two top-level pickers shared with
  `photo_effects_screen.dart`: `showTextOverlayDialog()` and
  `showOverlayStickerPicker()`.
- `screens/photo_effects_screen.dart` **(Sep 2026)** — photo-story editor:
  filter strip, text overlays, stickers, music. Returns
  `PhotoEffectsResult {filterType, textOverlays, aspectRatio, music}`.
- `screens/story_music.dart` **(Sep 2026)** — `StoryMusicSelection`,
  `pickStoryMusic()` (library + 15s window), `StoryMusicPlayer` (loops one
  window of a sound; load tokens stop a superseded load from playing), and
  the "♪ Title · Owner" `StoryMusicChip`.
- `screens/sound_moderation.dart` **(Sep 2026)** — copyright safeguards:
  rights checkbox, report sheet, auto-hide threshold, owner remove,
  `isSoundHidden`/`isSoundPlayable`, and `CopyrightPolicyScreen` (§3).
- `screens/video_upload_service.dart` **(Sep 2026)** — shared video
  compress + upload (`compressVideoForUpload`, `uploadVideoToBunny`,
  `VideoUploadException`) and the readiness helpers
  (`newVideoReadinessFields`, `syncVideoReady`, `isVideoVisibleTo`).
- `screens/local_video_cache.dart` **(Sep 2026)** — in-memory videoUrl →
  local file map for instant playback of the uploader's own new video.
- `screens/text_overlay_style.dart` — overlay style presets and
  `AnimatedOverlayText`, the actual widget that renders one overlay
  (background/shadow/neon/impact/gradient styles, looping entrance/exit
  animations) - shared by the upload preview, `home_screen.dart`'s feed
  playback, and `story_screen.dart`'s story viewer.
- `screens/content_filter.dart` — content/keyword filtering helper.
- `screens/profile_screen.dart` — own profile: avatar, name, Edit Profile,
  stats (Posts / Followers / Following), video grid (tap = open viewer,
  long-press = delete own post), TikTok-style view count on each thumbnail.
  AppBar has Wallet, **Saved** (bookmark icon), **Logout** (behind a
  confirmation dialog), a
  **Settings** gear icon (→ `settings_screen.dart`), and a 3-dot menu
  (**Delete account** — has a confirmation dialog + password
  re-authentication). Also contains `EditProfileScreen` (edit name + profile
  photo via Camera or Gallery → uploads to **Bunny Storage**, see §3).
  Also has two profile extras:
  - **Sky Note** — a short (60-char) thought in a drifting cloud-shaped
    bubble near the profile photo, auto-expiring after 24 hours (fields
    `skyNoteText`, `skyNoteCreatedAt` on the user doc; also shown on
    `public_profile_screen.dart`). A deliberately different take on
    Facebook's permanent "feeling" tag.
  - **Fly Memories** — an "on this day" recap card of the user's own past
    posts.
- `screens/saved_videos_screen.dart` **(Sep 2026)** — "Saved": the
  signed-in user's bookmarked videos, newest first, as a 3-column grid.
  Streams `users/{me}/saved` (ordered by `savedAt`), then fetches the real
  post docs in `whereIn` chunks of 10 (so deleted posts drop out and
  captions/effects are current). Tap → `SavedVideosFeedScreen`; long-press
  → confirm → unsave (deletes both docs). Opened from the bookmark icon in
  `profile_screen.dart`'s AppBar. Saves made before this build aren't in
  the list (only `posts/*/saves` had them) — re-save to show them.
- `screens/public_profile_screen.dart` — another user's profile: photo
  (with the sparkle-star online badge), name, Follow / Message buttons,
  stats, video grid, and a 3-dot menu with **Block user**
  (`_confirmBlockUser`, writes `users/{myId}/blocked/{blockedUserId}`).
- `screens/story_screen.dart` — Stories. Facebook-style story cards bar,
  add-story flow (photo → Bunny Storage, video → Bunny Stream with a 15s
  trim cap and the same speed/filter/text-overlay effects step as feed
  posts - see §3) → 14-hour expiry, full-screen viewer with segmented
  progress bars + auto-advance (applying those same effects live - see §3),
  a delete button for the story's own owner, floating reactions that rise
  up, and a "See who reacted" list for the story owner. **(Sep 2026)**
  Photo stories go through `PhotoEffectsScreen`; both kinds can have music;
  video stories use `video_upload_service.dart` (now compressed), are
  hidden from others until `videoReady`, and play from the local file for
  their poster.
  **Stories bar redesign (29 Sep 2026, approved by Ko — "like Facebook but
  cooler"):** `StoriesBar` (now a StatefulWidget, stream built once) shows
  tall rounded **cards** (104×166, `_kStoryCard*` consts) instead of the
  old round avatars. Each `_StoryCard` uses the person's LATEST story as
  its background (`_storyPreviewUrl`: the photo, or the video's Bunny
  thumbnail — never run a Bunny _image_ URL through `cloudinaryThumbUrl`),
  keeps Fly's segmented gradient ring on the corner avatar (one segment per
  story), a glass age chip ("5m"/"3h", `_storyAgeLabel`), ▶/♪ badges for
  video/music stories, a pink→purple gradient frame with glow
  (`_StoryCardFrame`) and a press "squish" (`_PressableScale`).
  `_CreateStoryCard` is Facebook-style: own photo on top, dark "Create
  story" panel below, gradient "+" on the seam. My own stories come right
  after it. Bar height stays 182 so the Home header doesn't move.
  **Story viewer redesign (30 Sep 2026, confirmed on phones):**
  `StoryViewerScreen(groups:, initialGroup:)` now takes ALL people's
  stories (one list per person, same order as the bar) in a horizontal
  `PageView` with a **3D cube turn** between people (AnimatedBuilder on the
  PageController, rotateY around the shared edge + darkening). Each page
  is a `_UserStoriesPage`; only the page on screen (`isActive`) loads and
  plays — neighbours show a still preview (`_videoPlaceholder`), and a
  page that's swiped back to after finishing replays its last story.
  When a person's stories end it moves to the next person
  (`onFinished`), tapping left on their first story goes to the previous
  person (`onBeforeFirst`). Press-and-hold pauses and fades all UI out;
  swipe down closes. Header shows name + `_storyAgeLabel`. Non-owners get
  the emoji row + a **"Send message to NAME..." reply box** (pauses while
  typing; Scaffold `resizeToAvoidBottomInset: false`, the bar lifts by
  viewInsets) — `_sendReply` writes a normal `chats/{chatId}/messages`
  text message (same fields/chat-list update/notification as
  chat_screen.dart) plus `storyId` + `storyThumb`; `chat_screen.dart`
  shows such messages with a small story preview ("Replied to your
  story"). Owners get "See who reacted" + delete instead. No rules change
  (chat rules already allow it).
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
  - **Streams are built once** (`_usersStream`, `_chatsStream`, and in the
    thread `_messagesStream`, `_activityStream`, all in `initState`) — never
    inside `build()` (1 Oct 2026). The spinner only shows while there's no
    data yet; an error shows "Couldn't load chats/messages" instead.
  - Photos and voice notes upload to Bunny Storage (see §3, 1 Oct 2026).
- `ChatThreadScreen` status + reactions **(1 Oct 2026, confirmed)**:
  - Messages are created with `seen: false, delivered: false`; opening the
    chat sets `seen` + `delivered`. `_DeliveryStatus` shows under my
    **newest** message only (plus any still pending): Sending... (hollow
    circle, `hasPendingWrites`) → Sent (outlined tick) → Delivered (filled
    blue tick) → Seen (their tiny photo).
  - Long-press any message → `_showMessageActions`: `_ReactionBar`
    (👍 ❤️ 😆 😮 😢 😡, `_kMessageReactions`, hidden when blocked) + Copy
    (text) / Unsend (mine, the old `_deleteMessage`). Stored as
    `reactions: {<uid>: emoji}` via `update({'reactions.<uid>': ...})`;
    picking the same one again removes it. `_ReactedBubble` draws the pill
    on the bubble corner (count when >1); tapping it opens
    `_showReactionDetails` (tap my row to remove). Reacting to their
    message adds a "Reacted 😆 to your message" notification
    (`_notifyOther`, shared with `_afterSend`).
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
  mid-call, and a shared drawing overlay. `kTokenServerUrl` (the Worker
  URL) is defined here as a top-level `const` and imported with a `show`
  clause elsewhere; the old `kAppSharedSecret` was removed in Sep 2026 (see
  `worker_auth.dart`). See §3 for the two known, not-yet-fixed call bugs.
- `screens/worker_auth.dart` **(Sep 2026)** — `workerAuthHeaders()`: the
  signed-in user's Firebase ID token as an `Authorization` header, used by
  every Worker call (calls, live, call push, video/image uploads).
- `screens/live_screen.dart` — live streaming (LiveKit broadcaster/viewer,
  `GoLiveScreen`): live comments, tap/long-press quick reactions
  (❤️😂😮👏🔥) with flying animation, viewer count, gift button + flying
  gift banners + coin badge. Host-only **Reaction Pulse** bar
  (`ReactionPulseBar`, a small bar chart of recent reaction activity).
  **Timeline Highlights**: in `_endLive()`, before marking the stream
  ended, it scans the reaction history for the 30-second window with the
  most reactions and shows the host a "biggest moment" recap. Ended lives
  are kept (not deleted) as a grayed "ENDED" recap card with the comment
  thread — there is no video replay (that would need paid LiveKit Egress +
  a backend).
- `screens/gifting.dart` — **cosmetic-only** virtual gifting: `GiftItem`
  catalog, `CoinService`, `GiftPickerSheet`, `CoinBalanceBadge`,
  `TopSupportersSheet`, flying gift animation. Coins are earned free
  (daily login, follow, share/repost, watching to the end); **no real-money
  purchase and no cash-out** — deliberately deferred until legal advice.
- `screens/wallet_screen.dart` — coin balance, "how to earn" list, gifts
  received (`liveStreams/{uid}/gifts`), and a disabled "Withdraw to cash"
  placeholder. Opened from the 🪙 icon in `profile_screen.dart`'s AppBar.
- `screens/sound_screen.dart`, `screens/sounds_library_screen.dart`,
  `screens/sound_sync_sheet.dart` — a sound's page (videos using it, "Use
  this sound", report/remove), the browsable/searchable library (hides
  removed/over-reported sounds), and the "choose part of the song" sheet.
- `screens/search_screen.dart`, `screens/translation_service.dart` — search
  and caption translation.
- `screens/face_filter_camera_screen.dart` — AR face-filter camera capture.
- `screens/notifications_screen.dart` — notifications list. Rows are
  tappable (1 Oct 2026, confirmed): a message opens that chat, a follow
  opens the follower's profile, a comment/reaction (they carry `postId`)
  opens `PostFromNotificationScreen` (home_screen.dart, fade+scale route)
  (`_openNotification`).
- `PostFromNotificationScreen` (in `home_screen.dart`, **1 Oct 2026,
  confirmed**) — reads `posts/{postId}` once (Future in a `late final`);
  while loading shows the notifier's photo in a Fly-gradient ring + their
  comment/reaction (not a bare spinner); deleted/hidden/not-ready post →
  "This video is no longer available". Plays one `_VideoPostItem` with
  new params: `openCommentsOnStart` + `highlightCommentFrom/Text`
  (comment) or `burstEmojiOnStart` (reaction: `_spawnReactionBurst`, 9
  flying emojis + light haptic), fired 700ms after mount. A glass
  (blurred) banner "X commented: …" / "X reacted 😆 …" slides in and hides
  after ~4s. `_CommentsSheet` got `highlightUserId/highlightText`: the
  matching comment (newest from that user, same text if possible) is
  wrapped in `_CommentSpotlight` — scrolls into view and a rotating
  pink→purple→blue sweep-gradient border glows ~3.5s, then fades.
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

- **Cloudflare Worker** — **runs** in the Cloudflare dashboard (Workers &
  Pages → `livekit-token-worker` → Edit code → Deploy), but since Sep 2026 a
  copy of the deployed code is kept in this repo at
  **`cloudflare/livekit_token_worker.js`** (fetch it via the raw URL). It
  contains no secrets — all keys come from `env.*` Worker secrets:
  `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL`,
  `APP_SHARED_SECRET` (legacy; delete after all phones update),
  `FIREBASE_PROJECT_ID` (also used to verify ID tokens), `FIREBASE_CLIENT_EMAIL`,
  `FIREBASE_PRIVATE_KEY_B64`, `BUNNY_LIBRARY_ID`, `BUNNY_API_KEY`,
  `BUNNY_STORAGE_ZONE`, `BUNNY_STORAGE_PASSWORD`, `BUNNY_WEBHOOK_TOKEN`.
  Deploying is manual: give Ko the full file to paste over everything and
  press Deploy, then have him commit the same file here so the copy doesn't
  drift. If in doubt whether the repo copy matches what's deployed, ask him.
- **`firestore.rules`** (repo root) — see §3; published by hand in the
  Firebase Console.
- **Bunny.net Stream dashboard** — Library ID 756617,
  `vz-a6ab9346-730.b-cdn.net`. Per-video status and **size** are visible
  here: "Processing" with **0 Bytes / 00:00:00** means the upload never
  arrived (it will never finish — delete it), whereas a real size means it's
  just still encoding. Webhook URL is configured under the library settings.
  Incidents: https://status.bunny.net.

_(If a path differs slightly, list the repo tree via the GitHub API or fetch the
directory to confirm before editing. Given how large `home_screen.dart` is,
always grep/search within it for a class name before assuming a "missing"
screen needs to be created from scratch — it may already exist there.)_

---

## 5. Firestore data model

- `users/{uid}`: { displayName, photoUrl, email, fcmToken, isOnline,
  lastActive, hasSeenOnboarding, sawSwipeHint, skyNoteText,
  skyNoteCreatedAt } (+ coin fields, see Gifting/live below)
  - `users/{uid}/followers/{id}`, `users/{uid}/following/{id}`: { createdAt }
  - `users/{uid}/notifications/{id}`: { type, text, fromId, fromName, fromPhoto,
    postId?, seen, createdAt }
  - `users/{uid}/saved/{postId}` (Sep 2026): { postId, ownerId, videoUrl,
    savedAt } — private Saved list; rules: owner-only read/write.
  - `users/{uid}/blocked/{blockedUserId}`: { createdAt } — who this user has
    blocked (listed/unblocked in `blocked_users_screen.dart`).
  - `users/{uid}/blockedBy/{blockerId}`: { createdAt } (30 Sep 2026) — mirror
    written by the blocker so the blocked person's app hides them too; see
    `block_service.dart`.
- `posts/{id}`: { userId, userEmail, videoUrl (Bunny HLS playlist for new
  posts, Cloudinary mp4 for old ones — see §3), bunnyVideoId, videoReady,
  videoFailed (Sep 2026, see §3 "Video ready"), soundId ('' when the audio
  wasn't shared), soundTitle, soundOwnerName, hashtags, replyToPostId/
  replyToOwnerId/replyToOwnerName (video replies), caption,
  reactions:{uid→type}, videoType('short'|'long'), createdAt, videoSpeed,
  filterType, blurBackground, textOverlays, effectsBaked (checked by
  `home_screen.dart`'s playback code, but no current upload path actually
  writes it true - effects are always applied live, never pre-baked; this
  flag looks like unused/future-proofing groundwork), plus repost fields
  (repostByName, repostByUserId, repostByPhoto, repostNote) when the item is
  a repost }
  - `posts/{id}/comments/{id}` (+ `.../replies/{id}`): { userId, displayName,
    photoUrl, text, reactions, createdAt, hidden?, hiddenAt? } — rules
    (`isPostOwner()`): author can delete; video owner can delete and may
    change only `hidden`/`hiddenAt`; the author can't touch those two.
  - `posts/{id}/views/{uid}`, `posts/{id}/saves/{uid}`, `posts/{id}/shares/{uid}`
    — one doc per user, used for counting.
- `stories/{id}`: { userId, userName, userPhoto, mediaUrl, mediaType('image'|
  'video'), createdAt, expiresAt, filterType, textOverlays; video only:
  videoSpeed, bunnyVideoId, videoReady, videoFailed; image only:
  imageAspectRatio; optional music: soundId, soundTitle, soundOwnerName,
  soundSourceUrl (absent = play the video's own audio), soundStartOffset }
  — filtered by `expiresAt > now` (14-hour lifetime); older stories may lack
  the Sep 2026 fields and still work.
  - `stories/{id}/reactions/{uid}`: { uid, type, userName, userPhoto, createdAt }
- `chats/{chatId}` (chatId = sorted `{uidA}_{uidB}`): { participants: [uidA,
  uidB], lastMessage, lastMessageAt, lastSenderId, lastCallAt }, plus
  `messages`/`activity` subcollections. A message: { senderId, type
  (text/image/audio), text/imageUrl/audioUrl, seen, delivered (1 Oct
  2026), reactions: {uid: emoji} (optional), createdAt, storyId/storyThumb
  (story replies) }. Rules: the receiver may change only `seen`/`delivered`,
  or their own `reactions.<uid>` (`onlyMyReaction`, not when blocked).
- `calls/{chatId}`: { callerId, callerName, callerPhoto, calleeId, roomName,
  status ('ringing'/...), createdAt } — call signaling. See §3 for the two
  known bugs around this doc's lifecycle (decline-while-killed,
  cancel-while-ringing).
- `sounds/{id}` (id = source post or story id): { ownerId, ownerName, title,
  sourceUrl, sourcePostId | sourceStoryId, usageCount, createdAt, and since
  Sep 2026: status ('active'|'approved'|'removed'), rightsConfirmed,
  rightsConfirmedAt, reportedBy: [uid] }. Older sounds lack the moderation
  fields and stay visible.
- `reports/{id}`: { targetType ('post'|'comment'|'user'|'sound'), targetId,
  targetOwnerId, parentPostId?, reporterId, reason, status, createdAt } —
  write-only from the app; reviewed in the Console.
- `videoStatus/{bunnyVideoGuid}` (Sep 2026): { ready, failed, status,
  updatedAt } — written only by the Worker's Bunny webhook.
- `deletionRequests/{uuid}` (3 Oct 2026): { email (lower-cased),
  username, reason, status ('pending' → Ko sets 'done'), createdAt } —
  written only by the Worker's `/delete-request`; no rule exists, so apps
  can't read or write it. Ko handles each one by hand in the Console:
  find the email in Authentication, delete that account + its data
  within 30 days, then mark the request `done`. (A small admin tool could
  automate this later if requests grow.)
- Gifting/live: `users/{uid}` also holds `coins`, `lastLoginRewardDate`,
  and daily reward counters; `users/{uid}/followRewards/{targetId}`,
  `users/{uid}/supporters/{senderId}`; `liveStreams/{hostUid}` with
  `viewers`, `reactions`, `comments`, `gifts` subcollections.

**Firestore security rules:** source of truth is `firestore.rules` in the
repo root (§3); published by hand in the Firebase Console. If you add a
collection/field the client reads or writes, update that file and remind Ko
to paste + Publish it.

---

## 6. Current features (already built)

Auth + auto-login (with a mascot-guided login screen, recent-account
quick-switch, and Forgot Password) · Flyla mascot onboarding tour for
first-time users · full-screen video feed (short vs landscape, Smart-Fit
sizing) · media controls + scrub slider + mute · reactions / comments /
replies (instant send, delete own, video owner can hide/delete) · follow ·
view / like / comment / share / save counts · profile
stats + video viewer + delete own posts · camera/gallery profile photo ·
private Saved videos screen (Profile → bookmark icon) ·
Sky Note (24h cloud-bubble thought) · Fly Memories (on-this-day card) ·
13+ age gate at signup · back button returns to Home, double-back exits ·
video filters/speed/text-overlays/stickers chosen at upload time and
applied live at playback (never baked into the file) · sounds library ·
face-filter camera · hashtags · reposts with a personal note · share sheet
(WhatsApp/Messenger/Facebook/Telegram/X/SMS/Email/copy link/download) ·
search/discover · Shorts shelf in the Home feed · content/keyword
filtering · on-device caption translation (ML Kit; no Burmese support) ·
report a post or a user · two-way block (both people vanish for each
other everywhere; no messages or calls - also enforced in Firestore rules),
unblock from Settings → Blocked accounts, the profile or the chat · chat (text/image/voice) + typing indicators + Sent/Delivered/Seen + message reactions, sorted
by most recent message/call activity, with an "online now" strip · video/voice
calls (LiveKit, via a Cloudflare Worker token server) + CallKit-style
incoming-call UI/push + caller ring-back tone + working speaker toggle +
shared drawing + Picture-in-Picture · online-presence system (sparkle-star
badge, Firestore heartbeat, a foreground service so it survives the screen
locking) · live streaming (with host Reaction Pulse bar and end-of-live
Timeline Highlights) · cosmetic-only gifting (free coins, no cash-out) ·
in-app wallet · notifications ·
**Stories** (FB-style cards, 14h expiry, floating reactions, "who reacted"
list, a 15s trim cap + video speed/filter/text-overlay effects on story
videos, delete-own-story) · **network resilience** (status banner, adaptive
quality, load-error retry, upload retry, offline-persisted chat/feed,
disk-cached recently-watched Cloudinary videos) · video hosting on **Bunny
Stream** (migrated from Cloudinary; auto-transcoding/adaptive HLS/
thumbnails) with a real, physical, client-side **video trim** · profile
photos and story images on **Bunny Storage** · **(Sep 2026)** photo-story
effects (filter/text/stickers) · story music from the sounds library ·
sound copyright safeguards (rights checkbox, report, auto-hide at 5
reports, policy page) · full Firestore security rules · reliable Bunny
uploads (no more 0-byte videos) · instant playback of your own new video +
others only see it once encoded (Bunny webhook).

### Known, deliberately-not-yet-fixed gaps

- No true real-time "offline the instant they lose connection" presence
  (Fly has no Realtime Database) — presence is heartbeat + a 60s staleness
  window, which is accurate enough for the UI's purposes but not instant.
- Borrowed Sound doesn't work for new (Bunny-hosted) video posts — see §3;
  it's blocked at upload time with a message. (Trim, listed here in an
  earlier version of this file, now actually works - see §3.)
- **Security (in progress, Sep 2026):** the Worker now verifies Firebase ID
  tokens and the app no longer contains `kAppSharedSecret` — but the old
  value is still in git history and still works until the
  `APP_SHARED_SECRET` Worker secret is **deleted** (do that once every
  test phone runs the new build). Still open: `/token` lets any signed-in
  user mint a token for any room name, and `/call-push` doesn't check that
  `callerId` equals the caller's uid.
- **Coins are granted client-side** (`gifting.dart`); the rules only cap each
  write at +10. Fine while coins are free, but must move server-side
  (Worker) before coins are ever sold or cashed out.
- **Delete account (fixed Sep 2026):** it used to query posts by a
  non-existent `ownerId` field, leaving a deleted user's videos behind; it
  now uses `userId`, also marks their `sounds` as `removed`, unfollows
  everyone (deleting their entry in each followed user's `followers`) and
  deletes their `liveStreams` doc. The flow is deliberately hard to hit
  by accident: type DELETE to unlock the button (checked via a
  `ValueListenableBuilder` on the controller, letters only, autocorrect
  off — some keyboards never unlocked it with `onChanged`), then re-enter
  the password (eye icon to show/hide it); "Forgot password?" there emails
  a reset link to the account's own address (so only the email owner can
  finish; test accounts with made-up emails never receive it). Still left behind (no server-side
  cleanup on the Spark plan): Bunny video/image files, comments/reactions
  on other people's posts, other users' reposts of their videos, and other
  users' `following` entries pointing at them.
- `videoReady` filtering covers the Home feed and Stories bar only; profile
  grids, search and sound pages can still list a video that's still
  encoding. Phones on an **older app build** ignore `videoReady` entirely and
  show everything (consider a force-update check before launch).
  `LocalVideoCache` is memory-only (lost on app restart).
- Not built yet: sound strike system, song recognition (AudD), direct MP3
  upload, resumable (TUS) uploads.
- Offline replay of a previously-watched video only works for old
  Cloudinary posts, not new Bunny (HLS) ones — see §3.
- If the callee's app is **fully swiped away** and they tap Decline, the
  caller isn't told (plugin limitation) and waits for the 45s timer — see
  §3. (Caller hang-up now stops the callee's ringing in every state,
  fixed 27–28 Sep 2026.)
- Cloudinary account (cloud_name `dwx402gy4`) is currently **disabled**
  (usage-quota exceeded) — all old Cloudinary-hosted content (videos,
  profile photos, stories) is unplayable/unloadable until Ko either
  upgrades the plan or enough of the rolling 30-day usage window rolls off.
  Profile photos, stories and chat photos/voice notes no longer depend on
  it going forward (now on Bunny), but old Cloudinary-hosted ones are still
  affected.
- **Some networks can't reach Firestore at all (seen 1 Oct 2026).** On one
  test phone's mobile data / hotspot, every Firestore screen (Home,
  Profile, Chat) spun forever while online and showed cached data only when
  offline; the same phone on another Wi-Fi worked. Firestore uses a
  long-lived gRPC connection that some carriers/hotspots break (Auth and
  Bunny still work, so it looks like "only Fly is broken"). Not a code bug —
  check the network (other Wi-Fi, VPN, Private DNS off, Google Play
  services updated) before debugging code for "spinner only on one phone".

### To-do list (Ko's next steps, most urgent first — updated 1 Oct 2026)

1. **Recharge Bunny before the trial ends (~3 Oct 2026).** Balance is $0;
   once the trial ends, uploads and playback can stop. Remind Ko early.
2. **Delete the `APP_SHARED_SECRET` Worker secret** in Cloudflare — only
   after _every_ test phone runs an APK built after commit `0fcaf1a`
   (Firebase ID token auth). Until then the leaked public secret still
   works. Tell Ko to read the dialog title before pressing Delete.
3. **Sound strike system** (repeat copyright offenders lose sound uploads).
4. **Delete old tiny videos** (uploaded before the orientation guard) and
   re-upload them.
5. Before publishing: put the `/delete-account` link in Play Console's
   Data safety form (done on the Worker side 3 Oct 2026), and add a
   Privacy Policy page if Fly doesn't have one (Play requires one; not
   confirmed yet whether it exists).
6. Optional / later: AudD song recognition, direct MP3 upload, resumable
   (TUS) uploads, force-update check (old builds ignore `videoReady`).
   (The login-screen show/hide password icon listed here before is already
   built — removed 27 Sep 2026.)

When one of these is done, remove it from this list in the same commit.

---

## 7. How to help (workflow) — the exact loop Ko expects

This is how every task ran in the Sep–Oct 2026 sessions, and Ko asked
(2 Oct 2026) that new chats keep doing it the same way.

**0. Start of a session.** Ko says "အလုပ်စလိုက်ရအောင် ဆရာ" (let's start).
Pull/clone the repo (`git pull`) so you edit the real latest code, then
offer a short **numbered menu** of next tasks (from the To-do list in §6 /
what's left from last time) and let him pick by number. Remind him of any
time-critical item (e.g. Bunny recharge) first.

**1. Understand before editing.** Read the real files (not this file's
summary). For bugs, ask for a screenshot or a short screen recording - Ko
sends them readily (videos: extract frames with ffmpeg and look). Ask
precise either/or questions ("app fully closed, or in the background?",
"new APK on BOTH phones?"). Don't guess-and-rebuild repeatedly: if a fix
didn't work, find the real cause first (e.g. 1 Oct 2026: a "chat spinner"
was actually one phone's network blocking Firestore - §6).

**2. Deployed-by-hand files.** Before editing `cloudflare/livekit_token_worker.js`
or `firestore.rules`, ask Ko whether he changed it in the dashboard since
the last commit. If he isn't sure: have him open Cloudflare → Edit code
(or Firebase → Rules), `Ctrl+A`/`Ctrl+C`, paste over the repo file in VS
Code, save, then `git diff --ignore-cr-at-eol --stat <file>` - no output
means identical. (He may also just paste the live code into chat.)

**3. Deliver code.** Full-file rewrites, sent as files (one file card per
changed file), English comments, Burmese reply. In the reply:

- what was wrong / what changed, in plain Burmese, with ✅/⚠️ markers;
- a small table **"file → where it goes"** (`fly\lib\`, `fly\lib\screens\`,
  `fly\cloudflare\`, `fly\android\`). Ko replaces files by dragging in
  File Explorer → Replace, or with `Copy-Item ... -Force`. Never Notepad
  for .dart/.gradle/.kts/.xml (BOM); VS Code paste is fine;
- Worker change → click-by-click Deploy steps (VS Code `Ctrl+A/C` → Cloudflare
  Edit code `Ctrl+A/V` → Deploy, don't touch Secrets); rules change →
  Firebase Console → Firestore Database → Rules → paste → Publish.

**4. Analyze first, one command at a time.** Give
`flutter analyze <only the changed files>` alone and ask for the output.
Ko asked "run both at once?" - the answer is no: analyze first, build only
after you've read it. When reading his output: say clearly "error မရှိပါဘူး ✅"
or point at the real error. Pre-existing, harmless noise to ignore:
`withOpacity` deprecations, `unnecessary_cast`, `use_build_context_synchronously`,
`_CommentBubbleIcon` unused, and the `test\widget_test.dart` "MyApp isn't a
class" error (old template test, doesn't affect the APK). Mention which
new infos came from your own code if any.

**5. Build + test checklist.** Then `flutter build apk --release`, install
on **both** test phones (A and B, vivo), and give a numbered A/B test
script with the exact expected result for each step ("B: close Fly from
Recents → A sends → B gets 🔔 …, A shows ●✓ Delivered"). Mention vivo
quirks (Settings → Battery → Fly → allow background activity) when push
or background work is involved.

**6. Ko confirms ("ဟုတ် အဆင်ပြေတယ် ဆရာ 🥰").** In that SAME reply, send the
updated **AI_CONTEXT.md as a full file** (his standing rule) plus commit
steps:

- First verify the files really landed in the project - Ko's browser
  sometimes saves straight into the project folder and sometimes not into
  Downloads at all. Use a unique-line check, e.g.
  `Select-String -Path AI_CONTEXT.md -Pattern "<a phrase only the new version has>"`
  (and the same for the Worker/rules). If missing, find it with
  `Get-ChildItem $env:USERPROFILE -Recurse -Filter "<name>*" | ...` and check
  name (`(1)`), size and LastWriteTime before copying. In Sep 2026 wrong
  files were committed twice by skipping this.
- Then `git add <each file by name>` → `git status` (tell him how many files
  must be listed, e.g. "file ၉ ခု") → `git commit -m "<English summary>"` →
  `git push`. "LF will be replaced by CRLF" warnings are harmless.
- Read his pasted output: if a file is missing from `git status` (most
  often `firestore.rules` or the Worker), stop and fix it with a follow-up
  sync commit before moving on.
- After his push, pull your own clone so you stay in sync.

**7. Close the loop.** One or two lines on what's done, then the numbered
menu of what's next. If it's very late (he often works past midnight),
it's fine to suggest resting.

Other standing points:

- Never ask Ko to paste secrets/tokens. Before any Delete button, tell him
  to read the dialog title first.
- Prefer reusing what exists (e.g. chat push reused the call push route;
  notification → video reused `_VideoPostItem`) and keep diffs small and
  isolated; Fly stream rule: build Firestore streams once (initState), never
  inside `build()`.
- Keep this file current: update the relevant §3/§4/§5/§6 entries and the
  "Latest small update" line at the top with every confirmed task, and
  remove finished items from the To-do list.

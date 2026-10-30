// Cloudflare Worker for Fly's calls, live streams, uploads and Bunny
// webhooks, all server-side so no secret key ever has to live inside the
// Flutter app.
//
// AUTH (Sep 2026): every app route requires the caller's Firebase ID
// token in an `Authorization: Bearer <token>` header (see
// lib/screens/worker_auth.dart). The Worker verifies its RS256 signature
// against Google's published public keys and checks audience/issuer/
// expiry against FIREBASE_PROJECT_ID - so only signed-in Fly users can
// call it. The old `X-App-Secret` header is still accepted ONLY while the
// APP_SHARED_SECRET secret exists (so older app builds keep working
// during the switch-over); deleting that secret turns it off for good.
//
//  POST /token          - mints a LiveKit access token. Since 25 Oct 2026
//                         only for a room the caller belongs in (their own
//                         live, someone's live as a watch-only viewer, or
//                         a call with a friend), identity = their uid.
//                         /call-push likewise only from one of the two
//                         friends to the OTHER one's own fcmToken.
//  POST /call-push       - sends an FCM push to wake a phone for an
//                         incoming call, even if Fly is fully closed.
//                         With `type: 'call_cancelled'` it instead tells
//                         the callee's phone to stop ringing because the
//                         caller hung up first (works even if Fly was
//                         swiped away on that phone).
//                         With `type: 'chat_message'` (Oct 2026) it wakes
//                         the receiver's phone for a new chat message:
//                         the app shows the notification and marks the
//                         message "Delivered" even if Fly is fully closed.
//                         The sender must be one of the two people in
//                         `chatId` (checked against their verified uid).
//  POST /friend-push     - (4 Oct 2026) wakes someone's phone for a new
//                         friend request (`type: 'friend_request'`) or an
//                         accepted one (`type: 'friend_accept'`). The app
//                         only sends `receiverId`; the Worker checks in
//                         Firestore that the request / friendship really
//                         exists for the verified caller, looks up the
//                         receiver's fcmToken and the caller's name/photo
//                         itself - so nobody can spam fake friend pushes.
//  POST /activity-push  - (11 Oct 2026) wakes someone's phone for a new
//                         comment on their video or a reply in their
//                         comment thread. The app only sends
//                         {receiverId, notificationId}: the Worker reads
//                         users/{receiverId}/notifications/{notificationId}
//                         itself and only pushes if it exists, is a
//                         'comment' / 'reply', was written by the verified
//                         caller (fromId) and is less than 10 minutes old -
//                         so nobody can push made-up text to anyone. Text,
//                         names and ids come from that doc, not the app.
//  POST /search          - (4 Oct 2026) Fly's search. Body {q}. Looks the
//                         words up in Cloudflare D1 (database `fly-search`,
//                         binding SEARCH_DB, SQLite FTS5) and returns only
//                         IDs: {users: [uid], posts: [postId]} (max 20
//                         each). The app then reads those docs from
//                         Firestore, which stays the source of truth - so a
//                         deleted/blocked/not-ready item that is still in
//                         D1 simply never shows.
//  POST /search-sync-me   - (4 Oct 2026) the app calls this on start; the
//                         Worker reads the caller's users/{uid} doc from
//                         Firestore ITSELF (never trusts the app) and
//                         updates their name in D1 only if it changed.
//                         If that doc no longer exists (account deleted),
//                         it removes the user AND all their posts from D1.
//                         Posts get indexed by /bunny-webhook when their
//                         video becomes ready.
//  POST /search-index-post - (19 Oct 2026) the app calls this right after a
//                         new post is saved, so it is searchable at once
//                         (not only after Bunny's webhook). Body {postId}.
//                         The Worker reads posts/{postId} from Firestore
//                         ITSELF, and only indexes it if the verified caller
//                         is its owner and the video has not failed - so
//                         nobody can index made-up text or someone else's
//                         post. The webhook still indexes too (harmless:
//                         the upsert only writes when the text changed).
//  POST /search-log      - (4 Oct 2026) "Trending on Fly". Body {q}. The
//                         app calls it when someone really searches (presses
//                         search, taps a recent/trending item, opens a video
//                         from results) - not on every typed letter. Counted
//                         once per person per word per day, only if the word
//                         matches at least one video, max 30 words per
//                         person per day (table search_hits, kept 8 days).
//  POST /search-trending - (4 Oct 2026) the top words of the last 7 days,
//                         counted by DIFFERENT people: {terms: [..max 8]}.
//                         Cached 10 minutes in the Worker so opening Search
//                         rarely touches D1.
//  GET  /search-backfill  - (4 Oct 2026) one-time copy of existing users /
//                         posts into D1, a page at a time:
//                         /search-backfill?token=SEARCH_ADMIN_TOKEN&what=users
//                         (then what=posts). Shows a "Next page" link until
//                         done. Also creates the tables the first time.
//                         No Firebase sign-in - protected by the token.
//  POST /moderate-text  - (21 Oct 2026) checks text BEFORE the app saves
//                         it where others can see it (names, Sky Notes,
//                         captions, comments, live comments/titles).
//                         Body {text, kind}; answer {ok} or {ok: false,
//                         reason: 'language' | 'spam' | 'reserved'}.
//                         English per word (no "spicy"/"Scunthorpe"
//                         mistakes), Burmese in Zawgyi or Unicode, links
//                         to Telegram/WhatsApp. Word lists: see "Text
//                         moderation" below. Text that passes the lists
//                         is also checked by OpenAI's free
//                         omni-moderation model (any language) when the
//                         OPENAI_API_KEY secret exists (21 Oct 2026).
//                         Nothing is stored.
//  POST /moderate-image - (21 Oct 2026) checks pictures BEFORE they are
//                         uploaded: frames of a video (post or story), a
//                         story photo or a profile photo. Body
//                         {images: [base64 JPEG/PNG, max 16], kind}. Each
//                         goes to OpenAI omni-moderation (free) as its own
//                         request; answer {ok: true, checked} or {ok:
//                         false, reason: 'nudity' | 'violence' |
//                         'self_harm'}. No OPENAI_API_KEY / OpenAI down ->
//                         {ok: true, checked: false} - the app then
//                         REFUSES the upload ("try again in a minute"):
//                         pictures fail closed. Images are not stored.
//  GET  /posts-audience-backfill - (25 Oct 2026) one-time: gives every
//                         old post without an `audience` field
//                         `audience: 'everyone'` ("Who can watch",
//                         lib/screens/post_audience.dart), 40 at a time:
//                         /posts-audience-backfill?token=SEARCH_ADMIN_TOKEN
//                         Needed before the app queries
//                         where('audience', '==', 'everyone') - Firestore
//                         never matches a missing field. Only touches that
//                         one field. Run it on BOTH Workers (dev + prod).
//  POST /create-video    - (kept for potential future use) creates a
//                         Bunny Stream video slot and mints a presigned
//                         TUS upload signature
//  POST /upload-video     - creates a Bunny Stream video slot AND
//                         streams the video body straight through to
//                         it in one call. This is what upload_screen.dart
//                         and story_screen.dart use (via
//                         video_upload_service.dart) - a plain POST with
//                         the raw video bytes as the body (not JSON), so
//                         it's routed before the JSON-parsing paths below.
//  POST /upload-image     - streams an image body straight through to a
//                         Bunny Storage zone (profile photos, story
//                         images - not video, so Bunny Stream doesn't
//                         apply). Also a raw-body route, not JSON.
//  GET  /privacy         - (Oct 2026) public Privacy Policy page (English)
//  GET  /terms           - (22 Oct 2026) public Terms of Use + Community
//                         Guidelines page (also /terms-of-use,
//                         /community-guidelines). The app links to it at
//                         sign-up and asks everyone to agree once.
//  GET  /delete-account  - (Oct 2026) public web page where people can
//                         ask for their Fly account to be deleted without
//                         the app - Google Play requires this link (put it
//                         in Play Console -> App content -> Data safety).
//                         No sign-in: anyone can open it.
//  POST /delete-request   - the form on that page posts here (no sign-in).
//                         It ONLY stores the request in Firestore
//                         `deletionRequests/{id}` (status 'pending'); it
//                         never deletes anything itself. Ko checks the
//                         email matches a real account, deletes it, then
//                         marks the request done. Clients can't read or
//                         write that collection (no rule = denied).
//  POST /bunny-webhook    - called BY BUNNY (not the app) whenever a
//                         video's encoding status changes. Marks the
//                         matching post/story `videoReady: true` in
//                         Firestore once it's playable, so the feed only
//                         shows finished videos to other people.
//                         Authenticated with ?token=BUNNY_WEBHOOK_TOKEN
//                         in the webhook URL (Bunny can't send a
//                         Firebase token).
//                         25 Oct 2026: when encoding FINISHES (status 3)
//                         it also re-checks the video's pictures with
//                         OpenAI and removes a refused post / story (see
//                         modCheckBunnyVideo) - hack-proof moderation.
//  POST /report           - a signed-in user reports a post, comment /
//                         reply or user (25 Oct 2026); hides content
//                         when the rules say so - see handleReport.
//  POST /appeal           - the owner of a hidden / limited post asks Ko
//                         to look again (27 Oct 2026) - see handleAppeal.
//  GET  /admin            - (27 Oct 2026, Report system step 3) Ko's review
//                         queue page: Restore / Remove reported posts and
//                         comments. Ko types SEARCH_ADMIN_TOKEN on the page
//                         (never in the link). Its calls go to
//  POST /admin-api        - header X-Admin-Token = SEARCH_ADMIN_TOKEN. See
//                         handleAdminApi. Strikes live in
//                         moderationStrikes/{uid}, reporters' rejected /
//                         accepted counts in reporterStanding/{uid}
//                         (Worker-only collections).
//                         30 Oct 2026 (strikes, TikTok / YouTube style):
//                         each Remove adds moderationStrikes/{uid}/items/
//                         {key} that counts for 90 days; 1 active strike =
//                         warning, 2 = no posting for 7 days, 3+ or child
//                         safety = 30 days (postBanUntil). /upload-video and
//                         firestore.rules (posts / stories create) refuse
//                         while it lasts. The owner may READ their own
//                         moderationStrikes doc + items (rules).
//  GET /moderation-video-test?token=SEARCH_ADMIN_TOKEN&video=ID - shows
//                         that re-check's scores for one video; removes
//                         nothing. With &remove=1 it runs the real
//                         removal on that video (to test it with a
//                         harmless video).
//
// SETUP: same secrets as before - LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
// LIVEKIT_URL, APP_SHARED_SECRET (legacy - delete once every phone runs
// the Firebase-token app build), FIREBASE_PROJECT_ID,
// FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY_B64, BUNNY_LIBRARY_ID,
// BUNNY_API_KEY, plus two for Bunny Storage:
//   BUNNY_STORAGE_ZONE      - the Storage Zone name, e.g.
//                             "fly-images-aungdev756617"
//   BUNNY_STORAGE_PASSWORD  - that zone's password/API key, from its
//                             "FTP & API Access" page. Separate from
//                             BUNNY_API_KEY (that one's for Stream/video).
// optional, for AI text moderation (21 Oct 2026):
//   OPENAI_API_KEY          - an OpenAI API key (no billing needed - the
//                             Moderation API is free). Without it,
//                             /moderate-text uses the word lists only.
// one for search (4 Oct 2026):
//   SEARCH_ADMIN_TOKEN      - any long random string, only for
//                             /search-backfill?token=...
// plus a D1 binding (Settings -> Bindings): SEARCH_DB -> fly-search.
// and one for the Bunny webhook:
//   BUNNY_WEBHOOK_TOKEN     - any long random string; the same value goes
//                             at the end of the Webhook URL set in Bunny
//                             (.../bunny-webhook?token=THAT_VALUE).
// and one for the server-side video re-check (25 Oct 2026, a plain Text
// variable - not secret):
//   BUNNY_CDN_HOSTNAME      - the Stream library's CDN host, the same as
//                             bunnyStreamCdnHost in lib/app_config.dart:
//                             prod vz-a6ab9346-730.b-cdn.net,
//                             dev  vz-6cc91834-d0e.b-cdn.net.
//                             Without it the re-check is skipped.

// Cloudflare's request-body limit on the free Workers plan is 100 MB.
const MAX_VIDEO_UPLOAD_BYTES = 95 * 1024 * 1024;

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DATASTORE_SCOPE = 'https://www.googleapis.com/auth/datastore';

// Google's public keys for Firebase Auth ID tokens, as a JWK set.
const FIREBASE_JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Public account-deletion page + its form (no Firebase sign-in - the
    // person may not have the app any more). Routed before everything else.
    if (request.method === 'GET' && url.pathname === '/delete-account') {
      return new Response(DELETE_ACCOUNT_PAGE_HTML, {
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'public, max-age=300',
          'X-Frame-Options': 'DENY',
          'Referrer-Policy': 'no-referrer',
        },
      });
    }
    // Public Privacy Policy (Oct 2026): link for Play Console + the app.
    if (request.method === 'GET' &&
        (url.pathname === '/privacy' || url.pathname === '/privacy-policy')) {
      return new Response(PRIVACY_PAGE_HTML, {
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'public, max-age=300',
          'X-Frame-Options': 'DENY',
          'Referrer-Policy': 'no-referrer',
        },
      });
    }
    if (request.method === 'GET' && url.pathname === '/community-guidelines') {
      return Response.redirect(`${url.origin}/terms#community-guidelines`, 302);
    }
    if (request.method === 'GET' &&
        (url.pathname === '/terms' || url.pathname === '/terms-of-use')) {
      return new Response(TERMS_PAGE_HTML, {
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'public, max-age=300',
          'X-Frame-Options': 'DENY',
          'Referrer-Policy': 'no-referrer',
        },
      });
    }
    if (request.method === 'POST' && url.pathname === '/delete-request') {
      return handleDeleteRequest(request, env);
    }
    // One-time search backfill, opened by Ko in a browser (token-protected).
    if (request.method === 'GET' && url.pathname === '/search-backfill') {
      return handleSearchBackfill(env, url);
    }
    if (request.method === 'GET' && url.pathname === '/posts-audience-backfill') {
      return handlePostsAudienceBackfill(env, url);
    }
    if (request.method === 'GET' && url.pathname === '/moderation-video-test') {
      return handleModerationVideoTest(env, url);
    }
    // Report system step 3 (27 Oct 2026): Ko's review page + its API
    // (SEARCH_ADMIN_TOKEN in a header, not a Firebase sign-in).
    if (request.method === 'GET' && url.pathname === '/admin') {
      return new Response(ADMIN_PAGE_HTML, { headers: ADMIN_PAGE_HEADERS });
    }
    if (request.method === 'POST' && url.pathname === '/admin-api') {
      return handleAdminApi(request, env);
    }

    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    // Bunny's own webhook - authenticated by its URL token instead of a
    // user's Firebase token, so it's routed before that check.
    if (url.pathname === '/bunny-webhook') {
      return handleBunnyWebhook(request, env, url);
    }

    // { uid } for a verified Firebase user, { uid: null } for a legacy
    // shared-secret call, or null = reject.
    const caller = await authenticateCaller(request, env);
    if (!caller) {
      return new Response('Unauthorized', { status: 401 });
    }

    const path = url.pathname;

    // These two carry a raw binary body, not JSON - handle them before
    // the JSON-body paths below even attempt to parse anything.
    if (path === '/upload-video') {
      // 30 Oct 2026: no new videos while posting is turned off by strikes.
      const banUntil = await postingBanUntilMs(env, caller.uid);
      if (banUntil) {
        return jsonResponse({
          error: 'posting_banned',
          until: new Date(banUntil).toISOString(),
        }, 403);
      }
      return handleUploadVideo(request, env);
    }
    if (path === '/upload-image') {
      return handleUploadImage(request, env, caller);
    }

    let body;
    try {
      body = await request.json();
    } catch (_) {
      return new Response('Invalid JSON body', { status: 400 });
    }

    if (path === '/call-push') {
      return handleCallPush(body, env, caller);
    }
    if (path === '/friend-push') {
      return handleFriendPush(body, env, caller);
    }
    if (path === '/activity-push') {
      return handleActivityPush(body, env, caller);
    }
    if (path === '/search') {
      return handleSearch(body, env);
    }
    if (path === '/search-sync-me') {
      return handleSearchSyncMe(env, caller);
    }
    if (path === '/search-index-post') {
      return handleSearchIndexPost(body, env, caller);
    }
    if (path === '/search-log') {
      return handleSearchLog(body, env, caller);
    }
    if (path === '/search-trending') {
      return handleSearchTrending(env);
    }
    if (path === '/moderate-text') {
      return handleModerateText(body, env);
    }
    if (path === '/moderate-image') {
      return handleModerateImage(body, env);
    }
    if (path === '/report') {
      return handleReport(body, env, caller);
    }
    if (path === '/appeal') {
      return handleAppeal(body, env, caller);
    }
    if (path === '/create-video') {
      return handleCreateVideo(body, env);
    }
    return handleTokenRequest(body, env, caller);
  },
};

// ---------------------------------------------------------------------
// Caller authentication
// ---------------------------------------------------------------------
async function authenticateCaller(request, env) {
  const authHeader = request.headers.get('Authorization') || '';
  if (authHeader.startsWith('Bearer ')) {
    const uid = await verifyFirebaseIdToken(
      authHeader.slice('Bearer '.length).trim(),
      env,
    );
    return uid ? { uid } : null;
  }

  // Legacy path for older app builds - works only while the
  // APP_SHARED_SECRET secret still exists on this Worker.
  const providedSecret = request.headers.get('X-App-Secret');
  if (
    env.APP_SHARED_SECRET &&
    providedSecret &&
    providedSecret === env.APP_SHARED_SECRET
  ) {
    return { uid: null };
  }
  return null;
}

// Cached per Worker instance; refreshed per Google's Cache-Control.
let firebaseKeysCache = { keys: null, expiresAt: 0 };

async function getFirebasePublicKeys(forceRefresh = false) {
  const now = Date.now();
  if (!forceRefresh && firebaseKeysCache.keys && now < firebaseKeysCache.expiresAt) {
    return firebaseKeysCache.keys;
  }
  const response = await fetch(FIREBASE_JWKS_URL);
  if (!response.ok) {
    throw new Error(`Could not load Firebase public keys (${response.status})`);
  }
  const data = await response.json();
  const match = /max-age=(\d+)/.exec(response.headers.get('Cache-Control') || '');
  const maxAgeSeconds = match ? Number(match[1]) : 3600;
  firebaseKeysCache = {
    keys: data.keys || [],
    expiresAt: now + maxAgeSeconds * 1000,
  };
  return firebaseKeysCache.keys;
}

function base64UrlToBytes(input) {
  const base64 = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToJson(input) {
  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(input)));
}

// Returns the Firebase uid if [token] is a valid, unexpired ID token for
// this Firebase project, otherwise null. Follows Firebase's documented
// checks for verifying ID tokens with a third-party JWT library.
async function verifyFirebaseIdToken(token, env) {
  try {
    const projectId = env.FIREBASE_PROJECT_ID;
    if (!token || !projectId) return null;

    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [headerB64, payloadB64, signatureB64] = parts;
    const header = base64UrlToJson(headerB64);
    const payload = base64UrlToJson(payloadB64);
    if (header.alg !== 'RS256' || !header.kid) return null;

    let keys = await getFirebasePublicKeys();
    let jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) {
      // Google rotates keys; refetch once before giving up.
      keys = await getFirebasePublicKeys(true);
      jwk = keys.find((k) => k.kid === header.kid);
    }
    if (!jwk) return null;

    const key = await crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    const valid = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      key,
      base64UrlToBytes(signatureB64),
      new TextEncoder().encode(`${headerB64}.${payloadB64}`),
    );
    if (!valid) return null;

    const now = Math.floor(Date.now() / 1000);
    const skew = 300; // tolerate small clock differences
    if (payload.aud !== projectId) return null;
    if (payload.iss !== `https://securetoken.google.com/${projectId}`) {
      return null;
    }
    if (typeof payload.exp !== 'number' || payload.exp <= now - skew) {
      return null;
    }
    if (typeof payload.iat !== 'number' || payload.iat > now + skew) {
      return null;
    }
    if (
      typeof payload.auth_time === 'number' &&
      payload.auth_time > now + skew
    ) {
      return null;
    }
    if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
      return null;
    }
    return payload.sub;
  } catch (_) {
    return null;
  }
}

// The other person's uid in a 1-on-1 room / chat id "{uidA}_{uidB}"
// (sorted, as the app builds it) when [uid] is one of the two, else null.
// "live_{uid}" rooms never count as a pair.
function pairOtherId(roomName, uid) {
  const room = String(roomName || '');
  if (room.startsWith('live_')) return null;
  const ids = room.split('_');
  if (ids.length !== 2 || !isSafeUid(ids[0]) || !isSafeUid(ids[1])) return null;
  if (ids[0] === ids[1] || ids[0] > ids[1]) return null;
  if (!isSafeUid(uid) || !ids.includes(uid)) return null;
  return ids[0] === uid ? ids[1] : ids[0];
}

// 25 Oct 2026 (security): a token is only given for a room the caller
// belongs in, and always with the caller's own uid as the identity:
//   - "live_{host}": the host may publish; anyone else joins as a viewer
//     who can watch only (no camera / mic / data);
//   - "{uidA}_{uidB}" (a call): only one of those two, and only while
//     they are friends (users/{me}/friends/{other} exists - the same rule
//     the app and firestore.rules use for calls).
// Before this, any signed-in user could get a token for ANY room name
// (join someone else's call, or publish into someone's live) with any
// identity. participant_name is now only the display name.
async function handleTokenRequest(body, env, caller) {
  const roomName = String(body.room_name || '');
  const participantName = String(body.participant_name || '');
  if (!roomName || !participantName) {
    return new Response('room_name and participant_name are required', {
      status: 400,
    });
  }
  const uid = caller && caller.uid;
  if (!isSafeUid(uid)) {
    return new Response('Not allowed', { status: 403 });
  }

  let canPublish = true;
  if (roomName.startsWith('live_')) {
    const host = roomName.slice('live_'.length);
    if (!isSafeUid(host)) {
      return new Response('Not allowed for this room', { status: 403 });
    }
    canPublish = host === uid;
  } else {
    const other = pairOtherId(roomName, uid);
    if (!other) {
      return new Response('Not allowed for this room', { status: 403 });
    }
    try {
      const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
      const friend = await firestoreGetFields(
        env, dbToken, `users/${uid}/friends/${other}`);
      if (friend === null) {
        return new Response('Only friends can call', { status: 403 });
      }
    } catch (err) {
      return new Response(`Could not check the call: ${err.message}`, {
        status: 503,
      });
    }
  }

  try {
    const token = await createLiveKitToken({
      apiKey: env.LIVEKIT_API_KEY,
      apiSecret: env.LIVEKIT_API_SECRET,
      room: roomName,
      identity: uid,
      name: participantName.slice(0, 80),
      canPublish,
    });

    return new Response(
      JSON.stringify({
        participantToken: token,
        serverUrl: env.LIVEKIT_URL,
      }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    return new Response(`Token generation failed: ${err.message}`, {
      status: 500,
    });
  }
}

// Creates a video slot AND relays the video body to it in a single call.
// The Worker never buffers the whole file in memory - request.body is a
// stream, and it's handed straight to the outgoing PUT's body, so bytes
// flow through as they arrive from the phone rather than being collected
// first.
//
// Fixes for the stuck 0-byte "Processing" videos on Bunny:
//  1. The phone MUST send a Content-Length, and the body is relayed
//     through a FixedLengthStream of exactly that length. The PUT to Bunny
//     then carries a real Content-Length (not chunked), and if the phone's
//     connection drops mid-upload the relay FAILS instead of quietly
//     ending early with a short or empty file.
//  2. If anything goes wrong after the slot was created (upload error,
//     dropped connection, Bunny rejecting the file), the slot is DELETED,
//     so no empty "Processing" video is left behind on Bunny - and the
//     app gets an error instead of a video id, so no post points at it.
async function handleUploadVideo(request, env) {
  if (!env.BUNNY_LIBRARY_ID || !env.BUNNY_API_KEY) {
    return new Response('Bunny Stream is not configured on this Worker', {
      status: 500,
    });
  }
  const title = request.headers.get('X-Video-Title') || 'Fly video';

  // Validate the body size BEFORE creating anything on Bunny.
  const lengthHeader = request.headers.get('Content-Length');
  const contentLength = Number(lengthHeader);
  if (!lengthHeader || !Number.isFinite(contentLength) || contentLength <= 0) {
    return new Response('Content-Length is required and must be > 0', {
      status: 411,
    });
  }
  if (contentLength > MAX_VIDEO_UPLOAD_BYTES) {
    return new Response('Video is too large', { status: 413 });
  }
  if (!request.body) {
    return new Response('Empty request body', { status: 400 });
  }

  let videoId = null;
  try {
    const createResponse = await fetch(
      `https://video.bunnycdn.com/library/${env.BUNNY_LIBRARY_ID}/videos`,
      {
        method: 'POST',
        headers: {
          AccessKey: env.BUNNY_API_KEY,
          Accept: 'application/json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ title }),
      },
    );
    const createText = await createResponse.text();
    if (!createResponse.ok) {
      return new Response(`Bunny create-video failed: ${createText}`, {
        status: 502,
      });
    }
    const created = JSON.parse(createText);
    videoId = created.guid;

    // Exactly contentLength bytes must pass through, or the stream errors.
    const { readable, writable } = new FixedLengthStream(contentLength);
    const relay = request.body.pipeTo(writable);

    const [uploadResponse] = await Promise.all([
      fetch(
        `https://video.bunnycdn.com/library/${env.BUNNY_LIBRARY_ID}/videos/${videoId}`,
        {
          method: 'PUT',
          headers: {
            AccessKey: env.BUNNY_API_KEY,
            'Content-Type': 'application/octet-stream',
          },
          body: readable,
        },
      ),
      relay,
    ]);

    const uploadText = await uploadResponse.text();
    if (!uploadResponse.ok) {
      await deleteBunnyVideo(env, videoId);
      return new Response(`Bunny video upload failed: ${uploadText}`, {
        status: 502,
      });
    }

    return new Response(JSON.stringify({ videoId }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    // Dropped connection, short body, network error... never leave an
    // empty slot behind.
    if (videoId) {
      await deleteBunnyVideo(env, videoId);
    }
    return new Response(`Upload-video failed: ${err.message}`, {
      status: 500,
    });
  }
}

// Best-effort cleanup of a video slot whose upload didn't complete.
async function deleteBunnyVideo(env, videoId) {
  try {
    await fetch(
      `https://video.bunnycdn.com/library/${env.BUNNY_LIBRARY_ID}/videos/${videoId}`,
      {
        method: 'DELETE',
        headers: { AccessKey: env.BUNNY_API_KEY },
      },
    );
  } catch (_) {
    // Nothing more we can do - it can still be deleted by hand.
  }
}

// ---------------------------------------------------------------------
// Bunny webhook -> Firestore "video is ready"
// ---------------------------------------------------------------------
// Bunny Stream webhook status codes:
//   3 = Finished, 4 = Resolution finished (the first one means playable),
//   5 = Failed. Everything else (queued, processing...) is ignored.
//
// Writes videoStatus/{videoGuid} first, THEN flags any post/story with
// that bunnyVideoId. The app does the mirror image (creates the post,
// THEN reads videoStatus), so whichever side is second always catches
// the "ready" signal - even if encoding finishes before the post exists.
async function handleBunnyWebhook(request, env, url) {
  const token = url.searchParams.get('token');
  if (!env.BUNNY_WEBHOOK_TOKEN || token !== env.BUNNY_WEBHOOK_TOKEN) {
    return new Response('Unauthorized', { status: 401 });
  }

  let payload;
  try {
    payload = await request.json();
  } catch (_) {
    return new Response('Invalid JSON body', { status: 400 });
  }

  const libraryId = String(payload.VideoLibraryId ?? '');
  const videoGuid = String(payload.VideoGuid ?? '');
  const status = Number(payload.Status);

  // Anything we don't act on still gets a 200, so Bunny doesn't retry it.
  if (libraryId !== String(env.BUNNY_LIBRARY_ID)) {
    return new Response('Ignored: other library', { status: 200 });
  }
  if (!/^[0-9a-fA-F-]{36}$/.test(videoGuid)) {
    return new Response('Ignored: bad video id', { status: 200 });
  }

  let ready;
  if (status === 3 || status === 4) {
    ready = true;
  } else if (status === 5) {
    ready = false;
  } else {
    return new Response('Ignored: status not relevant', { status: 200 });
  }
  const failed = status === 5;

  try {
    const accessToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);

    // 25 Oct 2026: server-side re-check once encoding has FINISHED (all of
    // Bunny's pictures exist then) - see modCheckBunnyVideo.
    if (status === 3) {
      let check = { reason: null, checked: false };
      try {
        check = await modCheckBunnyVideo(env, videoGuid);
      } catch (err) {
        console.log('video re-check failed', videoGuid, err.message);
      }
      if (check.reason) {
        await firestorePatch(env, accessToken, `videoStatus/${videoGuid}`, {
          ready: false,
          failed: true,
          status,
          blocked: true,
          blockReason: check.reason,
          modChecked: true,
          updatedAt: new Date(),
        });
        await modRemoveBunnyVideo(env, accessToken, videoGuid, check.reason);
        return new Response('OK: removed by moderation', { status: 200 });
      }
      await firestorePatch(env, accessToken, `videoStatus/${videoGuid}`, {
        modChecked: check.checked,
      });
    }

    await firestorePatch(env, accessToken, `videoStatus/${videoGuid}`, {
      ready,
      failed,
      status,
      updatedAt: new Date(),
    });

    for (const collection of ['posts', 'stories']) {
      const docNames = await firestoreFindByField(
        env,
        accessToken,
        collection,
        'bunnyVideoId',
        videoGuid,
      );
      for (const name of docNames) {
        // Posts are read first (best-effort): for search, and so a post
        // from an older app build gets `audience: 'everyone'` (25 Oct 2026,
        // "Who can watch" - a where('audience', '==', 'everyone') query
        // never matches a missing field).
        let doc = null;
        if (collection === 'posts') {
          try {
            doc = await firestoreGetByName(accessToken, name);
          } catch (_) {}
        }
        const patch = { videoReady: ready, videoFailed: failed };
        if (doc && !(doc.fields && doc.fields.audience)) patch.audience = 'everyone';
        await firestorePatchByName(accessToken, name, patch);
        // A post whose video just became playable goes into search
        // (best-effort - search must never make Bunny retry the webhook).
        if (collection === 'posts' && ready && env.SEARCH_DB && doc) {
          try {
            const fields = { ...(doc.fields || {}) };
            if (patch.audience) fields.audience = { stringValue: 'everyone' };
            await ensureSearchSchema(env);
            await searchUpsertPost(env, docIdFromName(name), fields);
          } catch (_) {}
        }
      }
    }

    return new Response('OK', { status: 200 });
  } catch (err) {
    // 500 makes Bunny retry the webhook later.
    return new Response(`Webhook failed: ${err.message}`, { status: 500 });
  }
}

// ---------------------------------------------------------------------
// Account-deletion requests (public form on /delete-account)
// ---------------------------------------------------------------------
// Stores the request only - see the route notes at the top. Bots: a hidden
// "website" field real people never fill, and a minimum time on the page;
// either one quietly "succeeds" without storing anything.
async function handleDeleteRequest(request, env) {
  const ok = () =>
    new Response(JSON.stringify({ ok: true }), {
      headers: { 'Content-Type': 'application/json' },
    });

  const lengthHeader = Number(request.headers.get('Content-Length') || '0');
  if (lengthHeader > 4096) {
    return new Response('Request too large', { status: 413 });
  }

  let body;
  try {
    body = await request.json();
  } catch (_) {
    return new Response('Invalid JSON body', { status: 400 });
  }

  if (body.website) return ok(); // honeypot filled = bot
  if (typeof body.elapsedMs === 'number' && body.elapsedMs < 2500) return ok();

  const email = String(body.email || '').trim().toLowerCase().slice(0, 200);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return new Response('A valid email is required', { status: 400 });
  }

  try {
    const accessToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    await firestorePatch(
      env,
      accessToken,
      `deletionRequests/${crypto.randomUUID()}`,
      {
        email,
        username: String(body.username || '').trim().slice(0, 80),
        reason: String(body.reason || '').trim().slice(0, 500),
        status: 'pending',
        createdAt: new Date(),
      },
    );
    return ok();
  } catch (err) {
    return new Response(`Could not save the request: ${err.message}`, {
      status: 500,
    });
  }
}

function firestoreBase(env) {
  return `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
}

function toFirestoreValue(value) {
  if (value === null || value === undefined) return { nullValue: null };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') {
    return Number.isInteger(value)
      ? { integerValue: String(value) }
      : { doubleValue: value };
  }
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  return { stringValue: String(value) };
}

function toFirestoreFields(obj) {
  const fields = {};
  for (const [key, value] of Object.entries(obj)) {
    fields[key] = toFirestoreValue(value);
  }
  return fields;
}

// Merge-writes [fields] into documents/{path} (creates it if missing).
async function firestorePatch(env, accessToken, path, fields) {
  return firestorePatchByName(
    accessToken,
    `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${path}`,
    fields,
  );
}

// Same, for a full resource name as returned by a query.
async function firestorePatchByName(accessToken, name, fields) {
  const mask = Object.keys(fields)
    .map((f) => `updateMask.fieldPaths=${encodeURIComponent(f)}`)
    .join('&');
  const response = await fetch(
    `https://firestore.googleapis.com/v1/${name}?${mask}`,
    {
      method: 'PATCH',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ fields: toFirestoreFields(fields) }),
    },
  );
  if (!response.ok) {
    throw new Error(`Firestore write failed: ${await response.text()}`);
  }
}

// Resource names of documents in [collection] where [field] == [value].
async function firestoreFindByField(env, accessToken, collection, field, value) {
  const response = await fetch(`${firestoreBase(env)}:runQuery`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: collection }],
        where: {
          fieldFilter: {
            field: { fieldPath: field },
            op: 'EQUAL',
            value: { stringValue: value },
          },
        },
        limit: 10,
      },
    }),
  });
  if (!response.ok) {
    throw new Error(`Firestore query failed: ${await response.text()}`);
  }
  const rows = await response.json();
  return rows
    .map((row) => row.document && row.document.name)
    .filter((name) => !!name);
}

// Relays an image's bytes straight through to a Bunny Storage zone - no
// transcoding step needed (unlike video), so this is a much simpler
// single PUT rather than the create-then-upload dance handleUploadVideo
// does for Bunny Stream. Used for profile photos and story images
// (never story videos - those still go through /upload-video/Bunny
// Stream, since they need the same HLS/adaptive-quality treatment as
// feed videos).
async function handleUploadImage(request, env, caller) {
  if (!env.BUNNY_STORAGE_ZONE || !env.BUNNY_STORAGE_PASSWORD) {
    return new Response('Bunny Storage is not configured on this Worker', {
      status: 500,
    });
  }

  // The phone picks this - a short, ASCII-only, already-unique path (e.g.
  // "{uid}_{timestamp}.jpg") - since, like the video title header, an
  // HTTP header value can't safely carry arbitrary Unicode.
  const fileName = request.headers.get('X-File-Name');
  if (!fileName || /[^a-zA-Z0-9._-]/.test(fileName)) {
    return new Response(
      'X-File-Name header is required and must be plain ASCII (letters, digits, dot, dash, underscore only)',
      { status: 400 },
    );
  }

  // A signed-in caller may only write files named after their own uid
  // (the app always uses "{uid}_{timestamp}.jpg"), so nobody can
  // overwrite someone else's profile photo or story image.
  if (caller && caller.uid && !fileName.startsWith(`${caller.uid}_`)) {
    return new Response('X-File-Name must start with your own user id', {
      status: 403,
    });
  }

  try {
    // This zone was created in the Singapore region, which has its own
    // region-specific API endpoint (sg.storage.bunnycdn.com) rather than
    // the generic global one (storage.bunnycdn.com) - using the wrong
    // one is what caused an early 401 Unauthorized here, since the
    // credentials aren't valid against a different region's cluster.
    const uploadResponse = await fetch(
      `https://sg.storage.bunnycdn.com/${env.BUNNY_STORAGE_ZONE}/${fileName}`,
      {
        method: 'PUT',
        headers: { AccessKey: env.BUNNY_STORAGE_PASSWORD },
        body: request.body,
      },
    );
    const uploadText = await uploadResponse.text();
    if (!uploadResponse.ok) {
      return new Response(`Bunny Storage upload failed: ${uploadText}`, {
        status: 502,
      });
    }

    return new Response(JSON.stringify({ fileName }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(`Upload-image failed: ${err.message}`, {
      status: 500,
    });
  }
}

// Kept for potential future use (e.g. a resumable-upload path revisited
// later) - not currently called by the app, which uses /upload-video
// above instead.
async function handleCreateVideo(body, env) {
  const title = body.title || 'Fly video';

  if (!env.BUNNY_LIBRARY_ID || !env.BUNNY_API_KEY) {
    return new Response('Bunny Stream is not configured on this Worker', {
      status: 500,
    });
  }

  try {
    const createResponse = await fetch(
      `https://video.bunnycdn.com/library/${env.BUNNY_LIBRARY_ID}/videos`,
      {
        method: 'POST',
        headers: {
          AccessKey: env.BUNNY_API_KEY,
          Accept: 'application/json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ title }),
      },
    );

    const createText = await createResponse.text();
    if (!createResponse.ok) {
      return new Response(`Bunny create-video failed: ${createText}`, {
        status: 502,
      });
    }
    const created = JSON.parse(createText);
    const videoId = created.guid;

    const expirationTime = Math.floor(Date.now() / 1000) + 86400;
    const signature = await sha256Hex(
      `${env.BUNNY_LIBRARY_ID}${env.BUNNY_API_KEY}${expirationTime}${videoId}`,
    );

    return new Response(
      JSON.stringify({
        videoId,
        libraryId: env.BUNNY_LIBRARY_ID,
        expirationTime,
        signature,
      }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    return new Response(`Create-video failed: ${err.message}`, {
      status: 500,
    });
  }
}

async function sha256Hex(input) {
  const bytes = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Builds the FCM data payload for a chat message push, or returns a
// Response if the request isn't allowed. FCM data must stay under 4 KB, so
// text and names are trimmed.
function buildChatPushData(body, caller) {
  const { fcmToken, chatId, senderName, senderPhoto, text } = body;
  if (!fcmToken || !chatId || !senderName) {
    return new Response('fcmToken, chatId and senderName are required', {
      status: 400,
    });
  }
  // Only a verified user who is one of the two people in the chat may
  // send this - nobody can push a fake message "from" someone else.
  const ids = String(chatId).split('_');
  if (!caller || !caller.uid || ids.length !== 2 || !ids.includes(caller.uid)) {
    return new Response('Not allowed for this chat', { status: 403 });
  }
  return {
    type: 'chat_message',
    chatId: String(chatId),
    senderId: caller.uid,
    senderName: String(senderName).slice(0, 80),
    senderPhoto: String(senderPhoto || '').slice(0, 500),
    text: String(text || '').slice(0, 300),
  };
}

async function handleCallPush(body, env, caller) {
  const { fcmToken, callerName, callerPhoto, roomName, callerId, isVideo } =
      body;
  // 'incoming_call' (default, so older app builds keep working unchanged),
  // 'call_cancelled' (the caller hung up before the callee answered) or
  // 'chat_message' (a new chat message - see buildChatPushData).
  const type =
    body.type === 'call_cancelled' || body.type === 'chat_message'
      ? body.type
      : 'incoming_call';

  let chatData = null;
  if (type === 'chat_message') {
    chatData = buildChatPushData(body, caller);
    if (chatData instanceof Response) return chatData;
  } else if (type === 'call_cancelled') {
    if (!fcmToken || !roomName) {
      return new Response('fcmToken and roomName are required', {
        status: 400,
      });
    }
  } else if (!fcmToken || !roomName || !callerName) {
    return new Response('fcmToken, roomName and callerName are required', {
      status: 400,
    });
  }

  // 25 Oct 2026 (security): every type must come from one of the two
  // people of that chat / call room, the two must be friends (calls and
  // chat are friends-only, like firestore.rules), and the push may only go
  // to the OTHER person's own phone (fcmToken must equal theirs). The
  // caller id, name and photo on a call come from the caller's own
  // profile - nobody can ring someone "as" another person, or push to a
  // stranger's phone. callerId in the body is ignored (older app builds
  // still send it).
  const pairRoom = type === 'chat_message' ? body.chatId : roomName;
  const uid = caller && caller.uid;
  const otherId = pairOtherId(pairRoom, uid);
  if (!otherId) {
    return new Response('Not allowed for this room', { status: 403 });
  }
  let profileName = '';
  let profilePhoto = '';
  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const [friend, other, me] = await Promise.all([
      firestoreGetFields(env, dbToken, `users/${uid}/friends/${otherId}`),
      firestoreGetFields(env, dbToken, `users/${otherId}`),
      type === 'incoming_call'
        ? firestoreGetFields(env, dbToken, `users/${uid}`)
        : Promise.resolve(null),
    ]);
    // A cancel is still allowed after an unfriend, so a ringing phone can
    // always be stopped.
    if (friend === null && type !== 'call_cancelled') {
      return new Response('Only friends', { status: 403 });
    }
    if (!stringField(other, 'fcmToken') ||
        stringField(other, 'fcmToken') !== String(fcmToken)) {
      return new Response('Not that person\'s device', { status: 403 });
    }
    profileName = stringField(me, 'displayName').trim();
    profilePhoto = stringField(me, 'photoUrl');
  } catch (err) {
    return new Response(`Could not check the push: ${err.message}`, {
      status: 503,
    });
  }

  // A cancel only needs the room name - the phone just stops ringing, so
  // there's nothing to show and no sound to play.
  const data =
    type === 'chat_message'
      ? chatData
      : type === 'call_cancelled'
      ? {
          type,
          roomName: String(roomName),
        }
      : {
          type,
          roomName: String(roomName),
          callerId: uid,
          callerName: (profileName || String(callerName)).slice(0, 80),
          callerPhoto: (profilePhoto || String(callerPhoto || '')).slice(0, 500),
          isVideo: String(!!isVideo),
        };
  const aps =
    type === 'call_cancelled'
      ? { 'content-available': 1 }
      : { 'content-available': 1, sound: 'default' };

  try {
    const accessToken = await getGoogleAccessToken(env);
    const fcmResponse = await fetch(
      `https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: fcmToken,
            data,
            android: {
              // High priority for every type: a cancel that arrives late
              // (normal priority can be held back while the phone dozes)
              // would leave the phone ringing for nothing, and a chat
              // message should show up right away like Messenger's.
              priority: 'high',
            },
            apns: {
              headers: { 'apns-priority': '10' },
              payload: { aps },
            },
          },
        }),
      },
    );

    const resultText = await fcmResponse.text();
    if (!fcmResponse.ok) {
      return new Response(`FCM send failed: ${resultText}`, { status: 502 });
    }
    return new Response(resultText, {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(`Push failed: ${err.message}`, { status: 500 });
  }
}

// ---------------------------------------------------------------------
// Friend request pushes (4 Oct 2026, see lib/friend_service.dart)
// ---------------------------------------------------------------------

// Reads documents/{path} with the service account. Returns the plain
// `fields` object (Firestore REST format), or null if it doesn't exist.
async function firestoreGetFields(env, accessToken, path) {
  const response = await fetch(`${firestoreBase(env)}/${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`Firestore read failed: ${await response.text()}`);
  }
  const doc = await response.json();
  return doc.fields || {};
}

function stringField(fields, name) {
  const v = fields && fields[name];
  return v && typeof v.stringValue === 'string' ? v.stringValue : '';
}

// A Firebase uid: letters/digits only, no '/' (it goes into a path).
function isSafeUid(id) {
  return typeof id === 'string' && /^[A-Za-z0-9]{1,128}$/.test(id);
}

async function handleFriendPush(body, env, caller) {
  const type = body.type;
  const receiverId = body.receiverId;
  if (type !== 'friend_request' && type !== 'friend_accept') {
    return new Response('Unknown type', { status: 400 });
  }
  if (!caller || !isSafeUid(caller.uid) || !isSafeUid(receiverId) ||
      receiverId === caller.uid) {
    return new Response('Bad receiver', { status: 400 });
  }

  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);

    // Only push for something that really happened, done by this caller:
    //  - a request: users/{receiver}/friendRequests/{caller} exists;
    //  - an accept: users/{caller}/friends/{receiver} exists.
    const proofPath = type === 'friend_request'
      ? `users/${receiverId}/friendRequests/${caller.uid}`
      : `users/${caller.uid}/friends/${receiverId}`;
    const proof = await firestoreGetFields(env, dbToken, proofPath);
    if (proof === null) {
      return new Response('Nothing to notify about', { status: 403 });
    }

    const receiver = await firestoreGetFields(env, dbToken, `users/${receiverId}`);
    const fcmToken = stringField(receiver, 'fcmToken');
    if (!fcmToken) {
      // No device registered - nothing to do, not an error.
      return new Response('{"skipped":"no fcmToken"}', {
        headers: { 'Content-Type': 'application/json' },
      });
    }
    const sender = await firestoreGetFields(env, dbToken, `users/${caller.uid}`);
    const senderName =
      (stringField(sender, 'displayName').trim() || 'Someone').slice(0, 80);
    const senderPhoto = stringField(sender, 'photoUrl').slice(0, 500);

    const fcmAccessToken = await getGoogleAccessToken(env);
    const fcmResponse = await fetch(
      `https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${fcmAccessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: fcmToken,
            data: {
              type,
              senderId: caller.uid,
              senderName,
              senderPhoto,
            },
            android: { priority: 'high' },
            apns: {
              headers: { 'apns-priority': '10' },
              payload: { aps: { 'content-available': 1, sound: 'default' } },
            },
          },
        }),
      },
    );
    const resultText = await fcmResponse.text();
    if (!fcmResponse.ok) {
      return new Response(`FCM send failed: ${resultText}`, { status: 502 });
    }
    return new Response(resultText, {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(`Friend push failed: ${err.message}`, { status: 500 });
  }
}

// Comment / reply push (11 Oct 2026) - see the route list at the top.
async function handleActivityPush(body, env, caller) {
  const receiverId = body.receiverId;
  const notificationId = body.notificationId;
  if (!caller || !isSafeUid(caller.uid) || !isSafeUid(receiverId) ||
      receiverId === caller.uid || !isSafeUid(notificationId)) {
    return new Response('Bad request', { status: 400 });
  }

  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const notif = await firestoreGetFields(
      env, dbToken, `users/${receiverId}/notifications/${notificationId}`);
    if (notif === null) {
      console.log('activity-push: no such notification', receiverId, notificationId);
      return new Response('Nothing to notify about', { status: 403 });
    }
    const kind = stringField(notif, 'type');
    // comment_reaction (13 Oct 2026) = someone reacted to my comment/reply.
    if ((kind !== 'comment' && kind !== 'reply' &&
         kind !== 'comment_reaction') ||
        stringField(notif, 'fromId') !== caller.uid) {
      return new Response('Nothing to notify about', { status: 403 });
    }
    // Only fresh notifications - an old doc can't be pushed again later.
    const created = notif.createdAt && notif.createdAt.timestampValue;
    if (!created || Date.now() - Date.parse(created) > 10 * 60 * 1000) {
      console.log('activity-push: too old', created);
      return new Response('Too old', { status: 403 });
    }

    const receiver = await firestoreGetFields(env, dbToken, `users/${receiverId}`);
    const fcmToken = stringField(receiver, 'fcmToken');
    if (!fcmToken) {
      console.log('activity-push: receiver has no fcmToken', receiverId);
      return new Response('{"skipped":"no fcmToken"}', {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const fcmAccessToken = await getGoogleAccessToken(env);
    const fcmResponse = await fetch(
      `https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${fcmAccessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: fcmToken,
            data: {
              type: 'activity',
              kind,
              replyKind: stringField(notif, 'replyKind'),
              senderId: caller.uid,
              senderName:
                (stringField(notif, 'fromName').trim() || 'Someone').slice(0, 80),
              senderPhoto: stringField(notif, 'fromPhoto').slice(0, 500),
              text: stringField(notif, 'text').slice(0, 200),
              postId: stringField(notif, 'postId').slice(0, 128),
              commentId: stringField(notif, 'commentId').slice(0, 128),
              commentText: stringField(notif, 'commentText').slice(0, 120),
            },
            android: { priority: 'high' },
            apns: {
              headers: { 'apns-priority': '10' },
              payload: { aps: { 'content-available': 1, sound: 'default' } },
            },
          },
        }),
      },
    );
    const resultText = await fcmResponse.text();
    // Diagnostics (11 Oct 2026) - visible with `npx wrangler tail`.
    console.log('activity-push:', kind, 'to', receiverId,
      'token ...' + fcmToken.slice(-8), 'project', env.FIREBASE_PROJECT_ID,
      'FCM', fcmResponse.status, resultText.slice(0, 300));
    if (!fcmResponse.ok) {
      return new Response(`FCM send failed: ${resultText}`, { status: 502 });
    }
    return new Response(resultText, {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.log('activity-push: error', err.message);
    return new Response(`Activity push failed: ${err.message}`, { status: 500 });
  }
}

// ---------------------------------------------------------------------
// Search (4 Oct 2026): Cloudflare D1 + SQLite FTS5
// ---------------------------------------------------------------------
// Plain tables hold one row per user / post; FTS5 "external content"
// indexes mirror them through triggers, so every upsert is ONE statement
// (the free plan allows 50 D1 queries per request). The trigram tokenizer
// finds text anywhere in a word ("ung" -> "Aung") for queries of 3+
// characters; 1-2 characters use a plain prefix match instead.
// ---------------------------------------------------------------------
// Myanmar text tools for Search (19 Oct 2026)
// ---------------------------------------------------------------------
// Many phones in Myanmar still type "Zawgyi" - a font hack that stores the
// SAME Burmese words with DIFFERENT code points than Unicode. Search used
// to compare raw text, so a post typed in Zawgyi was invisible to a phone
// typing Unicode (and the other way round). Everything that goes INTO the
// search index, and every search word, now passes through here first:
//   1. detect Zawgyi, convert it to Unicode (Google's Myanmar Tools);
//   2. tidy the text (lower case, no zero-width characters, the vowel /
//      medial marks of a syllable in one fixed order - people type them in
//      different orders and Unicode shows them the same).
// Firestore keeps the text exactly as typed; only D1 (search) is normalized.
//
// The Zawgyi detector and the Zawgyi -> Unicode rules below are from
// Google's "Myanmar Tools" (https://github.com/googlei18n/myanmar-tools,
// npm `myanmar-tools` 1.2.0), Copyright 2017 Google LLC, Apache License 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). The rule table and the
// base64 model are copied unchanged; the small runner code is ported from
// their TypeScript to plain JavaScript.

// ---- Zawgyi -> Unicode rules (generated, unchanged) ----
// TRANSLITERATION RULES
// Input path: genconvert/input/my-t-my-s0-zawgyi.txt
function getAllRulesZ2U() {
  var rules0 = [
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u1064'),
      s: '\u1004\u103A\u1039$1\u103B',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u1064'),
      s: '\u1004\u103A\u1039$1',
    },
    {
      p: RegExp('^' + '\u1064'),
      s: '\u1004\u103A\u1039',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u108B'),
      s: '\u1004\u103A\u1039$1\u102D',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u108C'),
      s: '\u1004\u103A\u1039$1\u102E',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u108D'),
      s: '\u1004\u103A\u1039$1\u1036',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u1033\u108B'),
      s: '\u1004\u103A\u1039$1\u103B\u102D\u102F',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u108B'),
      s: '\u1004\u103A\u1039$1\u103B\u102D',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u108C'),
      s: '\u1004\u103A\u1039$1\u103B\u102E',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u108D'),
      s: '\u1004\u103A\u1039$1\u103B\u1036',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])\u103A\u108E'),
      s: '$1\u103B\u102D\u1036',
    },
    {
      p: RegExp('^' + '\u108B'),
      s: '\u1004\u103A\u1039\u102D',
    },
    {
      p: RegExp('^' + '\u108C'),
      s: '\u1004\u103A\u1039\u102E',
    },
    {
      p: RegExp('^' + '\u108D'),
      s: '\u1004\u103A\u1039\u1036',
    },
    {
      p: RegExp('^' + '\u106A'),
      s: '\u1009',
    },
    {
      p: RegExp('^' + '\u106B'),
      s: '\u100A',
    },
    {
      p: RegExp('^' + '\u108F'),
      s: '\u1014',
    },
    {
      p: RegExp('^' + '\u1090'),
      s: '\u101B',
    },
    {
      p: RegExp('^' + '\u1086'),
      s: '\u103F',
    },
    {
      p: RegExp('^' + '[\u103A\u107D]'),
      s: '\u103B',
    },
    {
      p: RegExp('^' + '([\u103B\u107E-\u1084])+'),
      s: '\u103C',
    },
    {
      p: RegExp('^' + '\u103C*\u108A'),
      s: '\u103D\u103E',
    },
    {
      p: RegExp('^' + '\u103C'),
      s: '\u103D',
    },
    {
      p: RegExp('^' + '[\u103D\u1087]'),
      s: '\u103E',
    },
    {
      p: RegExp('^' + '\u1088'),
      s: '\u103E\u102F',
    },
    {
      p: RegExp('^' + '\u1089'),
      s: '\u103E\u1030',
    },
    {
      p: RegExp('^' + '\u1033'),
      s: '\u102F',
    },
    {
      p: RegExp('^' + '\u1034'),
      s: '\u1030',
    },
    {
      p: RegExp('^' + '\u1039'),
      s: '\u103A',
    },
    {
      p: RegExp('^' + '[\u1094\u1095]'),
      s: '\u1037',
    },
    {
      p: RegExp('^' + '\u1025\u1039'),
      s: '\u1009\u103A',
    },
    {
      p: RegExp('^' + '\u1025\u1061'),
      s: '\u1009\u1039\u1001',
    },
    {
      p: RegExp('^' + '\u1025\u1062'),
      s: '\u1009\u1039\u1002',
    },
    {
      p: RegExp('^' + '\u1025\u1065'),
      s: '\u1009\u1039\u1005',
    },
    {
      p: RegExp('^' + '\u1025\u1068'),
      s: '\u1009\u1039\u1007',
    },
    {
      p: RegExp('^' + '\u1025\u1076'),
      s: '\u1009\u1039\u1013',
    },
    {
      p: RegExp('^' + '\u1025\u1078'),
      s: '\u1009\u1039\u1015',
    },
    {
      p: RegExp('^' + '\u1025\u107A'),
      s: '\u1009\u1039\u1017',
    },
    {
      p: RegExp('^' + '\u1025\u1079'),
      s: '\u1009\u1039\u1016',
    },
    {
      p: RegExp('^' + '\u105A'),
      s: '\u102B\u103A',
    },
    {
      p: RegExp('^' + '\u1060'),
      s: '\u1039\u1000',
    },
    {
      p: RegExp('^' + '\u1061'),
      s: '\u1039\u1001',
    },
    {
      p: RegExp('^' + '\u1062'),
      s: '\u1039\u1002',
    },
    {
      p: RegExp('^' + '\u1063'),
      s: '\u1039\u1003',
    },
    {
      p: RegExp('^' + '\u1065'),
      s: '\u1039\u1005',
    },
    {
      p: RegExp('^' + '[\u1066\u1067]'),
      s: '\u1039\u1006',
    },
    {
      p: RegExp('^' + '\u1068'),
      s: '\u1039\u1007',
    },
    {
      p: RegExp('^' + '\u1069'),
      s: '\u1039\u1008',
    },
    {
      p: RegExp('^' + '\u106C'),
      s: '\u1039\u100B',
    },
    {
      p: RegExp('^' + '\u106D'),
      s: '\u1039\u100C',
    },
    {
      p: RegExp('^' + '\u1070'),
      s: '\u1039\u100F',
    },
    {
      p: RegExp('^' + '[\u1071\u1072]'),
      s: '\u1039\u1010',
    },
    {
      p: RegExp('^' + '\u1096'),
      s: '\u1039\u1010\u103D',
    },
    {
      p: RegExp('^' + '[\u1073\u1074]'),
      s: '\u1039\u1011',
    },
    {
      p: RegExp('^' + '\u1075'),
      s: '\u1039\u1012',
    },
    {
      p: RegExp('^' + '\u1076'),
      s: '\u1039\u1013',
    },
    {
      p: RegExp('^' + '\u1077'),
      s: '\u1039\u1014',
    },
    {
      p: RegExp('^' + '\u1078'),
      s: '\u1039\u1015',
    },
    {
      p: RegExp('^' + '\u1079'),
      s: '\u1039\u1016',
    },
    {
      p: RegExp('^' + '\u107A'),
      s: '\u1039\u1017',
    },
    {
      p: RegExp('^' + '[\u107B\u1093]'),
      s: '\u1039\u1018',
    },
    {
      p: RegExp('^' + '\u107C'),
      s: '\u1039\u1019',
    },
    {
      p: RegExp('^' + '\u1085'),
      s: '\u1039\u101C',
    },
    {
      p: RegExp('^' + '\u108E'),
      s: '\u102D\u1036',
    },
    {
      p: RegExp('^' + '\u106E'),
      s: '\u100D\u1039\u100D',
    },
    {
      p: RegExp('^' + '\u106F'),
      s: '\u100D\u1039\u100E',
    },
    {
      p: RegExp('^' + '\u1091'),
      s: '\u100F\u1039\u100D',
    },
    {
      p: RegExp('^' + '\u1092'),
      s: '\u100B\u1039\u100C',
    },
    {
      p: RegExp('^' + '\u1097'),
      s: '\u100B\u1039\u100B',
    },
    {
      p: RegExp('^' + '\u104E'),
      s: '\u104E\u1004\u103A\u1038',
    },
  ];
  var rules1 = [
    {
      p: RegExp('^' + '\u1040([^\u1040-\u1049])'),
      s: '\u101D$1',
      matchOnStart: 'true',
    },
    {
      p: RegExp('^' + '\u1044([^\u1040-\u1049])'),
      s: '\u104E$1',
      matchOnStart: 'true',
      revisit: 0,
    },
    {
      p: RegExp('^' + '([^\u1040-\u1049])\u1040$'),
      s: '$1\u101D',
    },
    {
      p: RegExp('^' + '([^\u1040-\u1049])\u1044$'),
      s: '$1\u104E',
    },
    {
      p: RegExp('^' + '([\u102B-\u103F])\u1040([^\u1040-\u1049])'),
      s: '$1\u101D$2',
    },
    {
      p: RegExp('^' + '([\u102B-\u103F])\u1044([^\u1040-\u1049])'),
      s: '$1\u104E$2',
    },
  ];
  var rules2 = [
    {
      p: RegExp('^' + '([ \u00A0\u1680\u2000-\u200D\u202F\u205F\u2060\u3000\uFEFF])\u1037'),
      s: '\u1037$1',
    },
    {
      p: RegExp('^' + '([ \u00A0\u1680\u2000-\u200D\u202F\u205F\u2060\u3000\uFEFF]+)([\u102B-\u1030\u1032-\u103B\u103D\u103E])'),
      s: '$2',
    },
    {
      p: RegExp('^' + '\u1037+'),
      s: '\u1037',
    },
    {
      p: RegExp('^' + '\u1031+\u1004\u103A\u1039([\u1000-\u1021])'),
      s: '\u1004\u103A\u1039$1\u1031',
    },
    {
      p: RegExp('^' + '\u1031+\u1037+([\u1000-\u1021])'),
      s: '$1\u1031\u1037',
    },
    {
      p: RegExp('^' + '\u1031+\u103C([\u1000-\u1021])'),
      s: '$1\u103C\u1031',
    },
    {
      p: RegExp('^' + '\u1031+([\u1000-\u1021])([\u103B\u103D\u103E]+)'),
      s: '$1$2\u1031',
    },
    {
      p: RegExp('^' + '\u1031+([\u1000-\u102A])'),
      s: '$1\u1031',
    },
  ];
  var rules3 = [
    {
      p: RegExp('^' + '\u103B\u103A'),
      s: '\u103A\u103B',
    },
    {
      p: RegExp('^' + '\u1025\u102E'),
      s: '\u1026',
    },
    {
      p: RegExp('^' + '\u103A\u1037'),
      s: '\u1037\u103A',
    },
    {
      p: RegExp('^' + '\u1036([\u103B-\u103E]*)([\u102B-\u1030\u1032]+)'),
      s: '$1$2\u1036',
    },
    {
      p: RegExp('^' + '([\u102B\u102C\u102F\u1030])([\u102D\u102E\u1032])'),
      s: '$2$1',
    },
    {
      p: RegExp('^' + '\u103C([\u1000-\u1021])'),
      s: '$1\u103C',
    },
  ];
  var rules4 = [
    {
      p: RegExp('^' + '([\u103B-\u103E])\u1039([\u1000-\u1021])'),
      s: '\u1039$2$1',
    },
    {
      p: RegExp('^' + '\u103C\u103A\u1039([\u1000-\u1021])'),
      s: '\u103A\u1039$1\u103C',
    },
    {
      p: RegExp('^' + '\u1036([\u103B-\u103E]+)'),
      s: '$1\u1036',
    },
  ];
  var rules5 = [
    {
      p: RegExp('^' + '([\u103C-\u103E]+)\u103B'),
      s: '\u103B$1',
    },
    {
      p: RegExp('^' + '([\u103D\u103E]+)\u103C'),
      s: '\u103C$1',
    },
    {
      p: RegExp('^' + '\u103E\u103D'),
      s: '\u103D\u103E',
    },
    {
      p: RegExp('^' + '([\u1031]+)([\u102B-\u1030\u1032]*)\u1039([\u1000-\u1021])'),
      s: '\u1039$3$1$2',
    },
    {
      p: RegExp('^' + '([\u102B-\u1030\u1032]+)\u1039([\u1000-\u1021])'),
      s: '\u1039$2$1',
    },
    {
      p: RegExp('^' + '([\u103B-\u103E]*)([\u1031]+)([\u103B-\u103E]*)'),
      s: '$1$3$2',
    },
    {
      p: RegExp('^' + '\u1037([\u102D-\u1030\u1032\u1036\u103B-\u103E]+)'),
      s: '$1\u1037',
    },
    {
      p: RegExp('^' + '([\u102B-\u1030\u1032]+)([\u103B-\u103E]+)'),
      s: '$2$1',
    },
    {
      p: RegExp('^' + '([\u1000-\u1021])([\u102B-\u1032\u1036\u103B-\u103E])\u103A([\u1000-\u1021])'),
      s: '$1\u103A$2$3',
    },
  ];
  var rules6 = [
    {
      p: RegExp('^' + '\u1005\u103B'),
      s: '\u1008',
    },
    {
      p: RegExp('^' + '([\u102B-\u1032])([\u103B-\u103E])'),
      s: '$2$1',
    },
    {
      p: RegExp('^' + '([\u103C-\u103E])\u103B'),
      s: '\u103B$1',
    },
    {
      p: RegExp('^' + '([\u103D\u103E])\u103C'),
      s: '\u103C$1',
    },
    {
      p: RegExp('^' + '\u103E\u103D'),
      s: '\u103D\u103E',
    },
    {
      p: RegExp('^' + '\u1038([\u000136u\u102B-\u1030\u1032\u1037\u103A-\u103F])'),
      s: '$1\u1038',
    },
    {
      p: RegExp('^' + '\u1036\u102F'),
      s: '\u102F\u1036',
    },
  ];
  var rules7 = [
    {
      p: RegExp('^' + '\u102D\u102D+'),
      s: '\u102D',
    },
    {
      p: RegExp('^' + '\u102E\u102E+'),
      s: '\u102E',
    },
    {
      p: RegExp('^' + '\u102F\u102F+'),
      s: '\u102F',
    },
    {
      p: RegExp('^' + '\u1030\u1030+'),
      s: '\u1030',
    },
    {
      p: RegExp('^' + '\u1032\u1032+'),
      s: '\u1032',
    },
    {
      p: RegExp('^' + '\u1036\u1036+'),
      s: '\u1036',
    },
    {
      p: RegExp('^' + '\u1037\u1037+'),
      s: '\u1037',
    },
    {
      p: RegExp('^' + '\u1039\u1039+'),
      s: '\u1039',
    },
    {
      p: RegExp('^' + '\u103A\u103A+'),
      s: '\u103A',
    },
    {
      p: RegExp('^' + '\u103B\u103B+'),
      s: '\u103B',
    },
    {
      p: RegExp('^' + '\u103C\u103C+'),
      s: '\u103C',
    },
    {
      p: RegExp('^' + '\u103D\u103D+'),
      s: '\u103D',
    },
    {
      p: RegExp('^' + '\u103E\u103E+'),
      s: '\u103E',
    },
    {
      p: RegExp('^' + '\u102F[\u1030\u103A]'),
      s: '\u102F',
    },
    {
      p: RegExp('^' + '\u102D\u102E'),
      s: '\u102E',
    },
    {
      p: RegExp('^' + '([ \u00A0\u1680\u2000-\u200D\u202F\u205F\u2060\u3000\uFEFF])+([\u102B-\u1032\u1036-\u103E])'),
      s: '$2',
    },
    {
      p: RegExp('^' + '\u200B+'),
      s: '',
      matchOnStart: 'true',
    },
    {
      p: RegExp('^' + '\u200B+$'),
      s: '',
    },
    {
      p: RegExp('^' + '[ \u00A0\u1680\u2000-\u200D\u202F\u205F\u2060\u3000\uFEFF]*\u200B[ \u00A0\u1680\u2000-\u200D\u202F\u205F\u2060\u3000\uFEFF]*'),
      s: '\u200B',
    },
  ];
  return [rules0, rules1, rules2, rules3, rules4, rules5, rules6, rules7];
}
// END OF TRANSLITERATION RULES


function mmRunPhase(rules, inString) {
  let outString = '';
  let midString = inString;
  let startOfString = true;
  while (midString.length > 0) {
    let foundRule = false;
    for (const rule of rules) {
      if (rule.matchOnStart == null || startOfString) {
        const m = midString.match(rule.p);
        if (m != null) {
          foundRule = true;
          const rightPartSize = midString.length - m[0].length;
          midString = midString.replace(rule.p, rule.s);
          const newStart = midString.length - rightPartSize;
          if (rule.revisit == null) {
            outString += midString.substring(0, newStart);
            midString = midString.substring(newStart);
          }
        }
      }
    }
    if (!foundRule) {
      outString += midString[0];
      midString = midString.substring(1);
    }
    startOfString = false;
  }
  return outString;
}

let mmZ2URules = null;
function zawgyiToUnicode(text) {
  if (!mmZ2URules) mmZ2URules = getAllRulesZ2U();
  let out = String(text);
  for (const rules of mmZ2URules) out = mmRunPhase(rules, out);
  return out;
}

// ---- Zawgyi detector (Markov model, port of zawgyi_detector.ts) ----
const MM_MODEL_B64 = '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AAU/knYwAAa/Gt8wAAc9OtwAAAk/t0j4AAu/q5s4ABC+uD2gABFAOD7MABJACAECABNACAECABQ/6y9AABVAdRuaABY/iyU4ABc9OtwAABm+NcjgABo/vPmMABxANF2IAB2+uD2wAB5AK9HCAB9AHGKMACA/PR/QACK/kQdQACY9OtwAACc9OtwAACg/t0j4ACxAvFxCAC0+1cBQAC4/qTR0AC8/ssSKADBAK9HCADI/ylyQADRAIfQkADU9OtwAADdADDmoADi/qp9+ADlAyspAADrBB3O9ADtBDOjjADw9OtwAAD3ATtFOAD4/r2fWAD9ApENPAEBASL8UAEE9OtwAAFFAFkj+AFpANF2IAHU9OtwAAH7AAioiAH++uD2gAIHAXNtYAIs9OtwAACO/l7HYAABAK+jWAAE/wu+MAAO+++MwAAW9sShAAAY+2UDgAAq+++MwAAw+TgIAAA2+++MwABE/QsOAABM+2UDgABS+++MwABU/sJ5sABY/G00QABi+++MwABo+2UDgABs+TgIAABy/R5cgAB2+++MwAB69sShAAB++++MwACi+++MwACy+++MwAC1ALTqqAC4+ahCAAC8/ZPKYADC9sShAADJAMQhCADM+TgIAADTAJJH4ADc/sJ5sADo/2CoDADs/pl+UADy+++MwAEA+TgIAAEK+++MwACW+wWfQAAA+4mIAAAG+wWfIAAI+oXxgAAM/OIrAAAY+oXxgAAc+oXxgAAg/OIrAAA4+oXxgABE/2dEwABI/OIrAABM+oXxgABU/lxdWABY/kCuoABc/nagcABg/OIrAABo/67TqABs+oXxgABw/OIrAAB4+oXxgACBABtu8ACI+oXxgACe/iRMAACw/OIrAAC2+gx16AC5Af3gPAC9AGUUeADA/nagcADJALaarADdAAUokADnAiUXIADy/iRMAAEA/yLmkAEG/SIB4AEK/iRMAAHW/iRMAAHe//lwEAIa/vPlIACHADiFmAAA/HMfgAAE+sDXgAAa/w4nAAAe/w4nAAAi/w4nAAAq/w4nAAAu/VaFoAA6/w4nAAA+/w4nAABHAF/8AABO/w4nAABU+1idQABY++XpgABi/w4nAABo+NVuAABy+26mwAB09p4UAAB6/w4nAAB++26mwACC+EL1AACK/j6N4AC1AMozaAC5AOQlpAC8+1idQADBAkL6i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ABS/DaVwABU/QiXAABY/IZewABc/AdyIABhAGYn6ABlAFLTcABq9my+AABs+A6KAABw+jV+YAB290UCAAB4/sdJIAB89/BtAACA/roQwACJAH6OKACe/gEZ8ACxApOL6AC2/NDPcAC4/YyQIAC8/y4uWADC/OfL0ADFAN56EADK/vddJADO9IZaAADRAEsvAADY/2lroADc//nAUADhAIey+ADnAeku4ADpAJTUiADtA1yRIADzA1rJEAD3AIrnkAD5AM30eAEBAfe4uAEG/GMBwAFFAC0H+AFM/2lroAFlAX9mkAFpASQXgAF1AgEWBAGK/GMBwAHXAnCsxAHbAh+o+AHfApNFpAHm/gEaAAIbAtbLqAIfAIrnkAA/ABirkABpAf60iAB5AH+uNAB+/s5y8AC5AHUfUAC8/PKHoADBAE9zMADFABfhqADI/mYg0ADa+m/WgAD5APW6kAFk/j65YAHNAiOrCAHS/s5y8AHo/inSwAHy/NcdgABS/btIIAAA/odWkAAE/u4U4AAK+dX/AAAO+dX/AAAW+dX/AAAZAKaPfAAi+dX/AAAq+dX/AABA/W964ABFAb/OIABNAHfi3ABQ/4zhiABU/0OdAABpAVgBlABs/ksIgABy+dX/AAB4/8z26AB8/+o6yACA/W964AEA/odWkABQ+XfogAAA/OkP8AAG9OrzAAAK+8+cgAAs/aPCgABG/7mviABK+8+cgABW/YcAgABa+8+cgABq/yZkeABs/aPCgABw/aPCgAB2/lbLUAB+/n/GuACA/aPCgACK//X9mADLAH3ERADy/YcAgAEI/aPCgAHa+8+cgAIa+8+cgACM/Q7J4AAA/qXq4AAE/iIpdAAK+qxhgAANAREosAAU/upJIAAZAKLg6AAg/lb+EAApAF+2mAAxAF+2mABA/7niQABE/mfH4ABM/32UMABW/HzG4ABY/BmPkABhACaWqABlAcKayABo/cl8YABs+xRiAABxAmdb8AB1AI5jOAB4/7niQAB8/1yJAACE/upJIACI9kgMAACc/upJIAC3AF79SADBAiFmyADFACaWqADLAEezYADi/WFGoADrAxlRkAEBAPYvyAFy+qxhgAF++qxhgAH2+qxhgAA0/GaQYAAA/2XFgAAFADWoOAAY/pYsYABVADWoOABo/pYsYABw/2XFgAB+9vnAAACA/2XFg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';

const MM_STD_CP0 = 0x1000, MM_STD_CP1 = 0x103f;
const MM_AFT_CP0 = 0x104a, MM_AFT_CP1 = 0x109f;
const MM_EXA_CP0 = 0xaa60, MM_EXA_CP1 = 0xaa7f;
const MM_EXB_CP0 = 0xa9e0, MM_EXB_CP1 = 0xa9ff;
const MM_SPC_CP0 = 0x2000, MM_SPC_CP1 = 0x200b;
const MM_STD_OFFSET = 1;
const MM_AFT_OFFSET = MM_STD_OFFSET + MM_STD_CP1 - MM_STD_CP0 + 1;
const MM_EXA_OFFSET = MM_AFT_OFFSET + MM_AFT_CP1 - MM_AFT_CP0 + 1;
const MM_EXB_OFFSET = MM_EXA_OFFSET + MM_EXA_CP1 - MM_EXA_CP0 + 1;
const MM_SPC_OFFSET = MM_EXB_OFFSET + MM_EXB_CP1 - MM_EXB_CP0 + 1;

function mmStateForCodePoint(cp, ssv) {
  if (MM_STD_CP0 <= cp && cp <= MM_STD_CP1) return cp - MM_STD_CP0 + MM_STD_OFFSET;
  if (MM_AFT_CP0 <= cp && cp <= MM_AFT_CP1) return cp - MM_AFT_CP0 + MM_AFT_OFFSET;
  if (MM_EXA_CP0 <= cp && cp <= MM_EXA_CP1) return cp - MM_EXA_CP0 + MM_EXA_OFFSET;
  if (MM_EXB_CP0 <= cp && cp <= MM_EXB_CP1) return cp - MM_EXB_CP0 + MM_EXB_OFFSET;
  if (ssv === 0 && MM_SPC_CP0 <= cp && cp <= MM_SPC_CP1) {
    return cp - MM_SPC_CP0 + MM_SPC_OFFSET;
  }
  return 0;
}

let mmModel = null;
function mmLoadModel() {
  const binary = atob(MM_MODEL_B64);
  const buffer = new ArrayBuffer(binary.length);
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const stream = new DataView(buffer, 0);
  let offset = 8; // magic number
  const version = stream.getUint32(offset);
  offset += 4;
  let ssv = 0;
  if (version === 2) {
    ssv = stream.getUint32(offset);
    offset += 4;
  } else if (version !== 1) {
    throw new Error('Zawgyi model: unexpected version ' + version);
  }
  offset += 12; // Markov magic number + version
  const size = stream.getInt16(offset);
  offset += 2;
  const diffs = [];
  for (let i1 = 0; i1 < size; i1++) {
    diffs[i1] = [];
    let entries = stream.getInt16(offset);
    offset += 2;
    let fallback = 0.0;
    if (entries !== 0) {
      fallback = stream.getFloat32(offset);
      offset += 4;
    }
    let next = -1;
    for (let i2 = 0; i2 < size; i2++) {
      if (entries > 0 && next < i2) {
        next = stream.getInt16(offset);
        offset += 2;
        entries--;
      }
      if (next === i2) {
        diffs[i1][i2] = stream.getFloat32(offset);
        offset += 4;
      } else {
        diffs[i1][i2] = fallback;
      }
    }
  }
  return { ssv, diffs };
}

// Probability (0..1) that [text] is Zawgyi rather than Unicode, or
// -Infinity when it has no Myanmar characters at all.
function zawgyiProbability(text) {
  if (!mmModel) mmModel = mmLoadModel();
  const input = String(text);
  let prev = 0;
  let total = 0.0;
  let seen = false;
  for (let i = 0; i <= input.length; i++) {
    const curr = i === input.length
      ? 0
      : mmStateForCodePoint(input.charCodeAt(i), mmModel.ssv);
    if (prev !== 0 || curr !== 0) {
      total += mmModel.diffs[prev][curr];
      seen = true;
    }
    prev = curr;
  }
  if (!seen) return Number.NEGATIVE_INFINITY;
  return 1.0 / (1.0 + Math.exp(total));
}

// ---- Search normalization ----
// Rank of each Myanmar vowel / medial / tone mark inside a syllable (the
// order Unicode recommends). Keyboards produce them in different orders
// that look identical, so they are sorted into one order before indexing.
const MM_MARK_RANK = {
  '\u103b': 10, '\u103c': 11, '\u103d': 12, '\u103e': 13,
  '\u1031': 20,
  '\u102d': 30, '\u102e': 30, '\u1032': 30,
  '\u102f': 40, '\u1030': 40,
  '\u102b': 50, '\u102c': 50,
  '\u1036': 60, '\u1037': 70, '\u103a': 80, '\u1038': 90,
};

function mmSortMarks(run) {
  return Array.from(run)
    .map((c, i) => [c, i])
    .sort((a, b) => (MM_MARK_RANK[a[0]] - MM_MARK_RANK[b[0]]) || (a[1] - b[1]))
    .map((x) => x[0])
    .join('');
}

// Same text, one spelling of the invisible details. Does NOT convert Zawgyi.
function mmTidy(text) {
  return String(text || '')
    .normalize('NFC')
    .replace(/[\u200b-\u200d\u2060\ufeff]/g, '')
    .toLowerCase()
    .replace(/[\u102b-\u1038\u103a-\u103e]+/g, mmSortMarks)
    .replace(/\s+/g, ' ')
    .trim();
}

// For text that is saved into the search index: Zawgyi is converted.
function searchNormalizeIndex(text) {
  const raw = String(text || '');
  if (!raw) return '';
  const p = zawgyiProbability(raw);
  return mmTidy(p >= 0.5 ? zawgyiToUnicode(raw) : raw);
}

// For something a person TYPES into Search: short words are hard to tell
// apart, so when the detector is not sure both readings are searched.
function searchQueryVariants(text) {
  const raw = String(text || '');
  const p = zawgyiProbability(raw);
  const asTyped = mmTidy(raw);
  if (p === Number.NEGATIVE_INFINITY || p <= 0.1) return [asTyped];
  const converted = mmTidy(zawgyiToUnicode(raw));
  if (p >= 0.9) return [converted];
  return converted && converted !== asTyped ? [asTyped, converted] : [asTyped];
}

// One spelling for places that need a single word (Trending).
function searchCanonicalTerm(text) {
  const raw = String(text || '');
  const p = zawgyiProbability(raw);
  return mmTidy(p >= 0.5 ? zawgyiToUnicode(raw) : raw);
}

// Every distinct 3-character piece of every word that has 3+ characters
// (what the FTS "trigram" index stores). Typos only break the pieces that
// touch the wrong letter, so the rest still match.
function mmTrigrams(text) {
  const out = new Set();
  for (const word of String(text || '').split(' ')) {
    const chars = Array.from(word);
    for (let i = 0; i + 3 <= chars.length; i++) {
      out.add(chars.slice(i, i + 3).join(''));
    }
  }
  return Array.from(out);
}

let searchSchemaReady = false;

async function ensureSearchSchema(env) {
  if (searchSchemaReady) return;
  const statements = [
    `CREATE TABLE IF NOT EXISTS users (
       uid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
       updated_at INTEGER NOT NULL DEFAULT 0)`,
    `CREATE INDEX IF NOT EXISTS users_name ON users(name COLLATE NOCASE)`,
    `CREATE VIRTUAL TABLE IF NOT EXISTS users_fts USING fts5(
       name, content='users', content_rowid='rowid', tokenize='trigram')`,
    `CREATE TRIGGER IF NOT EXISTS users_ai AFTER INSERT ON users BEGIN
       INSERT INTO users_fts(rowid, name) VALUES (new.rowid, new.name); END`,
    `CREATE TRIGGER IF NOT EXISTS users_ad AFTER DELETE ON users BEGIN
       INSERT INTO users_fts(users_fts, rowid, name)
         VALUES ('delete', old.rowid, old.name); END`,
    `CREATE TRIGGER IF NOT EXISTS users_au AFTER UPDATE ON users BEGIN
       INSERT INTO users_fts(users_fts, rowid, name)
         VALUES ('delete', old.rowid, old.name);
       INSERT INTO users_fts(rowid, name) VALUES (new.rowid, new.name); END`,
    `CREATE TABLE IF NOT EXISTS posts (
       post_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL DEFAULT '',
       caption TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '',
       created_at INTEGER NOT NULL DEFAULT 0)`,
    `CREATE INDEX IF NOT EXISTS posts_created ON posts(created_at)`,
    `CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
       caption, tags, content='posts', content_rowid='rowid',
       tokenize='trigram')`,
    `CREATE TRIGGER IF NOT EXISTS posts_ai AFTER INSERT ON posts BEGIN
       INSERT INTO posts_fts(rowid, caption, tags)
         VALUES (new.rowid, new.caption, new.tags); END`,
    `CREATE TRIGGER IF NOT EXISTS posts_ad AFTER DELETE ON posts BEGIN
       INSERT INTO posts_fts(posts_fts, rowid, caption, tags)
         VALUES ('delete', old.rowid, old.caption, old.tags); END`,
    `CREATE TRIGGER IF NOT EXISTS posts_au AFTER UPDATE ON posts BEGIN
       INSERT INTO posts_fts(posts_fts, rowid, caption, tags)
         VALUES ('delete', old.rowid, old.caption, old.tags);
       INSERT INTO posts_fts(rowid, caption, tags)
         VALUES (new.rowid, new.caption, new.tags); END`,
    // Trending (4 Oct 2026): one row = "this person searched this word on
    // this day". The primary key makes repeats free (INSERT OR IGNORE) and
    // lets "last 7 days" read only those days.
    `CREATE TABLE IF NOT EXISTS search_hits (
       day TEXT NOT NULL, term TEXT NOT NULL, uid TEXT NOT NULL,
       PRIMARY KEY (day, term, uid)) WITHOUT ROWID`,
    `CREATE INDEX IF NOT EXISTS search_hits_uid ON search_hits(uid, day)`,
  ];
  await env.SEARCH_DB.batch(statements.map((sql) => env.SEARCH_DB.prepare(sql)));
  searchSchemaReady = true;
}

// Plain-text value of a Firestore REST field (string / timestamp / array
// of strings).
function fsString(fields, name) {
  const v = fields && fields[name];
  if (!v) return '';
  if (typeof v.stringValue === 'string') return v.stringValue;
  return '';
}
function fsStringArray(fields, name) {
  const v = fields && fields[name];
  const values = v && v.arrayValue && v.arrayValue.values;
  if (!Array.isArray(values)) return [];
  return values
    .map((x) => (typeof x.stringValue === 'string' ? x.stringValue : ''))
    .filter((x) => !!x);
}
function fsMillis(fields, name) {
  const v = fields && fields[name];
  if (v && typeof v.timestampValue === 'string') {
    const t = Date.parse(v.timestampValue);
    return Number.isFinite(t) ? t : 0;
  }
  return 0;
}
function docIdFromName(name) {
  return String(name).split('/').pop();
}

function searchUserStatement(env, uid, fields) {
  // Saved in the normalized spelling (Zawgyi -> Unicode, lower case...);
  // Firestore keeps the name as typed.
  const name = searchNormalizeIndex(fsString(fields, 'displayName')).slice(0, 80);
  // Only writes when the name really changed (rows written cost quota).
  return env.SEARCH_DB.prepare(
    `INSERT INTO users (uid, name, updated_at) VALUES (?1, ?2, ?3)
     ON CONFLICT(uid) DO UPDATE SET name = excluded.name,
       updated_at = excluded.updated_at
     WHERE users.name IS NOT excluded.name`,
  ).bind(uid, name, Date.now());
}

// 24 Oct 2026 ("Who can watch"): only Everyone posts are searchable. A post
// whose `audience` is followers / friends / only_me is REMOVED from the
// index instead (so a post that becomes private disappears from Search).
// Posts without the field are Everyone.
function searchPostIsPublic(fields) {
  const audience = fsString(fields, 'audience');
  return audience === '' || audience === 'everyone';
}

function searchPostStatement(env, postId, fields) {
  if (!searchPostIsPublic(fields)) {
    return env.SEARCH_DB.prepare('DELETE FROM posts WHERE post_id = ?1')
      .bind(postId);
  }
  const caption = searchNormalizeIndex(fsString(fields, 'caption').slice(0, 500));
  const tags = searchNormalizeIndex(
    fsStringArray(fields, 'hashtags')
      .map((t) => t.replace(/^#/, ''))
      .join(' '),
  ).slice(0, 300);
  return env.SEARCH_DB.prepare(
    `INSERT INTO posts (post_id, owner_id, caption, tags, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(post_id) DO UPDATE SET caption = excluded.caption,
       tags = excluded.tags
     WHERE posts.caption IS NOT excluded.caption
        OR posts.tags IS NOT excluded.tags`,
  ).bind(
    postId,
    fsString(fields, 'userId'),
    caption,
    tags,
    fsMillis(fields, 'createdAt'),
  );
}

async function searchUpsertPost(env, postId, fields) {
  await searchPostStatement(env, postId, fields).run();
}

async function firestoreGetByName(accessToken, name) {
  const response = await fetch(`https://firestore.googleapis.com/v1/${name}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`Firestore read failed: ${await response.text()}`);
  }
  return response.json();
}

// "aung" -> '"aung"' (an FTS5 phrase; quotes inside are doubled, so the
// person's text can never be read as FTS syntax).
function ftsPhrase(text) {
  return `"${text.replace(/"/g, '""')}"`;
}

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Keep letters/numbers/spaces of any language; drop punctuation.
function cleanSearchText(value) {
  const raw = String(value || '').normalize('NFC').slice(0, 60);
  return raw.replace(/[^\p{L}\p{N}\p{M}\s]/gu, ' ').replace(/\s+/g, ' ').trim();
}

// Search (19 Oct 2026, "Stage 1"):
//  - the typed words are normalized like the index (Zawgyi -> Unicode...);
//  - 3+ characters: fuzzy. The words are cut into 3-character pieces, FTS5
//    finds posts/names that contain ANY piece, and the Worker keeps those
//    that contain enough of them (so one wrong letter still finds the
//    post) and puts the best matches first;
//  - 1-2 characters: names / hashtags that start with it, and captions
//    that contain it (newest SEARCH_SHORT_SCAN_POSTS posts only).
// Cost note: an OR query reads many index rows. Fine while Fly is small;
// when it grows, move search to Meilisearch/Typesense (see AI_CONTEXT).
const SEARCH_MAX_GRAMS = 24;
const SEARCH_CANDIDATES = 80;
const SEARCH_RESULTS = 20;
const SEARCH_SHORT_SCAN_POSTS = 3000;

// How many of [n] pieces a result must contain to count as a match.
function searchNeeded(n) {
  if (n <= 2) return n;
  if (n === 3) return 2;
  return Math.ceil(n * 0.5);
}

// Ranks candidate rows [{id, text, at}] for query [v] and its [grams].
function searchRank(rows, v, grams) {
  const need = searchNeeded(grams.length);
  const scored = [];
  for (const r of rows) {
    const text = r.text;
    let hits = 0;
    for (const g of grams) if (text.includes(g)) hits++;
    if (hits < need) continue;
    const score = hits + (text.includes(v) ? grams.length + 1 : 0)
      + (text.startsWith(v) ? 1 : 0);
    scored.push({ id: r.id, score, at: r.at });
  }
  return scored;
}

function searchEscapeLike(text) {
  return text.replace(/[\\%_]/g, '\\$&');
}

async function handleSearch(body, env) {
  if (!env.SEARCH_DB) return jsonResponse({ error: 'search not set up' }, 503);
  const q = cleanSearchText(body.q);
  if (!q) return jsonResponse({ users: [], posts: [] });

  try {
    await ensureSearchSchema(env);
    const db = env.SEARCH_DB;
    const variants = [...new Set(searchQueryVariants(q).filter((x) => x))];
    const userScores = new Map();
    const postScores = new Map();
    const keep = (map, list) => {
      for (const r of list) {
        const old = map.get(r.id);
        if (!old || r.score > old.score) map.set(r.id, r);
      }
    };

    for (const v of variants) {
      if ([...v].length >= 3) {
        const grams = mmTrigrams(v).slice(0, SEARCH_MAX_GRAMS);
        if (!grams.length) continue;
        const match = grams.map(ftsPhrase).join(' OR ');
        const [userRows, postRows] = await db.batch([
          db.prepare(
            `SELECT u.uid AS id, u.name AS text, u.updated_at AS at
             FROM users_fts f JOIN users u ON u.rowid = f.rowid
             WHERE users_fts MATCH ?1 ORDER BY f.rank LIMIT ?2`,
          ).bind(match, SEARCH_CANDIDATES),
          db.prepare(
            `SELECT p.post_id AS id, (p.caption || ' ' || p.tags) AS text,
                    p.created_at AS at
             FROM posts_fts f JOIN posts p ON p.rowid = f.rowid
             WHERE posts_fts MATCH ?1 ORDER BY f.rank LIMIT ?2`,
          ).bind(match, SEARCH_CANDIDATES),
        ]);
        keep(userScores, searchRank(userRows.results || [], v, grams));
        keep(postScores, searchRank(postRows.results || [], v, grams));
      } else {
        const like = searchEscapeLike(v);
        const [userRows, postRows] = await db.batch([
          db.prepare(
            `SELECT uid AS id FROM users WHERE name LIKE ?1 ESCAPE '\\'
             ORDER BY name COLLATE NOCASE LIMIT ?2`,
          ).bind(`${like}%`, SEARCH_RESULTS),
          db.prepare(
            `SELECT post_id AS id, created_at AS at FROM (
               SELECT post_id, caption, tags, created_at FROM posts
               ORDER BY created_at DESC LIMIT ?3)
             WHERE (' ' || tags) LIKE ?1 ESCAPE '\\'
                OR caption LIKE ?2 ESCAPE '\\'
             ORDER BY created_at DESC LIMIT ?4`,
          ).bind(`% ${like}%`, `%${like}%`, SEARCH_SHORT_SCAN_POSTS, SEARCH_RESULTS),
        ]);
        keep(userScores, (userRows.results || []).map((r) => ({ id: r.id, score: 1, at: 0 })));
        keep(postScores, (postRows.results || []).map((r) => ({ id: r.id, score: 1, at: r.at })));
      }
    }

    const top = (map) => [...map.values()]
      .sort((a, b) => (b.score - a.score) || (b.at - a.at))
      .slice(0, SEARCH_RESULTS)
      .map((r) => r.id);
    return jsonResponse({ users: top(userScores), posts: top(postScores) });
  } catch (err) {
    return jsonResponse({ error: `search failed: ${err.message}` }, 500);
  }
}

async function handleSearchSyncMe(env, caller) {
  if (!env.SEARCH_DB) return jsonResponse({ skipped: 'search not set up' });
  if (!caller || !isSafeUid(caller.uid)) {
    return jsonResponse({ error: 'sign-in required' }, 401);
  }
  try {
    await ensureSearchSchema(env);
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const fields = await firestoreGetFields(env, dbToken, `users/${caller.uid}`);
    if (fields === null) {
      // Account deleted (profile_screen.dart calls this right after
      // removing users/{uid}): drop my name AND my posts from search.
      await env.SEARCH_DB.batch([
        env.SEARCH_DB.prepare('DELETE FROM users WHERE uid = ?1').bind(caller.uid),
        env.SEARCH_DB.prepare('DELETE FROM posts WHERE owner_id = ?1').bind(caller.uid),
        env.SEARCH_DB.prepare('DELETE FROM search_hits WHERE uid = ?1').bind(caller.uid),
      ]);
      return jsonResponse({ removed: true });
    }
    const result = await searchUserStatement(env, caller.uid, fields).run();
    return jsonResponse({ ok: true, changed: result.meta?.changes || 0 });
  } catch (err) {
    return jsonResponse({ error: `sync failed: ${err.message}` }, 500);
  }
}

// POST /search-index-post {postId} (19 Oct 2026): index my brand-new post
// right away. Everything indexed comes from the Firestore doc itself.
async function handleSearchIndexPost(body, env, caller) {
  if (!env.SEARCH_DB) return jsonResponse({ skipped: 'search not set up' });
  if (!caller || !isSafeUid(caller.uid)) {
    return jsonResponse({ error: 'sign-in required' }, 401);
  }
  const postId = body && body.postId;
  if (!isSafeUid(postId)) return jsonResponse({ error: 'bad post id' }, 400);
  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const fields = await firestoreGetFields(env, dbToken, `posts/${postId}`);
    if (fields === null) return jsonResponse({ skipped: 'no such post' });
    if (stringField(fields, 'userId') !== caller.uid) {
      return jsonResponse({ error: 'not your post' }, 403);
    }
    const failed = fields.videoFailed && fields.videoFailed.booleanValue === true;
    if (failed) return jsonResponse({ skipped: 'video failed' });
    await ensureSearchSchema(env);
    await searchUpsertPost(env, postId, fields);
    return jsonResponse({ ok: true });
  } catch (err) {
    return jsonResponse({ error: `index failed: ${err.message}` }, 500);
  }
}

// ---------------------------------------------------------------------
// Trending on Fly (4 Oct 2026)
// ---------------------------------------------------------------------
// A word trends when DIFFERENT people search it - one person searching
// 100 times still counts once. Raise TRENDING_MIN_PEOPLE as Fly grows
// (2 so Ko can test with two phones).
const TRENDING_MIN_PEOPLE = 2;
const TRENDING_DAYS = 7;
const TRENDING_MAX = 8;
const SEARCH_LOGS_PER_PERSON_PER_DAY = 30;
const TRENDING_CACHE_MS = 10 * 60 * 1000;

let trendingCache = { at: 0, terms: null };

// 'YYYY-MM-DD' (UTC) for [daysAgo] days before today.
function utcDay(daysAgo = 0) {
  return new Date(Date.now() - daysAgo * 86400000).toISOString().slice(0, 10);
}

async function handleSearchLog(body, env, caller) {
  if (!env.SEARCH_DB) return jsonResponse({ skipped: 'search not set up' });
  if (!caller || !isSafeUid(caller.uid)) {
    return jsonResponse({ error: 'sign-in required' }, 401);
  }
  const term = searchCanonicalTerm(cleanSearchText(body.q)).slice(0, 40);
  if ([...term].length < 2) return jsonResponse({ logged: false });

  try {
    await ensureSearchSchema(env);
    const db = env.SEARCH_DB;
    const day = utcDay();
    // ONE statement: counted only if the word finds at least one video and
    // this person hasn't logged too many words today. A repeat is ignored.
    const matchesVideo = [...term].length >= 3
      ? 'EXISTS (SELECT 1 FROM posts_fts WHERE posts_fts MATCH ?5)'
      : `EXISTS (SELECT 1 FROM posts WHERE (' ' || tags) LIKE ?5 ESCAPE '\\')`;
    const matchArg = [...term].length >= 3
      ? ftsPhrase(term)
      : `% ${term.replace(/[\\%_]/g, '\\$&')}%`;
    const result = await db.prepare(
      `INSERT OR IGNORE INTO search_hits (day, term, uid)
       SELECT ?1, ?2, ?3
       WHERE (SELECT COUNT(*) FROM search_hits WHERE uid = ?3 AND day = ?1) < ?4
         AND ${matchesVideo}`,
    ).bind(day, term, caller.uid, SEARCH_LOGS_PER_PERSON_PER_DAY, matchArg).run();

    // Now and then, forget days older than the trending window.
    if (Math.random() < 0.02) {
      await db.prepare('DELETE FROM search_hits WHERE day < ?1')
        .bind(utcDay(TRENDING_DAYS + 1)).run();
    }
    return jsonResponse({ logged: (result.meta?.changes || 0) > 0 });
  } catch (err) {
    return jsonResponse({ error: `log failed: ${err.message}` }, 500);
  }
}

async function handleSearchTrending(env) {
  if (!env.SEARCH_DB) return jsonResponse({ terms: [] });
  const now = Date.now();
  if (trendingCache.terms && now - trendingCache.at < TRENDING_CACHE_MS) {
    return jsonResponse({ terms: trendingCache.terms });
  }
  try {
    await ensureSearchSchema(env);
    const rows = await env.SEARCH_DB.prepare(
      `SELECT term, COUNT(*) AS people, MAX(day) AS last_day
       FROM search_hits WHERE day >= ?1
       GROUP BY term HAVING people >= ?2
       ORDER BY people DESC, last_day DESC LIMIT ?3`,
    ).bind(utcDay(TRENDING_DAYS - 1), TRENDING_MIN_PEOPLE, TRENDING_MAX).all();
    const terms = (rows.results || []).map((r) => r.term);
    trendingCache = { at: now, terms };
    return jsonResponse({ terms });
  } catch (err) {
    return jsonResponse({ error: `trending failed: ${err.message}` }, 500);
  }
}

// GET /search-backfill?token=...&what=users|posts[&page=<token>]
async function handleSearchBackfill(env, url) {
  const html = (body) =>
    new Response(
      `<!doctype html><meta name="viewport" content="width=device-width">` +
        `<body style="font-family:sans-serif;padding:24px;max-width:640px">` +
        `${body}</body>`,
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } },
    );
  const token = url.searchParams.get('token') || '';
  if (!env.SEARCH_ADMIN_TOKEN || token !== env.SEARCH_ADMIN_TOKEN) {
    return new Response('Not allowed', { status: 403 });
  }
  if (!env.SEARCH_DB) return html('<h2>❌ SEARCH_DB binding is missing.</h2>');
  const what = url.searchParams.get('what') === 'posts' ? 'posts' : 'users';
  const pageToken = url.searchParams.get('page') || '';

  try {
    await ensureSearchSchema(env);
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const mask = what === 'users'
      ? ['displayName']
      : ['caption', 'hashtags', 'userId', 'createdAt', 'videoFailed'];
    const params = new URLSearchParams({ pageSize: '40' });
    for (const f of mask) params.append('mask.fieldPaths', f);
    if (pageToken) params.set('pageToken', pageToken);
    const response = await fetch(`${firestoreBase(env)}/${what}?${params}`, {
      headers: { Authorization: `Bearer ${dbToken}` },
    });
    if (!response.ok) {
      throw new Error(`Firestore list failed: ${await response.text()}`);
    }
    const data = await response.json();
    const docs = data.documents || [];
    const statements = [];
    for (const doc of docs) {
      const id = docIdFromName(doc.name);
      const fields = doc.fields || {};
      if (what === 'users') {
        statements.push(searchUserStatement(env, id, fields));
      } else if (!(fields.videoFailed && fields.videoFailed.booleanValue)) {
        statements.push(searchPostStatement(env, id, fields));
      }
    }
    if (statements.length) await env.SEARCH_DB.batch(statements);

    const counts = await env.SEARCH_DB.batch([
      env.SEARCH_DB.prepare('SELECT COUNT(*) AS n FROM users'),
      env.SEARCH_DB.prepare('SELECT COUNT(*) AS n FROM posts'),
    ]);
    const nUsers = counts[0].results[0].n;
    const nPosts = counts[1].results[0].n;
    const summary =
      `<p>This page: ${docs.length} ${what}.</p>` +
      `<p>In search now: <b>${nUsers}</b> users, <b>${nPosts}</b> posts.</p>`;

    if (data.nextPageToken) {
      const next = new URLSearchParams({ token, what, page: data.nextPageToken });
      return html(
        `<h2>⏳ Copying ${what}...</h2>${summary}` +
          `<p><a style="font-size:20px" href="/search-backfill?${next}">` +
          `Next page →</a></p>`,
      );
    }
    const nextStep = what === 'users'
      ? `<p><a style="font-size:20px" href="/search-backfill?${new URLSearchParams({ token, what: 'posts' })}">Now copy posts →</a></p>`
      : '<h3>🎉 All done.</h3>';
    return html(`<h2>✅ ${what} done</h2>${summary}${nextStep}`);
  } catch (err) {
    return html(`<h2>❌ Error</h2><pre>${String(err.message)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')}</pre>`);
  }
}

// ---------------------------------------------------------------------
// "Who can watch" backfill (25 Oct 2026): GET /posts-audience-backfill
// ---------------------------------------------------------------------
// Same idea as /search-backfill: protected by SEARCH_ADMIN_TOKEN, 40 posts
// per page, a "Next page" link until done. A post that already has an
// audience is left alone, so running it twice is harmless.
// 40, not more: the free Workers plan allows 50 subrequests per request
// (1 Google token + 1 list + up to 40 writes). On 25 Oct 2026 a 100-post
// page stopped half-way on prod; opening the page again finished it.
async function handlePostsAudienceBackfill(env, url) {
  const html = (body) =>
    new Response(
      `<!doctype html><meta name="viewport" content="width=device-width">` +
        `<body style="font-family:sans-serif;padding:24px;max-width:640px">` +
        `${body}</body>`,
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } },
    );
  const token = url.searchParams.get('token') || '';
  if (!env.SEARCH_ADMIN_TOKEN || token !== env.SEARCH_ADMIN_TOKEN) {
    return new Response('Not allowed', { status: 403 });
  }
  const pageToken = url.searchParams.get('page') || '';
  const doneSoFar = Number(url.searchParams.get('done') || '0') || 0;
  const seenSoFar = Number(url.searchParams.get('seen') || '0') || 0;

  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const params = new URLSearchParams({ pageSize: '40' });
    params.append('mask.fieldPaths', 'audience');
    if (pageToken) params.set('pageToken', pageToken);
    const response = await fetch(`${firestoreBase(env)}/posts?${params}`, {
      headers: { Authorization: `Bearer ${dbToken}` },
    });
    if (!response.ok) {
      throw new Error(`Firestore list failed: ${await response.text()}`);
    }
    const data = await response.json();
    const docs = data.documents || [];
    const missing = docs.filter(
      (d) => !(d.fields && d.fields.audience && d.fields.audience.stringValue),
    );
    // 10 at a time - gentle on Firestore and on the Worker's subrequests.
    for (let i = 0; i < missing.length; i += 10) {
      await Promise.all(missing.slice(i, i + 10).map((d) =>
        firestorePatchByName(dbToken, d.name, { audience: 'everyone' })));
    }
    const done = doneSoFar + missing.length;
    const seen = seenSoFar + docs.length;
    const summary =
      `<p>Project: <b>${env.FIREBASE_PROJECT_ID}</b></p>` +
      `<p>Posts checked: <b>${seen}</b> · set to Everyone: <b>${done}</b></p>`;
    if (data.nextPageToken) {
      const next = new URLSearchParams({
        token, page: data.nextPageToken, done: String(done), seen: String(seen),
      });
      return html(
        `<h2>⏳ Working...</h2>${summary}` +
          `<p><a style="font-size:20px" href="/posts-audience-backfill?${next}">` +
          `Next page →</a></p>`,
      );
    }
    return html(`<h2>🎉 All done</h2>${summary}`);
  } catch (err) {
    return html(`<h2>❌ Error</h2><pre>${String(err.message)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')}</pre>`);
  }
}

// ---------------------------------------------------------------------
// Text moderation (21 Oct 2026): POST /moderate-text
// ---------------------------------------------------------------------
// The app asks here BEFORE it saves text that other people will see:
// names, Sky Notes, captions (hashtags come from the caption) + text
// stickers on a video, video comments / replies, live comments and live
// titles (lib/screens/moderation_service.dart). Chat messages are NOT
// checked - they are private between friends; Report handles them.
//
// Body {text, kind}; kind = name | skynote | caption | comment |
// live_comment | live_title (anything else counts as 'comment').
// Answer {ok: true} or {ok: false, reason}: 'language' (a bad word),
// 'spam' (Telegram/WhatsApp/short links, "free money"...) or 'reserved'
// (a name pretending to be Fly staff). Only a yes/no + reason comes back -
// never WHICH word matched - so nobody can use it to probe the list.
//
// Why on the Worker and not only on the phone: the Worker converts
// Zawgyi -> Unicode (Myanmar text tools above), so a word typed in
// Zawgyi, with spaces / dots / emoji between the letters, zero-width
// characters, "fancy" letters (ｆｕｃｋ), leetspeak (sh1t, f*ck) or
// stretched letters (fuuuuck) still matches - and the list grows with a
// Worker deploy, no new APK. Cloudflare never "sleeps" (unlike the free
// Render server), so the app can wait for this answer (~0.2 s).
//
// Matching rules (made so normal words are NOT blocked - "spicy",
// "Scunthorpe", "Dickson", ကုလားထိုင် = chair, သူကလား = "is it him?"):
//  - English is checked per WORD, never "anywhere in the text":
//      MOD_EN_ANYWHERE - inside any word (motherfucker, fuckingg);
//      MOD_EN_PREFIX   - a word that starts with it (bitches, shitty);
//      MOD_EN_EXACT    - the word itself, or + s/es/ed/er/ers/ing
//                        (dick, dicks - but never dickson). Words whose
//                        endings make normal words ("spic" -> spicy,
//                        spiced, spices) are left out on purpose;
//      MOD_EN_SQUEEZED - also found with ALL spaces/symbols removed
//                        (f u c k, f-u-c-k, fu ck); only long, unambiguous
//                        words go here ("fish it" contains "shit"!);
//      MOD_EN_PHRASES  - whole words in a row ("kill yourself").
//  - Burmese has no spaces between words, so a Burmese entry is found
//    anywhere in the text after every non-Burmese character between the
//    letters is removed - BUT only when the match ends on a syllable
//    boundary (ကောင် must not match inside ကောင်း) and is not part of a
//    phrase in MOD_MY_ALLOW.
//
// AI layer (21 Oct 2026): text that passes the word lists is sent to
// OpenAI's omni-moderation model (free, 40+ languages, understands
// meaning - threats and hate without swear words too). It needs the
// Worker secret OPENAI_API_KEY; without it, or when OpenAI is slow
// (> MOD_AI_TIMEOUT_MS), busy (429) or down, the word lists' answer
// stands - the app never gets stuck because of OpenAI. Short texts
// ("ok", "😍😍") skip the AI. The same text is answered from a small
// in-memory cache for a while. Self-harm categories are NOT blocked
// (blocking someone who is struggling helps nobody; showing help is a
// later idea). Swap the provider here if Fly outgrows the free limits -
// the app only knows /moderate-text.
//
// Ko: add words from real reports (Firestore `reports`). Type Burmese
// entries normally in Unicode - they are tidied when the Worker starts.
// Keep each Burmese entry a whole insult, not a short syllable that is
// also part of normal words. After editing: deploy BOTH Workers.
const MOD_KINDS = new Set([
  'name', 'skynote', 'caption', 'comment', 'live_comment', 'live_title',
]);
const MOD_MAX_CHARS = 5000;

const MOD_EN_ANYWHERE = [
  'fuck', 'nigger', 'nigga', 'faggot', 'motherfuck', 'cocksuck', 'shit',
];
const MOD_EN_PREFIX = [
  'bitch', 'cunt', 'whore', 'slut', 'bastard', 'asshole', 'dickhead',
  'wanker', 'twat', 'porn',
];
const MOD_EN_EXACT = [
  'fuk', 'fuq', 'fck', 'fcuk', 'dick', 'pussy', 'dumbass', 'jackass',
  'chink', 'fag', 'retard', 'kys', 'kalar',
];
const MOD_EN_SQUEEZED = [
  'fuck', 'nigger', 'nigga', 'faggot', 'motherfuck', 'cocksuck',
];
const MOD_EN_PHRASES = [
  'kill yourself', 'kill urself', 'kill your self', 'go die',
  'send nudes', 'free money', 'click here to win',
];
const MOD_EN_SUFFIXES = ['', 's', 'es', 'ed', 'er', 'ers', 'ing'];

// Burmese insults / slurs (Unicode). A starting list - Ko adds more.
const MOD_MY_BLOCK = [
  'လီး',          // vulgar (penis) - the most common swear
  'လိုး',          // vulgar (fuck) - covers မအေလိုး, ငါလိုးမ ...
  'စောက်',        // vulgar prefix - covers စောက်ရူး, စောက်ပိုး ...
  'သောက်ရူး',     // "softened" spellings of the above
  'သောက်ပိုး',
  'သောက်ကောင်',
  'ခွေးမသား',     // son of a bitch
  'ခွေးကောင်',    // "dog" (as an insult)
  'ကုလား',        // ethnic / religious slur
  'ဖာသည်',        // prostitute (as an insult)
  'ဖာသေမ',
  'ဖင်ခံ',         // anti-gay slur
  // Threats (21 Oct 2026) - OpenAI's AI does not catch Burmese threats.
  // Only with "you" in front (မင်း/နင်/ညည်း ...ကို), so news like
  // "...ကို သတ်ခံရ" or "ခြင်တွေကို သတ်ပစ်မယ်" (mosquitoes) still pass.
  // Spaces between the words don't matter (they are squeezed out).
  'မင်းကိုသတ်',   // covers မင်းကို သတ်ပစ်မယ် / သတ်မယ် / သတ်မှာ
  'နင့်ကိုသတ်',
  'နင်ကိုသတ်',
  'ညည်းကိုသတ်',
  'မင်းတို့ကိုသတ်',
  'နင်တို့ကိုသတ်',
  'မင်းကိုရိုက်သတ်',
  'နင့်ကိုရိုက်သတ်',
  'မင်းသေပြီ',    // "you're dead"
  'နင်သေပြီ',
  'မင်းသေမယ်',
  'နင်သေမယ်',
];
// Normal words that CONTAIN a blocked entry - never blocked.
const MOD_MY_ALLOW = [
  'ကုလားထိုင်',   // chair
  'ကုလားပဲ',      // chickpea
  'ကုလားအုတ်',    // camel
  'ကုလားကာ',      // curtain
  'မတ်စောက်',     // steep
  'တောင်စောက်',   // steep (hillside)
];

const MOD_SPAM_LINK =
  /(^|[^a-z0-9])(t\.me|telegram\.me|telegram\.dog|wa\.me|chat\.whatsapp\.com|bit\.ly|tinyurl\.com|cutt\.ly)([^a-z0-9]|$)/;
const MOD_NAME_URL =
  /(https?:\/\/|www\.|\.(com|net|org|io|me|ly|xyz|link|site|shop|club|info|biz|app)([^a-z]|$))/;
const MOD_RESERVED_WORDS = ['admin', 'administrator', 'moderator'];
const MOD_RESERVED_SQUEEZED = [
  'flyofficial', 'officialfly', 'flyteam', 'teamfly', 'flysupport',
  'flystaff', 'flyadmin',
];
const MOD_LEET = {
  '@': 'a', '4': 'a', '3': 'e', '1': 'i', '!': 'i', '|': 'i', '0': 'o',
  '$': 's', '5': 's', '7': 't',
};

let modMyLists = null;

// Burmese entries tidied the same way as the text (once per Worker start).
function modMyanmarLists() {
  if (!modMyLists) {
    const squeeze = (w) => modMyanmarSqueeze(mmTidy(w));
    // An allowed phrase is also kept in its "read as Zawgyi" form, so the
    // converted reading of a Unicode text (below) still finds it.
    const allow = new Set();
    for (const a of MOD_MY_ALLOW) {
      allow.add(squeeze(a));
      allow.add(modMyanmarSqueeze(mmTidy(zawgyiToUnicode(a))));
    }
    allow.delete('');
    modMyLists = {
      block: MOD_MY_BLOCK.map(squeeze).filter(Boolean),
      allow: Array.from(allow),
    };
  }
  return modMyLists;
}

// Keeps Burmese letters/marks only. A run of Latin letters becomes '|'
// (a hard break); spaces, dots, digits, emoji... vanish, so
// "ခွေး . ကောင်" is read as "ခွေးကောင်".
function modMyanmarSqueeze(text) {
  return String(text || '')
    .replace(/[a-z]+/g, '|')
    .replace(/[^က-႟ꩠ-ꩿꧠ-꧿|]/g, '');
}

function modMyanmarAllowed(s, start, length, allow) {
  for (const a of allow) {
    let from = 0;
    for (;;) {
      const i = s.indexOf(a, from);
      if (i < 0) break;
      if (i <= start && start + length <= i + a.length) return true;
      from = i + 1;
    }
  }
  return false;
}

function modMyanmarBlocked(raw) {
  if (!/[\u1000-\u109f\uaa60-\uaa7f\ua9e0-\ua9ff]/.test(raw)) return false;
  const { block, allow } = modMyanmarLists();
  // The text as typed is always checked. Unless the detector is sure it
  // is Unicode, the "converted from Zawgyi" reading is checked TOO - the
  // detector is often wrong on short text (Unicode "မအေလိုး" scores 0.99
  // "Zawgyi"), and for blocking it is safer to look twice.
  const readings = [modMyanmarSqueeze(mmTidy(raw))];
  if (zawgyiProbability(raw) > 0.1) {
    readings.push(modMyanmarSqueeze(mmTidy(zawgyiToUnicode(raw))));
  }
  for (const bad of block) {
    // Per reading: does the word appear as an insult (uncovered) and/or
    // only inside an allowed phrase (covered)?
    let uncovered = false;
    let onlyCoveredSomewhere = false;
    for (const s of readings) {
      let found = false;
      let free = false;
      let from = 0;
      for (;;) {
        const i = s.indexOf(bad, from);
        if (i < 0) break;
        from = i + 1;
        // The syllable goes on (a vowel/medial/final mark follows), e.g.
        // ကောင် inside ကောင်း - not this word.
        if (/[\u102b-\u103e]/.test(s[i + bad.length] || '')) continue;
        // Starts on a stacked (subscript) consonant - not a word start.
        if (i > 0 && s[i - 1] === '\u1039') continue;
        found = true;
        if (!modMyanmarAllowed(s, i, bad.length, allow)) free = true;
      }
      if (free) uncovered = true;
      else if (found) onlyCoveredSomewhere = true;
    }
    // A Zawgyi "ကုလားထိုင္" (chair) looks like the slur when read as
    // typed, but is clearly the allowed word in its converted reading -
    // one reading that explains every match as a normal word wins.
    if (uncovered && !onlyCoveredSomewhere) return true;
  }
  return false;
}

// Latin text -> words (null = a number-only token, i.e. a break).
function modLatinWords(lower) {
  return lower
    .split(/[^a-z0-9@$!|*]+/)
    .filter(Boolean)
    .map((t) => {
      if (!/[a-z]/.test(t)) return null;
      return Array.from(t).map((c) => MOD_LEET[c] || c).join('').replace(/\*/g, '');
    });
}

// A word plus its "stretched letters" readings: fuuuuck -> fuck, and
// asssshole -> asshole (3+ of the same letter -> 1 and -> 2).
function modWordVariants(w) {
  const out = new Set([w]);
  out.add(w.replace(/(.)\1{2,}/g, '$1'));
  out.add(w.replace(/(.)\1{2,}/g, '$1$1'));
  return out;
}

function modWordBlocked(word) {
  for (const w of modWordVariants(word)) {
    for (const x of MOD_EN_ANYWHERE) if (w.includes(x)) return true;
    for (const x of MOD_EN_PREFIX) if (w.startsWith(x)) return true;
    for (const x of MOD_EN_EXACT) {
      for (const sfx of MOD_EN_SUFFIXES) if (w === x + sfx) return true;
    }
  }
  return false;
}

// Returns null (fine) or the reason the text is refused.
function moderateText(text, kind) {
  const raw = String(text || '').slice(0, MOD_MAX_CHARS);
  if (!raw.trim()) return null;

  // Fancy letters -> plain (ｆｕｃｋ, 𝐟𝐮𝐜𝐤), lower case, no zero-width
  // characters, accents off Latin letters (fück -> fuck).
  const lower = raw
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[​-‍⁠﻿]/g, '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .normalize('NFC');
  const noSpaces = lower.replace(/\s+/g, '');
  // "t . me / x" -> "t.me/x" (spaces around dots and slashes dropped).
  const linkText = lower.replace(/\s*([./])\s*/g, '$1');

  // ---- spam / off-app links (every kind) ----
  if (MOD_SPAM_LINK.test(linkText)) return 'spam';

  // ---- English words ----
  const words = modLatinWords(lower);
  const plain = words.filter(Boolean);
  for (const w of plain) {
    if (modWordBlocked(w)) return 'language';
  }
  // Letters typed one by one: "f u c k", "s.h.i.t".
  let run = '';
  for (const w of [...words, null]) {
    if (w && w.length === 1) {
      run += w;
      continue;
    }
    if (run.length >= 3 && modWordBlocked(run)) return 'language';
    run = '';
  }
  const squeezed = plain.join('');
  for (const x of MOD_EN_SQUEEZED) {
    for (const v of modWordVariants(squeezed)) {
      if (v.includes(x)) return 'language';
    }
  }
  const sentence = ` ${plain.join(' ')} `;
  for (const p of MOD_EN_PHRASES) {
    if (sentence.includes(` ${p} `)) return 'language';
  }

  // ---- Burmese (Zawgyi or Unicode) ----
  if (modMyanmarBlocked(raw)) return 'language';

  // ---- names only ----
  if (kind === 'name') {
    if (MOD_NAME_URL.test(noSpaces)) return 'spam';
    if (/\d{8,}/.test(lower.replace(/[\s\-().+]/g, ''))) return 'spam';
    for (const w of plain) {
      if (MOD_RESERVED_WORDS.includes(w)) return 'reserved';
    }
    for (const x of MOD_RESERVED_SQUEEZED) {
      if (squeezed.includes(x)) return 'reserved';
    }
    if (squeezed === 'fly') return 'reserved';
  }
  return null;
}

// ---- AI layer (OpenAI omni-moderation) ----
const MOD_AI_URL = 'https://api.openai.com/v1/moderations';
const MOD_AI_MODEL = 'omni-moderation-latest';
const MOD_AI_TIMEOUT_MS = 3500;
const MOD_AI_MAX_CHARS = 2000;
// Categories that block when OpenAI flags them.
const MOD_AI_BLOCK = [
  'harassment', 'harassment/threatening', 'hate', 'hate/threatening',
  'sexual', 'sexual/minors', 'violence/graphic', 'illicit/violent',
];
// Plain "violence" also matches harmless things (a fight scene in a
// movie caption), so it only blocks with a high score.
const MOD_AI_VIOLENCE_SCORE = 0.8;
const MOD_AI_CACHE_MAX = 500;
const MOD_AI_CACHE_MS = 30 * 60 * 1000;
const modAiCache = new Map(); // text -> { blocked, at }

// Worth asking the AI: at least 3 letters (of any script) in total.
function modAiWorthChecking(text) {
  const letters = String(text).match(/\p{L}/gu);
  return !!letters && letters.length >= 3;
}

// true = blocked, false = fine, null = no answer (no key / error /
// timeout / rate limit) - then the word lists decide.
async function modAiBlocked(text, env) {
  if (!env.OPENAI_API_KEY) return null;
  const input = String(text).slice(0, MOD_AI_MAX_CHARS);
  if (!modAiWorthChecking(input)) return false;

  const cached = modAiCache.get(input);
  if (cached && Date.now() - cached.at < MOD_AI_CACHE_MS) {
    return cached.blocked;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MOD_AI_TIMEOUT_MS);
  try {
    const res = await fetch(MOD_AI_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ model: MOD_AI_MODEL, input }),
      signal: controller.signal,
    });
    if (!res.ok) {
      // 429 = free daily limit reached; 401 = bad key. Visible with
      // `npx wrangler tail` / Cloudflare -> Logs.
      console.log('moderate-text: OpenAI HTTP', res.status,
        (await res.text()).slice(0, 200));
      return null;
    }
    const data = await res.json();
    const result = data?.results?.[0];
    if (!result) return null;
    const flags = result.categories || {};
    const scores = result.category_scores || {};
    const blocked =
      MOD_AI_BLOCK.some((c) => flags[c] === true) ||
      (scores.violence || 0) >= MOD_AI_VIOLENCE_SCORE;

    if (modAiCache.size >= MOD_AI_CACHE_MAX) {
      modAiCache.delete(modAiCache.keys().next().value);
    }
    modAiCache.set(input, { blocked, at: Date.now() });
    return blocked;
  } catch (err) {
    console.log('moderate-text: OpenAI error', err.name, err.message);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// ---- Images (21 Oct 2026): POST /moderate-image ----
// OpenAI checks images for sexual content, violence and self-harm only
// (hate/harassment/"sexual/minors" are text-only categories there).
// One request per image (the docs don't promise several images in one
// request), all in parallel. A plain "violence" score (an action-movie
// scene) only blocks when very high; graphic violence blocks when flagged.
// 22 Oct 2026 (Ko: "sexual videos/photos must NOT get in"): up to 16
// frames per video, sent 4 at a time (gentler on OpenAI's free limits),
// and "sexual" blocks already at a moderate score, not only when OpenAI
// itself flags it. Raise MOD_IMG_SEXUAL_SCORE if normal photos (beach,
// gym) get refused too often; lower it to be even stricter.
const MOD_IMG_MAX_COUNT = 16;
const MOD_IMG_PARALLEL = 4;
const MOD_IMG_MAX_B64 = 2 * 1024 * 1024; // ~1.5 MB per image
const MOD_IMG_TIMEOUT_MS = 9000;
const MOD_IMG_VIOLENCE_SCORE = 0.85;
const MOD_IMG_SEXUAL_SCORE = 0.4;

function modImageMime(b64) {
  if (b64.startsWith('/9j/')) return 'image/jpeg';
  if (b64.startsWith('iVBOR')) return 'image/png';
  if (b64.startsWith('UklGR')) return 'image/webp';
  return null;
}

// OpenAI's raw answer for one image ({categories, category_scores}), or
// undefined = no answer (error / timeout / rate limit / image not
// reachable). [imageUrl] is a data: URL (pictures sent by the phone) or
// an https URL OpenAI downloads itself (Bunny frames, see
// modCheckBunnyVideo - no base64 work in the Worker).
async function modImageResult(imageUrl, env) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MOD_IMG_TIMEOUT_MS);
  try {
    const res = await fetch(MOD_AI_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: MOD_AI_MODEL,
        input: [{ type: 'image_url', image_url: { url: imageUrl } }],
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.log('moderate-image: OpenAI HTTP', res.status,
        (await res.text()).slice(0, 200));
      return undefined;
    }
    const data = await res.json();
    return data?.results?.[0] || undefined;
  } catch (err) {
    console.log('moderate-image: OpenAI error', err.name, err.message);
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

// 'nudity' | 'violence' | 'self_harm' = blocked, null = fine,
// undefined = no answer.
function modImageVerdictOf(result) {
  if (!result) return undefined;
  const f = result.categories || {};
  const sc = result.category_scores || {};
  if (f.sexual === true || (sc.sexual || 0) >= MOD_IMG_SEXUAL_SCORE) {
    return 'nudity';
  }
  if (f['self-harm'] === true || f['self-harm/intent'] === true ||
      f['self-harm/instructions'] === true) return 'self_harm';
  if (f['violence/graphic'] === true ||
      (sc.violence || 0) >= MOD_IMG_VIOLENCE_SCORE) return 'violence';
  return null;
}

async function modImageVerdict(b64, env) {
  const mime = modImageMime(b64);
  if (!mime) return undefined;
  return modImageVerdictOf(
    await modImageResult(`data:${mime};base64,${b64}`, env));
}

// ---- Server-side video re-check (25 Oct 2026) ----
// The phone checks a video's frames BEFORE uploading (checkVideo in
// moderation_service.dart), but a modified app could skip that. So when
// Bunny says a video has FINISHED encoding (webhook status 3), the Worker
// checks it again from Bunny's own pictures of it:
//   - the "seek" sprite sheets Bunny makes for the player's scrub bar
//     (seek/_0.jpg, _1.jpg... each a 6x6 grid of frames, one frame every
//     2 s - every 1 s under 10 s - so one sheet covers ~72 s), and
//   - the cover thumbnail.
// OpenAI downloads them straight from the Bunny CDN (BUNNY_CDN_HOSTNAME).
// If any picture is refused, the post / story is DELETED, the Bunny video
// is deleted, it leaves Search, and the case is logged in
// moderationActions/{videoGuid} (no client can read or write it). If the
// check can't run (OpenAI down, images not reachable) nothing is removed -
// the phone already checked it; videoStatus gets modChecked: false.
// Test it without removing anything: GET /moderation-video-test.
const MOD_VIDEO_MAX_SHEETS = 8;

// Image URLs to check for one Bunny video, or null if Bunny can't say.
async function modBunnyVideoImageUrls(env, videoGuid) {
  const res = await fetch(
    `https://video.bunnycdn.com/library/${env.BUNNY_LIBRARY_ID}/videos/${videoGuid}`,
    { headers: { AccessKey: env.BUNNY_API_KEY, Accept: 'application/json' } },
  );
  if (!res.ok) return null;
  const video = await res.json();
  const seconds = Math.max(1, Number(video.length) || 1);
  const step = seconds < 10 ? 1 : 2;
  const sheets = Math.max(1, Math.ceil(seconds / step / 36));
  // Long videos: spread MOD_VIDEO_MAX_SHEETS sheets evenly over them.
  const picked = new Set();
  const n = Math.min(sheets, MOD_VIDEO_MAX_SHEETS);
  for (let i = 0; i < n; i++) {
    picked.add(n === 1 ? 0 : Math.round((i * (sheets - 1)) / (n - 1)));
  }
  const base = `https://${env.BUNNY_CDN_HOSTNAME}/${videoGuid}`;
  const urls = [...picked].sort((a, b) => a - b)
    .map((i) => `${base}/seek/_${i}.jpg`);
  urls.push(`${base}/${video.thumbnailFileName || 'thumbnail.jpg'}`);
  return urls;
}

// { reason: 'nudity'|'violence'|'self_harm'|null, checked: bool, items }
async function modCheckBunnyVideo(env, videoGuid) {
  if (!env.OPENAI_API_KEY || !env.BUNNY_CDN_HOSTNAME) {
    return { reason: null, checked: false, items: [] };
  }
  const urls = await modBunnyVideoImageUrls(env, videoGuid);
  if (!urls) return { reason: null, checked: false, items: [] };
  const results = await Promise.all(urls.map((u) => modImageResult(u, env)));
  const items = urls.map((url, i) => ({
    url,
    result: results[i],
    verdict: modImageVerdictOf(results[i]),
  }));
  const blocked = items.find((x) => typeof x.verdict === 'string');
  return {
    reason: blocked ? blocked.verdict : null,
    checked: items.every((x) => x.verdict !== undefined),
    items,
  };
}

// Removes everything that shows a refused video. Best-effort per step.
async function modRemoveBunnyVideo(env, accessToken, videoGuid, reason) {
  const removed = [];
  let ownerId = '';
  for (const collection of ['posts', 'stories']) {
    let names = [];
    try {
      names = await firestoreFindByField(
        env, accessToken, collection, 'bunnyVideoId', videoGuid);
    } catch (_) {}
    for (const name of names) {
      try {
        const doc = await firestoreGetByName(accessToken, name);
        if (doc && doc.fields && !ownerId) ownerId = fsString(doc.fields, 'userId');
      } catch (_) {}
      try {
        await fetch(`https://firestore.googleapis.com/v1/${name}`, {
          method: 'DELETE',
          headers: { Authorization: `Bearer ${accessToken}` },
        });
        removed.push(`${collection}/${docIdFromName(name)}`);
      } catch (_) {}
      if (collection === 'posts' && env.SEARCH_DB) {
        try {
          await env.SEARCH_DB.prepare('DELETE FROM posts WHERE post_id = ?1')
            .bind(docIdFromName(name)).run();
        } catch (_) {}
      }
    }
  }
  await deleteBunnyVideo(env, videoGuid);
  try {
    await firestorePatch(env, accessToken, `moderationActions/${videoGuid}`, {
      kind: 'video',
      source: 'bunny-webhook',
      reason,
      videoGuid,
      userId: ownerId,
      removed: removed.join(', '),
      createdAt: new Date(),
    });
  } catch (_) {}
  console.log('video re-check: removed', videoGuid, reason, removed.join(', '));
}

// GET /moderation-video-test?token=SEARCH_ADMIN_TOKEN&video=<Bunny video ID>
// Shows what the server-side re-check sees for one video and its scores.
// Removes NOTHING - only for Ko to check that it works.
async function handleModerationVideoTest(env, url) {
  const html = (body) => new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<body style="font-family:sans-serif;padding:16px;max-width:760px;margin:auto">${body}</body>`,
    { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } },
  );
  const token = url.searchParams.get('token');
  if (!env.SEARCH_ADMIN_TOKEN || token !== env.SEARCH_ADMIN_TOKEN) {
    return html('<h2>❌ Wrong or missing token.</h2>');
  }
  const videoGuid = String(url.searchParams.get('video') || '').trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(videoGuid)) {
    return html('<h2>Add &amp;video=VIDEO_ID (the Bunny Stream video ID) to the link.</h2>');
  }
  if (!env.BUNNY_CDN_HOSTNAME) {
    return html('<h2>❌ BUNNY_CDN_HOSTNAME is not set on this Worker.</h2>');
  }
  if (!env.OPENAI_API_KEY) return html('<h2>❌ OPENAI_API_KEY is not set.</h2>');
  // &remove=1 : runs the REAL removal on this video, as if it had been
  // refused (deletes its post / story, the Bunny video and the Search row,
  // logs it with reason 'test'). For testing with a harmless video - no
  // bad video is ever needed. Cannot be undone.
  if (url.searchParams.get('remove') === '1') {
    const accessToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    await firestorePatch(env, accessToken, `videoStatus/${videoGuid}`, {
      ready: false,
      failed: true,
      blocked: true,
      blockReason: 'test',
      modChecked: true,
      updatedAt: new Date(),
    });
    await modRemoveBunnyVideo(env, accessToken, videoGuid, 'test');
    return html(`<h2>🗑️ Removed as a test</h2><p>Project: <b>${env.FIREBASE_PROJECT_ID}</b> · Video: ${videoGuid}</p>` +
      '<p>Its post / story, the Bunny video and the Search row were deleted, and it was logged in <b>moderationActions</b> (reason: test).</p>');
  }
  const r = await modCheckBunnyVideo(env, videoGuid);
  if (r.items.length === 0) {
    return html('<h2>❌ Bunny did not return this video (wrong ID, or another library?).</h2>');
  }
  const pct = (v) => `${Math.round((v || 0) * 100)}%`;
  const rows = r.items.map((x) => {
    const sc = x.result?.category_scores || {};
    const v = x.verdict === undefined ? '⚠️ no answer'
      : x.verdict === null ? '✅ ok' : `⛔ ${x.verdict}`;
    return `<tr><td><a href="${x.url}">${x.url.split('/').slice(-2).join('/')}</a></td>` +
      `<td>${pct(sc.sexual)}</td><td>${pct(sc.violence)}</td><td>${v}</td></tr>`;
  }).join('');
  const head = r.reason ? `<h2>⛔ Would be REMOVED (${r.reason})</h2>`
    : r.checked ? '<h2>✅ Passes the check</h2>'
      : '<h2>⚠️ Could not check every picture</h2>';
  return html(`${head}<p>Project: <b>${env.FIREBASE_PROJECT_ID}</b> · Video: ${videoGuid}</p>` +
    `<p>Blocks at sexual ≥ ${pct(MOD_IMG_SEXUAL_SCORE)} or violence ≥ ${pct(MOD_IMG_VIOLENCE_SCORE)}. Nothing was removed.</p>` +
    `<table border="1" cellpadding="6" style="border-collapse:collapse"><tr><th>Picture</th><th>Sexual</th><th>Violence</th><th>Result</th></tr>${rows}</table>`);
}

async function handleModerateImage(body, env) {
  const images = Array.isArray(body?.images)
    ? body.images.filter((x) => typeof x === 'string' && x.length > 0)
    : [];
  if (images.length === 0) return jsonResponse({ ok: true, checked: true });
  if (images.length > MOD_IMG_MAX_COUNT ||
      images.some((x) => x.length > MOD_IMG_MAX_B64)) {
    return jsonResponse({ error: 'too many or too large images' }, 400);
  }
  if (!env.OPENAI_API_KEY) return jsonResponse({ ok: true, checked: false });

  // A few at a time; stop at the first refused frame.
  const verdicts = [];
  for (let i = 0; i < images.length; i += MOD_IMG_PARALLEL) {
    const batch = await Promise.all(images.slice(i, i + MOD_IMG_PARALLEL)
      .map((b64) => modImageVerdict(b64, env)));
    const reason = batch.find((v) => typeof v === 'string');
    if (reason) return jsonResponse({ ok: false, reason });
    verdicts.push(...batch);
  }
  const checked = verdicts.every((v) => v === null);
  return jsonResponse({ ok: true, checked });
}

// ---- Reports (25-26 Oct 2026, Report system) ----
// POST /report {targetType: 'post'|'comment'|'user', targetId,
//               targetPath (comments/replies: their full path), reason}
// Like Facebook / TikTok: "a report is a signal, the rules decide" - the
// NUMBER of reports never removes anything by itself (Ko, 26 Oct: a
// group of people who dislike someone must not be able to bring a good
// video down by all reporting it):
//   1. First report: the AI checks the target with the normal thresholds
//      (post: caption + the video's frames, comment: its text). AI agrees
//      -> HIDE.
//   2. When 3 different people report it for the SAME reason, the AI
//      checks again, stricter, looking only at that reason (e.g. "sexual"
//      blocks from 25% instead of 40%). AI agrees -> HIDE.
//   3. AI still says it's fine -> NOT hidden. A public post only LEAVES
//      For You and Search (audience everyone -> followers, TikTok-style
//      "limited reach": followers and friends still see it) and goes into
//      Ko's review queue (reportTargets with needsReview: true).
//   4. Child safety / danger to life: into the review queue from the
//      FIRST report, priority high (the AI can't tell a person's age).
//   5. Reports from accounts younger than 24 h (termsAcceptedAt) are
//      kept but not counted (fake accounts made just to report).
// Hide never deletes: a post's audience becomes 'only_me' (the old one is
// kept in audienceBeforeHide, so every feed, query and rule hides it at
// once - the owner still sees it), it leaves Search; a comment / reply
// gets hidden: true. firestore.rules stop the owner from undoing a hide
// or a limit. Users are never hidden automatically - only recorded. Every
// hide / limit is logged in moderationActions; who reported is never
// shown to anyone. reports / reportTargets / moderationActions have no
// client access (reports: create only, for older app builds).
const REPORT_REASONS = new Set([
  'sexual', 'child_safety', 'hate', 'violence', 'self_harm', 'spam', 'other',
]);
const REPORT_URGENT = new Set(['child_safety', 'self_harm']);
// Step 3 (27 Oct 2026): a report Ko already decided on the admin page.
// 'rejected' = Ko restored / kept the content, 'accepted' = Ko removed it,
// 'dismissed' = the content was already gone.
const REPORT_DECIDED = new Set(['rejected', 'accepted', 'dismissed']);
// Reporters with this many rejected reports (reporterStanding/{uid}) are
// still recorded but no longer counted.
const REPORT_MAX_REJECTED = 3;
// Defaults; a Worker can override them with plain Text variables (only
// for testing on fly-dev-worker with few accounts):
//   REPORT_RECHECK_AT             (default 3)
//   REPORT_MIN_ACCOUNT_AGE_HOURS  (default 24)
function reportRecheckAt(env) {
  const n = Number(env.REPORT_RECHECK_AT);
  return Number.isInteger(n) && n >= 1 ? n : 3;
}
function reportMinAccountAgeMs(env) {
  const h = Number(env.REPORT_MIN_ACCOUNT_AGE_HOURS);
  return (Number.isFinite(h) && h >= 0 ? h : 24) * 60 * 60 * 1000;
}
const REPORT_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const REPORT_COMMENT_PATH_RE =
  /^posts\/[A-Za-z0-9_-]{1,128}\/comments\/[A-Za-z0-9_-]{1,128}(\/replies\/[A-Za-z0-9_-]{1,128})?$/;

// The stricter second look (step 2): OpenAI category -> score that
// already counts, per report reason. Any category OpenAI itself flags
// counts too.
const REPORT_STRICT = {
  sexual: { sexual: 0.25 },
  child_safety: { sexual: 0.15, 'sexual/minors': 0.1 },
  violence: { violence: 0.6, 'violence/graphic': 0.3 },
  self_harm: {
    'self-harm': 0.3, 'self-harm/intent': 0.3, 'self-harm/instructions': 0.3,
  },
  hate: {
    hate: 0.3, 'hate/threatening': 0.2,
    harassment: 0.4, 'harassment/threatening': 0.3,
  },
  spam: {},
  other: {},
};

function reportStrictHit(reason, result) {
  if (!result) return undefined;
  const flags = result.categories || {};
  const scores = result.category_scores || {};
  if (Object.values(flags).some((v) => v === true)) return true;
  const limits = REPORT_STRICT[reason] || {};
  return Object.entries(limits).some(([c, min]) => (scores[c] || 0) >= min);
}

// OpenAI's raw answer for a text, or undefined.
async function modTextResult(text, env) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MOD_IMG_TIMEOUT_MS);
  try {
    const res = await fetch(MOD_AI_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: MOD_AI_MODEL,
        input: String(text).slice(0, MOD_AI_MAX_CHARS),
      }),
      signal: controller.signal,
    });
    if (!res.ok) return undefined;
    const data = await res.json();
    return data?.results?.[0] || undefined;
  } catch (_) {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

// true = the AI finds it bad, false = it doesn't, null = no answer.
// [strictReason] set = the stricter second look for that reason.
async function reportAiFlags(env, type, fields, strictReason) {
  if (!env.OPENAI_API_KEY) return null;
  const text = stringField(fields, type === 'comment' ? 'text' : 'caption');
  let unanswered = false;
  if (text.trim()) {
    if (strictReason) {
      const hit = reportStrictHit(strictReason, await modTextResult(text, env));
      if (hit === true) return true;
      if (hit === undefined) unanswered = true;
    } else {
      if (moderateText(text, type === 'comment' ? 'comment' : 'caption')) {
        return true;
      }
      const blocked = await modAiBlocked(text, env);
      if (blocked === true) return true;
      if (blocked === null) unanswered = true;
    }
  }
  if (type === 'post') {
    const videoGuid = stringField(fields, 'bunnyVideoId');
    if (/^[0-9a-fA-F-]{36}$/.test(videoGuid)) {
      const check = await modCheckBunnyVideo(env, videoGuid);
      if (strictReason) {
        const hits = check.items.map((x) => reportStrictHit(strictReason, x.result));
        if (hits.some((h) => h === true)) return true;
        if (check.items.length === 0 || hits.some((h) => h === undefined)) {
          unanswered = true;
        }
      } else {
        if (check.reason) return true;
        if (!check.checked) unanswered = true;
      }
    }
  }
  return unanswered ? null : false;
}

// Counted reporters of [key]: { all, byReason: {reason: n} }.
async function reportCounts(env, accessToken, key) {
  const response = await fetch(`${firestoreBase(env)}:runQuery`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: 'reports' }],
        where: {
          fieldFilter: {
            field: { fieldPath: 'targetKey' },
            op: 'EQUAL',
            value: { stringValue: key },
          },
        },
        select: {
          fields: [
            { fieldPath: 'reporterId' },
            { fieldPath: 'reason' },
            { fieldPath: 'counted' },
            { fieldPath: 'status' },
          ],
        },
        limit: 300,
      },
    }),
  });
  if (!response.ok) throw new Error(`report count failed: ${await response.text()}`);
  const rows = await response.json();
  const all = new Set();
  const byReason = {};
  for (const row of rows) {
    const f = row.document && row.document.fields;
    const who = stringField(f, 'reporterId');
    if (!who || (f.counted && f.counted.booleanValue === false)) continue;
    // Step 3: reports Ko already decided don't count any more.
    if (REPORT_DECIDED.has(stringField(f, 'status'))) continue;
    all.add(who);
    const r = stringField(f, 'reason') || 'other';
    (byReason[r] ||= new Set()).add(who);
  }
  const out = {};
  for (const [r, s] of Object.entries(byReason)) out[r] = s.size;
  return { all: all.size, byReason: out };
}

function fsBool(fields, name) {
  return !!(fields && fields[name] && fields[name].booleanValue === true);
}

function fsTimestampMs(fields, name) {
  const v = fields && fields[name] && fields[name].timestampValue;
  const ms = v ? Date.parse(v) : NaN;
  return Number.isFinite(ms) ? ms : null;
}

async function handleReport(body, env, caller) {
  const uid = caller && caller.uid;
  if (!isSafeUid(uid)) return jsonResponse({ error: 'not allowed' }, 403);
  const type = String(body.targetType || '');
  const reason = REPORT_REASONS.has(body.reason) ? body.reason : 'other';
  let targetPath;
  if (type === 'post' && REPORT_ID_RE.test(String(body.targetId || ''))) {
    targetPath = `posts/${body.targetId}`;
  } else if (type === 'comment' &&
      REPORT_COMMENT_PATH_RE.test(String(body.targetPath || ''))) {
    targetPath = String(body.targetPath);
  } else if (type === 'user' && isSafeUid(body.targetId)) {
    targetPath = `users/${body.targetId}`;
  } else {
    return jsonResponse({ error: 'bad target' }, 400);
  }
  const key = `${type}~${targetPath.replace(/\//g, '~')}`;

  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const [target, reporter, state, standing, previous] = await Promise.all([
      firestoreGetFields(env, dbToken, targetPath),
      firestoreGetFields(env, dbToken, `users/${uid}`),
      firestoreGetFields(env, dbToken, `reportTargets/${key}`),
      firestoreGetFields(env, dbToken, `reporterStanding/${uid}`),
      firestoreGetFields(env, dbToken, `reports/${key}~${uid}`),
    ]);
    if (target === null) return jsonResponse({ ok: true, gone: true });
    const ownerId = type === 'user'
      ? String(body.targetId)
      : stringField(target, 'userId');
    if (ownerId === uid) return jsonResponse({ error: 'own content' }, 400);

    // Step 3 (27 Oct 2026): Ko already decided this person's report on
    // this target - reporting it again changes nothing (otherwise a
    // restored post could be re-reported by the same group and counted
    // again).
    if (REPORT_DECIDED.has(stringField(previous, 'status'))) {
      return jsonResponse({ ok: true });
    }

    // Accounts younger than 24 h: kept, not counted. Step 3: neither are
    // reporters whose reports Ko rejected 3 times (reporterStanding is a
    // Worker-only collection - the app can't read or change it).
    const joinedAt = fsTimestampMs(reporter, 'termsAcceptedAt');
    const counted = joinedAt !== null &&
      Date.now() - joinedAt >= reportMinAccountAgeMs(env) &&
      fsInt(standing, 'rejected') < REPORT_MAX_REJECTED;

    // One per person per target (writing it again just updates it).
    await firestorePatch(env, dbToken, `reports/${key}~${uid}`, {
      targetType: type,
      targetId: targetPath.split('/').pop(),
      targetPath,
      targetKey: key,
      targetOwnerId: ownerId,
      reporterId: uid,
      reason,
      counted,
      status: 'pending',
      source: 'worker',
      createdAt: new Date(),
    });

    const counts = await reportCounts(env, dbToken, key);
    const sameReason = counts.byReason[reason] || 0;
    const urgent = REPORT_URGENT.has(reason) ||
      [...REPORT_URGENT].some((r) => (counts.byReason[r] || 0) > 0);

    const hidden = type === 'post'
      ? fsBool(target, 'hiddenByReports')
      : fsBool(target, 'hidden');
    const limited = fsBool(target, 'limitedByReports');
    const statePatch = {
      targetType: type,
      targetPath,
      ownerId,
      reports: counts.all,
      lastReason: reason,
      priority: urgent ? 'high' : 'normal',
      updatedAt: new Date(),
    };
    for (const r of REPORT_REASONS) statePatch[`reports_${r}`] = counts.byReason[r] || 0;

    let action = null; // 'hidden' | 'limited'
    let why = null;
    if (type !== 'user' && !hidden && counted) {
      // 1. The normal check, once per target.
      if (!fsBool(state, 'aiChecked')) {
        const flagged = await reportAiFlags(env, type, target, null);
        if (flagged !== null) statePatch.aiChecked = true;
        if (flagged === true) { action = 'hidden'; why = 'ai_agrees'; }
      }
      // 2. The stricter look, once per reason, at 3 same-reason reports.
      const strictKey = `strictChecked_${reason}`;
      if (!action && sameReason >= reportRecheckAt(env) &&
          !fsBool(state, strictKey)) {
        const flagged = await reportAiFlags(env, type, target, reason);
        if (flagged !== null) statePatch[strictKey] = true;
        if (flagged === true) {
          action = 'hidden';
          why = 'ai_strict';
        } else if (type === 'post' && !limited &&
            !fsBool(state, 'reviewedOk') &&
            (stringField(target, 'audience') || 'everyone') === 'everyone') {
          // 3. Still fine for the AI: limited reach, and Ko decides.
          //    Not after Ko restored it (reviewedOk) - then only the AI
          //    can still hide it.
          action = 'limited';
          why = 'many_reports';
        }
      }
    }

    const needsReview = type !== 'user' &&
      (action === 'limited' || urgent || sameReason >= reportRecheckAt(env) ||
        fsBool(state, 'needsReview')) && action !== 'hidden';
    statePatch.needsReview = needsReview;
    statePatch.hidden = hidden || action === 'hidden';
    statePatch.limited = limited || action === 'limited';
    await firestorePatch(env, dbToken, `reportTargets/${key}`, statePatch);

    if (action) {
      if (type === 'post') {
        const audience = stringField(target, 'audience') || 'everyone';
        if (action === 'hidden') {
          await firestorePatch(env, dbToken, targetPath, {
            audience: 'only_me',
            audienceBeforeHide: limited
              ? (stringField(target, 'audienceBeforeLimit') || audience)
              : audience,
            hiddenByReports: true,
            hiddenReason: reason,
            hiddenAt: new Date(),
          });
        } else {
          await firestorePatch(env, dbToken, targetPath, {
            audience: 'followers',
            audienceBeforeLimit: audience,
            limitedByReports: true,
            limitedReason: reason,
            limitedAt: new Date(),
          });
        }
        if (env.SEARCH_DB) {
          try {
            await env.SEARCH_DB.prepare('DELETE FROM posts WHERE post_id = ?1')
              .bind(targetPath.split('/').pop()).run();
          } catch (_) {}
        }
      } else {
        await firestorePatch(env, dbToken, targetPath, {
          hidden: true,
          hiddenAt: new Date(),
          hiddenByReports: true,
          hiddenReason: reason,
        });
      }
      await firestorePatch(env, dbToken,
        `moderationActions/report~${key}~${action}`, {
          kind: type,
          source: 'reports',
          action,
          why,
          reason,
          targetPath,
          userId: ownerId,
          reports: counts.all,
          priority: urgent ? 'high' : 'normal',
          createdAt: new Date(),
        });
      // Step 2 (27 Oct 2026): tell the owner of a post why (never who).
      if (type === 'post' && isSafeUid(ownerId)) {
        try {
          await firestorePatch(env, dbToken,
            `users/${ownerId}/notifications/mod~${key}~${action}`, {
              type: 'moderation',
              fromId: 'fly',
              fromName: 'Fly',
              fromPhoto: '',
              postId: targetPath.split('/').pop(),
              action,
              reason,
              text: action === 'hidden'
                ? 'Your video was hidden because it may break our Community Guidelines. Tap to see why or to appeal.'
                : 'Your video is only shown to your followers for now while we review some reports. Tap to see why or to appeal.',
              seen: false,
              createdAt: new Date(),
            });
        } catch (_) {}
      }
    }
    return jsonResponse({ ok: true });
  } catch (err) {
    console.log('report failed', err.message);
    return jsonResponse({ error: 'try again' }, 503);
  }
}

// POST /appeal {postId, message} (27 Oct 2026, Report system step 2):
// the OWNER of a post hidden or limited by reports asks for a person to
// look again. One appeal per post. It goes to the top of Ko's review
// queue (reportTargets: appealed + priority high); the post gets
// appealStatus 'pending' (firestore.rules: only the Worker writes it).
async function handleAppeal(body, env, caller) {
  const uid = caller && caller.uid;
  const postId = String(body.postId || '');
  if (!isSafeUid(uid) || !REPORT_ID_RE.test(postId)) {
    return jsonResponse({ error: 'bad request' }, 400);
  }
  const message = String(body.message || '').trim().slice(0, 500);
  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const path = `posts/${postId}`;
    const post = await firestoreGetFields(env, dbToken, path);
    if (post === null) return jsonResponse({ error: 'gone' }, 404);
    if (stringField(post, 'userId') !== uid) {
      return jsonResponse({ error: 'not your post' }, 403);
    }
    if (!fsBool(post, 'hiddenByReports') && !fsBool(post, 'limitedByReports')) {
      return jsonResponse({ error: 'nothing to appeal' }, 400);
    }
    if (stringField(post, 'appealStatus')) {
      return jsonResponse({ ok: true, already: true });
    }
    const key = `post~${path.replace(/\//g, '~')}`;
    await firestorePatch(env, dbToken, path, {
      appealStatus: 'pending',
      appealedAt: new Date(),
    });
    await firestorePatch(env, dbToken, `reportTargets/${key}`, {
      targetType: 'post',
      targetPath: path,
      ownerId: uid,
      appealed: true,
      appealMessage: message,
      appealedAt: new Date(),
      needsReview: true,
      priority: 'high',
      updatedAt: new Date(),
    });
    await firestorePatch(env, dbToken, `moderationActions/report~${key}~appeal`, {
      kind: 'post',
      source: 'appeal',
      action: 'appeal',
      targetPath: path,
      userId: uid,
      message,
      createdAt: new Date(),
    });
    return jsonResponse({ ok: true });
  } catch (err) {
    console.log('appeal failed', err.message);
    return jsonResponse({ error: 'try again' }, 503);
  }
}

// ---------------------------------------------------------------------
// Report system step 3 (27 Oct 2026): Ko's admin page
// ---------------------------------------------------------------------
// GET  /admin      - the review page (no token in the link; Ko types
//                    SEARCH_ADMIN_TOKEN on the page, it stays in that
//                    browser tab only - sessionStorage).
// POST /admin-api  - the page's calls, header `X-Admin-Token`, body
//                    {action: 'queue'} or {action: 'restore' | 'remove',
//                    key}. Not a Firebase route: no app can call it.
//
// Queue = reportTargets with needsReview: true (appeals first, then
// priority high, then newest). Who reported is never shown.
//   Restore - a post gets its audience back (audienceBeforeHide /
//             audienceBeforeLimit), the report fields are cleared, Search
//             gets it back if it is public again; a comment / reply gets
//             hidden: false. reportTargets.reviewedOk = true: the same kind
//             of brigading can't limit it again (only the AI can still
//             hide it). Every open report on it becomes 'rejected' and each
//             reporter gets rejected +1 in reporterStanding/{uid} (3 ->
//             their reports stop counting). The owner gets a "Fly" note.
//             For content that was never hidden / limited the page calls
//             this "Keep" - same thing.
//   Remove  - deletes the post (+ its Bunny video, Search row; its sound
//             becomes 'removed') or the comment / reply; strike +1 in
//             moderationStrikes/{owner}; reports 'accepted', reporters
//             accepted +1; the owner gets a "Fly" note (no postId - the
//             post is gone).
// moderationStrikes and reporterStanding have NO rule in firestore.rules,
// so no app can read or write them - only this Worker. Strikes are only
// counted for now (no automatic ban yet).
// Few subrequests on purpose (free plan: 50 per request): one batchGet
// for the queue, one commit for all writes of a decision.

const ADMIN_PAGE_HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  // Inline page only; it may call this Worker, show https pictures and
  // embed Bunny's player - nothing else (the token can't leak anywhere).
  'Content-Security-Policy':
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " +
    "img-src https: data:; connect-src 'self'; " +
    'frame-src https://iframe.mediadelivery.net; ' +
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

const ADMIN_REASON_LABELS = {
  sexual: 'Nudity or sexual content',
  child_safety: 'Child safety',
  hate: 'Hate speech or harassment',
  violence: 'Violence or dangerous content',
  self_harm: 'Suicide, self-harm or danger to life',
  spam: 'Spam or scam',
  other: 'Something else',
};

// The post fields the Report system adds; a Restore deletes all of them.
const REPORT_POST_FIELDS = [
  'audienceBeforeHide', 'hiddenByReports', 'hiddenReason', 'hiddenAt',
  'audienceBeforeLimit', 'limitedByReports', 'limitedReason', 'limitedAt',
  'appealStatus', 'appealedAt',
];
const POST_AUDIENCES = new Set(['everyone', 'followers', 'friends', 'only_me']);
const ADMIN_KEY_RE =
  /^(post|comment)~posts~[A-Za-z0-9_-]{1,128}(~comments~[A-Za-z0-9_-]{1,128}(~replies~[A-Za-z0-9_-]{1,128})?)?$/;

function fsInt(fields, name) {
  const v = fields && fields[name];
  if (!v) return 0;
  const n = Number(v.integerValue ?? v.doubleValue ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function fsDocName(env, path) {
  return `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${path}`;
}

// A commit "update" write: sets [fields] and DELETES [deleteNames]
// (a field in the mask but not in the body is removed). Creates the doc
// if it doesn't exist.
function fsUpdateWrite(env, path, fields, deleteNames = []) {
  return {
    update: { name: fsDocName(env, path), fields: toFirestoreFields(fields) },
    updateMask: { fieldPaths: [...Object.keys(fields), ...deleteNames] },
  };
}

// Same, plus `[counter] += 1` done by Firestore itself (no read needed).
function fsIncrementWrite(env, path, fields, counter) {
  return {
    ...fsUpdateWrite(env, path, fields),
    updateTransforms: [{ fieldPath: counter, increment: { integerValue: '1' } }],
  };
}

// Applies [writes] atomically, 400 per call.
async function firestoreCommit(env, accessToken, writes) {
  for (let i = 0; i < writes.length; i += 400) {
    const response = await fetch(`${firestoreBase(env)}:commit`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ writes: writes.slice(i, i + 400) }),
    });
    if (!response.ok) {
      throw new Error(`Firestore commit failed: ${await response.text()}`);
    }
  }
}

// {path: fields | null} for many docs in ONE request.
async function firestoreBatchGet(env, accessToken, paths) {
  const out = {};
  const unique = [...new Set(paths)];
  if (unique.length === 0) return out;
  const prefix = fsDocName(env, '');
  const response = await fetch(`${firestoreBase(env)}:batchGet`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ documents: unique.map((p) => fsDocName(env, p)) }),
  });
  if (!response.ok) {
    throw new Error(`Firestore batchGet failed: ${await response.text()}`);
  }
  for (const row of await response.json()) {
    if (row.found) {
      out[row.found.name.slice(prefix.length)] = row.found.fields || {};
    } else if (row.missing) {
      out[row.missing.slice(prefix.length)] = null;
    }
  }
  return out;
}

// Docs of a collection where [field] == [value] (bool or string).
async function firestoreQueryEq(env, accessToken, collection, field, value, limit) {
  const response = await fetch(`${firestoreBase(env)}:runQuery`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: collection }],
        where: {
          fieldFilter: {
            field: { fieldPath: field },
            op: 'EQUAL',
            value: toFirestoreValue(value),
          },
        },
        limit,
      },
    }),
  });
  if (!response.ok) {
    throw new Error(`Firestore query failed: ${await response.text()}`);
  }
  return (await response.json())
    .filter((row) => row.document)
    .map((row) => ({
      id: docIdFromName(row.document.name),
      name: row.document.name,
      fields: row.document.fields || {},
    }));
}

function adminTokenOk(request, env) {
  const token = request.headers.get('X-Admin-Token') || '';
  return !!env.SEARCH_ADMIN_TOKEN && token.length > 0 &&
    token === env.SEARCH_ADMIN_TOKEN;
}

// The reason a decision is "about": the hide / limit reason, else the
// most-reported one.
function adminMainReason(state, target) {
  const direct = stringField(target, 'hiddenReason') ||
    stringField(target, 'limitedReason');
  if (direct) return direct;
  let best = stringField(state, 'lastReason') || 'other';
  let bestCount = -1;
  for (const r of REPORT_REASONS) {
    const n = fsInt(state, `reports_${r}`);
    if (n > bestCount) { best = r; bestCount = n; }
  }
  return bestCount > 0 ? best : (stringField(state, 'lastReason') || 'other');
}

function adminTargetPathOk(type, path) {
  if (type === 'post') return /^posts\/[A-Za-z0-9_-]{1,128}$/.test(path);
  if (type === 'comment') return REPORT_COMMENT_PATH_RE.test(path);
  return false;
}

async function handleAdminApi(request, env) {
  if (!adminTokenOk(request, env)) {
    return jsonResponse({ error: 'wrong token' }, 401);
  }
  let body;
  try {
    body = await request.json();
  } catch (_) {
    return jsonResponse({ error: 'bad json' }, 400);
  }
  try {
    if (body.action === 'queue') return jsonResponse(await adminQueue(env));
    if (body.action === 'restore' || body.action === 'remove') {
      const key = String(body.key || '');
      if (!ADMIN_KEY_RE.test(key)) return jsonResponse({ error: 'bad key' }, 400);
      return adminDecide(env, key, body.action);
    }
    return jsonResponse({ error: 'unknown action' }, 400);
  } catch (err) {
    console.log('admin failed', err.message);
    return jsonResponse({ error: err.message }, 500);
  }
}

async function adminQueue(env) {
  const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
  const rows = (await firestoreQueryEq(
    env, dbToken, 'reportTargets', 'needsReview', true, 100))
    .filter((r) => ADMIN_KEY_RE.test(r.id));

  const paths = [];
  for (const r of rows) {
    const type = stringField(r.fields, 'targetType');
    const path = stringField(r.fields, 'targetPath');
    const owner = stringField(r.fields, 'ownerId');
    if (adminTargetPathOk(type, path)) paths.push(path);
    if (isSafeUid(owner)) {
      paths.push(`users/${owner}`, `moderationStrikes/${owner}`);
    }
  }
  const docs = await firestoreBatchGet(env, dbToken, paths);

  const items = rows.map((r) => {
    const s = r.fields;
    const type = stringField(s, 'targetType');
    const path = stringField(s, 'targetPath');
    const ownerId = stringField(s, 'ownerId');
    const t = adminTargetPathOk(type, path) ? docs[path] : null;
    const owner = isSafeUid(ownerId) ? docs[`users/${ownerId}`] : null;
    const strikes = isSafeUid(ownerId) ? docs[`moderationStrikes/${ownerId}`] : null;
    const reasons = {};
    for (const reason of REPORT_REASONS) {
      const n = fsInt(s, `reports_${reason}`);
      if (n > 0) reasons[reason] = n;
    }
    const strict = [...REPORT_REASONS].filter((x) => fsBool(s, `strictChecked_${x}`));
    const hidden = type === 'post'
      ? fsBool(t, 'hiddenByReports')
      : fsBool(t, 'hiddenByReports') && fsBool(t, 'hidden');
    return {
      key: r.id,
      type,
      path,
      gone: !t,
      ownerId,
      ownerName: stringField(owner, 'displayName') || '(no name)',
      ownerPhoto: stringField(owner, 'photoUrl'),
      strikes: fsInt(strikes, 'strikes'),
      postBanUntil: fsTimestampMs(strikes, 'postBanUntil') || 0,
      checkAccount: fsBool(strikes, 'needsAccountReview'),
      mainReason: t ? adminMainReason(s, t) : '',
      reports: fsInt(s, 'reports'),
      reasons,
      lastReason: stringField(s, 'lastReason'),
      priority: stringField(s, 'priority') || 'normal',
      appealed: fsBool(s, 'appealed'),
      appealMessage: stringField(s, 'appealMessage'),
      hidden,
      limited: type === 'post' && fsBool(t, 'limitedByReports'),
      reviewedOk: fsBool(s, 'reviewedOk'),
      aiChecked: fsBool(s, 'aiChecked'),
      strictChecked: strict,
      text: type === 'post' ? stringField(t, 'caption') : stringField(t, 'text'),
      audience: stringField(t, 'audience') || (type === 'post' ? 'everyone' : ''),
      videoGuid: type === 'post' ? stringField(t, 'bunnyVideoId') : '',
      videoUrl: type === 'post' ? stringField(t, 'videoUrl') : '',
      createdAt: fsTimestampMs(t, 'createdAt'),
      updatedAt: fsTimestampMs(s, 'updatedAt') || fsTimestampMs(s, 'appealedAt'),
    };
  });

  // Appeals first, then priority high, then the newest.
  items.sort((a, b) =>
    (Number(b.appealed) - Number(a.appealed)) ||
    (Number(b.priority === 'high') - Number(a.priority === 'high')) ||
    ((b.updatedAt || 0) - (a.updatedAt || 0)));

  return {
    project: env.FIREBASE_PROJECT_ID || '',
    cdn: env.BUNNY_CDN_HOSTNAME || '',
    library: env.BUNNY_LIBRARY_ID || '',
    reasonLabels: ADMIN_REASON_LABELS,
    items: items.slice(0, 60),
    more: Math.max(0, items.length - 60),
  };
}

async function adminDecide(env, key, decision) {
  const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
  const state = await firestoreGetFields(env, dbToken, `reportTargets/${key}`);
  if (state === null) return jsonResponse({ error: 'not in the queue' }, 404);
  const type = stringField(state, 'targetType');
  const targetPath = stringField(state, 'targetPath');
  if (!adminTargetPathOk(type, targetPath) ||
      `${type}~${targetPath.replace(/\//g, '~')}` !== key) {
    return jsonResponse({ error: 'bad target' }, 400);
  }
  const [target, reportRows] = await Promise.all([
    firestoreGetFields(env, dbToken, targetPath),
    firestoreQueryEq(env, dbToken, 'reports', 'targetKey', key, 300),
  ]);
  const now = new Date();
  const open = reportRows.filter(
    (r) => !REPORT_DECIDED.has(stringField(r.fields, 'status')));
  const reporters = [...new Set(
    open.map((r) => stringField(r.fields, 'reporterId')).filter(isSafeUid))];
  const reportsPath = (r) => `reports/${r.id}`;
  const writes = [];

  // Already deleted (by its owner): just take it out of the queue.
  if (target === null) {
    for (const r of open) {
      writes.push(fsUpdateWrite(env, reportsPath(r), { status: 'dismissed', decidedAt: now }));
    }
    writes.push(fsUpdateWrite(env, `reportTargets/${key}`, {
      needsReview: false, decision: 'gone', decidedAt: now, updatedAt: now,
    }));
    await firestoreCommit(env, dbToken, writes);
    return jsonResponse({ ok: true, gone: true });
  }

  const ownerId = stringField(target, 'userId') || stringField(state, 'ownerId');
  const postId = targetPath.split('/')[1];
  const reason = adminMainReason(state, target);
  const reasonLabel = ADMIN_REASON_LABELS[reason] || ADMIN_REASON_LABELS.other;
  const what = type === 'post' ? 'video' : 'comment';

  if (decision === 'restore') {
    let wasActioned = false;
    let newAudience = '';
    if (type === 'post') {
      const hidden = fsBool(target, 'hiddenByReports');
      const limited = fsBool(target, 'limitedByReports');
      wasActioned = hidden || limited;
      const fields = {};
      if (wasActioned) {
        const before = hidden
          ? stringField(target, 'audienceBeforeHide')
          : stringField(target, 'audienceBeforeLimit');
        newAudience = POST_AUDIENCES.has(before) ? before : 'everyone';
        fields.audience = newAudience;
      }
      const present = REPORT_POST_FIELDS.filter((f) => target[f] !== undefined);
      if (Object.keys(fields).length || present.length) {
        writes.push(fsUpdateWrite(env, targetPath, fields, present));
      }
    } else if (fsBool(target, 'hiddenByReports')) {
      // Only undo a hide the REPORTS made (not one the video owner made).
      wasActioned = fsBool(target, 'hidden');
      writes.push(fsUpdateWrite(env, targetPath, { hidden: false },
        ['hiddenAt', 'hiddenByReports', 'hiddenReason']));
    }
    for (const r of open) {
      writes.push(fsUpdateWrite(env, reportsPath(r), { status: 'rejected', decidedAt: now }));
    }
    for (const uid of reporters) {
      writes.push(fsIncrementWrite(env, `reporterStanding/${uid}`,
        { updatedAt: now }, 'rejected'));
    }
    writes.push(fsUpdateWrite(env, `reportTargets/${key}`, {
      needsReview: false,
      hidden: false,
      limited: false,
      reviewedOk: true,
      decision: 'restored',
      appealDecision: fsBool(state, 'appealed') ? 'approved' : '',
      decidedAt: now,
      updatedAt: now,
    }));
    writes.push(fsUpdateWrite(env, `moderationActions/report~${key}~restored`, {
      kind: type,
      source: 'admin',
      action: 'restored',
      reason,
      targetPath,
      userId: ownerId,
      rejectedReports: open.length,
      createdAt: now,
    }));
    if (wasActioned && isSafeUid(ownerId)) {
      writes.push(fsUpdateWrite(env, `users/${ownerId}/notifications/mod~${key}~restored`, {
        type: 'moderation',
        fromId: 'fly',
        fromName: 'Fly',
        fromPhoto: '',
        // A post's sheet then says "Everything is back to normal".
        postId: type === 'post' ? postId : '',
        action: 'restored',
        reason,
        text: type === 'post'
          ? 'Good news! A person from the Fly team reviewed your video and it is back to normal. Thanks for your patience.'
          : 'Good news! A person from the Fly team reviewed your comment and it is visible again.',
        seen: false,
        createdAt: now,
      }));
    }
    await firestoreCommit(env, dbToken, writes);

    // Public again -> back into Search.
    if (type === 'post' && newAudience === 'everyone' && env.SEARCH_DB) {
      try {
        const merged = { ...target, audience: { stringValue: 'everyone' } };
        if (!fsBool(merged, 'videoFailed')) {
          await searchUpsertPost(env, postId, merged);
        }
      } catch (_) {}
    }
    return jsonResponse({ ok: true, decision: 'restored', audience: newAudience });
  }

  // ---- Remove ----
  // The post (its Bunny video + Search row go after the commit) or the
  // comment / reply itself.
  writes.push({ delete: fsDocName(env, targetPath) });
  for (const r of open) {
    writes.push(fsUpdateWrite(env, reportsPath(r), { status: 'accepted', decidedAt: now }));
  }
  for (const uid of reporters) {
    writes.push(fsIncrementWrite(env, `reporterStanding/${uid}`,
      { updatedAt: now }, 'accepted'));
  }
  let outcome = null;
  if (isSafeUid(ownerId)) {
    // 30 Oct 2026: one strike item per removed thing (counts 90 days); the
    // summary doc says how many still count and until when posting is off.
    const [activeBefore, summary] = await Promise.all([
      activeStrikeCount(env, dbToken, ownerId, now.getTime()),
      firestoreGetFields(env, dbToken, `moderationStrikes/${ownerId}`),
    ]);
    outcome = strikeOutcome(activeBefore, reason, now.getTime(),
      fsTimestampMs(summary, 'postBanUntil'), what, reasonLabel);
    writes.push(fsUpdateWrite(env, `moderationStrikes/${ownerId}/items/${key}`, {
      kind: type,
      reason,
      targetPath,
      severe: outcome.severe,
      createdAt: now,
      expiresAt: new Date(now.getTime() + STRIKE_DAYS * DAY_MS),
    }));
    const summaryFields = {
      userId: ownerId,
      strikes: outcome.active,
      lastStrikeAt: now,
      lastReason: reason,
      lastTargetPath: targetPath,
      lastBanDays: outcome.banDays,
      updatedAt: now,
    };
    if (outcome.banUntilMs) {
      summaryFields.postBanUntil = new Date(outcome.banUntilMs);
    }
    if (outcome.severe || outcome.active >= 3) {
      summaryFields.needsAccountReview = true;
    }
    writes.push(fsUpdateWrite(env, `moderationStrikes/${ownerId}`, summaryFields));
    writes.push(fsUpdateWrite(env, `users/${ownerId}/notifications/mod~${key}~removed`, {
      type: 'moderation',
      fromId: 'fly',
      fromName: 'Fly',
      fromPhoto: '',
      postId: '', // gone - tapping opens nothing
      action: 'removed',
      reason,
      strikes: outcome.active,
      banDays: outcome.banDays,
      text: outcome.text,
      seen: false,
      createdAt: now,
    }));
  }
  writes.push(fsUpdateWrite(env, `reportTargets/${key}`, {
    needsReview: false,
    removed: true,
    hidden: true,
    decision: 'removed',
    appealDecision: fsBool(state, 'appealed') ? 'rejected' : '',
    decidedAt: now,
    updatedAt: now,
  }));
  writes.push(fsUpdateWrite(env, `moderationActions/report~${key}~removed`, {
    kind: type,
    source: 'admin',
    action: 'removed',
    reason,
    targetPath,
    userId: ownerId,
    acceptedReports: open.length,
    videoGuid: type === 'post' ? stringField(target, 'bunnyVideoId') : '',
    strikes: outcome ? outcome.active : 0,
    banDays: outcome ? outcome.banDays : 0,
    createdAt: now,
  }));
  await firestoreCommit(env, dbToken, writes);

  if (type === 'post') {
    const videoGuid = stringField(target, 'bunnyVideoId');
    if (/^[0-9a-fA-F-]{36}$/.test(videoGuid)) await deleteBunnyVideo(env, videoGuid);
    if (env.SEARCH_DB) {
      try {
        await env.SEARCH_DB.prepare('DELETE FROM posts WHERE post_id = ?1')
          .bind(postId).run();
      } catch (_) {}
    }
    // A sound made from this video stops being usable.
    try {
      const sound = await firestoreGetFields(env, dbToken, `sounds/${postId}`);
      if (sound !== null) {
        await firestorePatch(env, dbToken, `sounds/${postId}`, {
          status: 'removed', removedAt: now,
        });
      }
    } catch (_) {}
  }
  return jsonResponse({
    ok: true,
    decision: 'removed',
    strikes: outcome ? outcome.active : 0,
    banDays: outcome ? outcome.banDays : 0,
    banUntil: outcome && outcome.banUntilMs
      ? new Date(outcome.banUntilMs).toISOString() : '',
  });
}

// ---------------------------------------------------------------------
// Strikes (30 Oct 2026) - TikTok / YouTube style, see the header.
// ---------------------------------------------------------------------
const STRIKE_DAYS = 90;          // each strike counts for 90 days
const STRIKE_BAN_DAYS_2 = 7;     // 2 active strikes
const STRIKE_BAN_DAYS_3 = 30;    // 3+ active strikes, or a severe one
const STRIKE_SEVERE = new Set(['child_safety']);
const DAY_MS = 24 * 60 * 60 * 1000;

// "6 Nov 2026" (UTC) for notification texts.
function strikeDay(ms) {
  const d = new Date(ms);
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getUTCMonth()];
  return `${d.getUTCDate()} ${m} ${d.getUTCFullYear()}`;
}

// Strikes of [uid] that still count at [nowMs] (expiresAt in the future).
async function activeStrikeCount(env, accessToken, uid, nowMs) {
  const response = await fetch(
    `${firestoreBase(env)}/moderationStrikes/${uid}/items?pageSize=100`,
    { headers: { Authorization: `Bearer ${accessToken}` } },
  );
  if (response.status === 404) return 0;
  if (!response.ok) {
    throw new Error(`strike list failed: ${await response.text()}`);
  }
  const data = await response.json();
  return (data.documents || []).filter((d) => {
    const until = fsTimestampMs(d.fields, 'expiresAt');
    return until !== null && until > nowMs;
  }).length;
}

// When posting is turned off for [uid], the end time in ms - else null.
// Any error -> null (firestore.rules still refuse the post itself).
async function postingBanUntilMs(env, uid) {
  if (!isSafeUid(uid)) return null;
  try {
    const dbToken = await getGoogleAccessToken(env, DATASTORE_SCOPE);
    const doc = await firestoreGetFields(env, dbToken, `moderationStrikes/${uid}`);
    const until = fsTimestampMs(doc, 'postBanUntil');
    return until !== null && until > Date.now() ? until : null;
  } catch (_) {
    return null;
  }
}

// What a new strike means: {active, banDays, banUntilMs, severe, text}.
function strikeOutcome(activeBefore, reason, nowMs, existingBanMs, what, reasonLabel) {
  const active = activeBefore + 1;
  const severe = STRIKE_SEVERE.has(reason);
  let banDays = 0;
  if (severe || active >= 3) banDays = STRIKE_BAN_DAYS_3;
  else if (active === 2) banDays = STRIKE_BAN_DAYS_2;
  let banUntilMs = null;
  if (banDays) {
    banUntilMs = Math.max(nowMs + banDays * DAY_MS, existingBanMs || 0);
  }
  const head = `Your ${what} was removed because it breaks our Community Guidelines (${reasonLabel}).`;
  let text;
  if (!banDays) {
    text = `${head} This is a warning (1 strike) - strikes go away after ${STRIKE_DAYS} days. A 2nd strike means 7 days without posting.`;
  } else if (severe) {
    text = `${head} Because this involves child safety, you can't post videos or stories until ${strikeDay(banUntilMs)}. Our team will also look at your account.`;
  } else if (active === 2) {
    text = `${head} This is your 2nd strike, so you can't post videos or stories until ${strikeDay(banUntilMs)}. One more strike within ${STRIKE_DAYS} days means 30 days.`;
  } else {
    text = `${head} You now have ${active} strikes, so you can't post videos or stories until ${strikeDay(banUntilMs)}. Our team will also look at your account.`;
  }
  return { active, banDays, banUntilMs, severe, text };
}

async function handleModerateText(body, env) {
  const text = typeof body?.text === 'string' ? body.text : '';
  const kind = MOD_KINDS.has(body?.kind) ? body.kind : 'comment';
  // 1. Word lists (instant, no network).
  let reason = moderateText(text, kind);
  // 2. AI - only when the lists found nothing.
  if (!reason && (await modAiBlocked(text, env)) === true) {
    reason = 'language';
  }
  return jsonResponse(reason ? { ok: false, reason } : { ok: true });
}

async function getGoogleAccessToken(env, scope = FCM_SCOPE) {
  const header = { alg: 'RS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };

  const base64urlFromString = (str) =>
    btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const base64urlFromBytes = (bytes) =>
    btoa(String.fromCharCode(...new Uint8Array(bytes)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

  const headerB64 = base64urlFromString(JSON.stringify(header));
  const claimsB64 = base64urlFromString(JSON.stringify(claims));
  const toSign = `${headerB64}.${claimsB64}`;

  const privateKey = await importPrivateKey(env.FIREBASE_PRIVATE_KEY_B64);
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(toSign),
  );
  const assertion = `${toSign}.${base64urlFromBytes(signature)}`;

  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  const tokenData = await tokenResponse.json();
  if (!tokenData.access_token) {
    throw new Error(`OAuth2 exchange failed: ${JSON.stringify(tokenData)}`);
  }
  return tokenData.access_token;
}

async function importPrivateKey(base64Der) {
  const binary = atob(base64Der.trim());
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  return crypto.subtle.importKey(
    'pkcs8',
    bytes.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

async function createLiveKitToken({
  apiKey, apiSecret, room, identity, name = '', canPublish = true,
}) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: apiKey,
    sub: identity,
    name,
    iat: now,
    nbf: now,
    exp: now + 60 * 60,
    jti: crypto.randomUUID(),
    video: {
      room,
      roomJoin: true,
      canPublish,
      canSubscribe: true,
      canPublishData: canPublish,
    },
  };

  const base64urlFromString = (str) =>
    btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const base64urlFromBytes = (bytes) =>
    btoa(String.fromCharCode(...new Uint8Array(bytes)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

  const headerB64 = base64urlFromString(JSON.stringify(header));
  const payloadB64 = base64urlFromString(JSON.stringify(payload));
  const toSign = `${headerB64}.${payloadB64}`;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(apiSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(toSign),
  );

  return `${toSign}.${base64urlFromBytes(signature)}`;
}

// The public account-deletion page (GET /delete-account). Plain HTML/CSS/JS,
// English only (Fly is a global app); its form posts to /delete-request.
// String.raw keeps the page's own regex backslashes intact.
const DELETE_ACCOUNT_PAGE_HTML = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Delete your Fly account</title>
<meta name="description" content="Request deletion of your Fly account and its data.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;800&display=swap" rel="stylesheet">
<style>
  :root {
    --pink: #FF4B6E; --purple: #9C4DFF; --blue: #3A8DFF;
    --bg: #07060b; --card: rgba(255,255,255,0.06); --line: rgba(255,255,255,0.12);
    --text: #f4f2fa; --muted: #a8a3b8;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    min-height: 100vh; color: var(--text); background: var(--bg);
    font-family: Poppins, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    line-height: 1.6; overflow-x: hidden;
  }
  /* Drifting gradient glow behind everything */
  .glow { position: fixed; inset: -20%; z-index: 0; pointer-events: none;
    background:
      radial-gradient(40% 35% at 20% 15%, rgba(255,75,110,.35), transparent 70%),
      radial-gradient(40% 35% at 85% 25%, rgba(156,77,255,.35), transparent 70%),
      radial-gradient(45% 40% at 50% 95%, rgba(58,141,255,.30), transparent 70%);
    animation: drift 18s ease-in-out infinite alternate; filter: blur(10px); }
  @keyframes drift { to { transform: translate(3%, -2%) rotate(6deg) scale(1.05); } }
  .wrap { position: relative; z-index: 1; max-width: 640px; margin: 0 auto; padding: 20px 16px 48px; }
  header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 18px; }
  .logo { font-weight: 800; font-size: 28px; letter-spacing: 1px;
    background: linear-gradient(90deg, var(--pink), var(--purple), var(--blue));
    -webkit-background-clip: text; background-clip: text; color: transparent; }
  .hero { text-align: center; margin: 8px 0 22px; }
  .bird { font-size: 64px; display: inline-block; transform-origin: 70% 80%;
    animation: wave 2.4s ease-in-out infinite; filter: drop-shadow(0 8px 24px rgba(156,77,255,.5)); }
  @keyframes wave { 0%,60%,100% { transform: rotate(0); } 10%,30% { transform: rotate(-14deg); } 20%,40% { transform: rotate(10deg); } }
  h1 { font-size: 26px; margin: 8px 0 6px; }
  .sub { color: var(--muted); margin: 0 auto; max-width: 480px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 22px; padding: 20px;
    margin-top: 16px; backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
    animation: rise .6s cubic-bezier(.2,.9,.3,1.2) both; }
  .card:nth-of-type(2) { animation-delay: .08s; } .card:nth-of-type(3) { animation-delay: .16s; }
  @keyframes rise { from { opacity: 0; transform: translateY(18px) scale(.98); } }
  .card h2 { font-size: 17px; margin: 0 0 12px; display: flex; align-items: center; gap: 10px; }
  .badge { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; font-size: 15px; flex: none;
    background: linear-gradient(135deg, var(--pink), var(--purple)); }
  ol { margin: 0; padding-left: 20px; } ol li { margin: 4px 0; }
  .path { display: inline-block; background: rgba(255,255,255,.08); border-radius: 8px; padding: 1px 8px; font-size: 14px; }
  label { display: block; font-size: 14px; color: var(--muted); margin: 12px 0 6px; }
  input, textarea { width: 100%; font: inherit; color: var(--text); background: rgba(0,0,0,.35);
    border: 1px solid var(--line); border-radius: 14px; padding: 12px 14px; outline: none; transition: border-color .2s, box-shadow .2s; }
  input:focus, textarea:focus { border-color: var(--purple); box-shadow: 0 0 0 3px rgba(156,77,255,.25); }
  textarea { min-height: 84px; resize: vertical; }
  .hp { position: absolute; left: -9999px; width: 1px; height: 1px; opacity: 0; }
  .check { display: flex; gap: 10px; align-items: flex-start; margin-top: 14px; font-size: 14px; color: var(--muted); }
  .check input { width: 18px; height: 18px; margin-top: 3px; accent-color: var(--pink); flex: none; }
  .btn { width: 100%; margin-top: 16px; border: 0; border-radius: 16px; padding: 14px; font: inherit; font-weight: 600;
    color: #fff; cursor: pointer; background: linear-gradient(90deg, var(--pink), var(--purple), var(--blue));
    background-size: 200% 100%; transition: transform .15s, background-position .6s, opacity .2s; }
  .btn:hover { background-position: 100% 0; } .btn:active { transform: scale(.98); }
  .btn:disabled { opacity: .55; cursor: default; }
  .err { color: #ff8fa3; font-size: 14px; margin-top: 10px; min-height: 1em; }
  ul.list { margin: 0; padding-left: 0; list-style: none; } ul.list li { padding: 6px 0 6px 28px; position: relative; }
  ul.list li::before { position: absolute; left: 0; }
  ul.del li::before { content: "🗑️"; } ul.keep li::before { content: "⏳"; }
  .two { display: grid; gap: 14px; } @media (min-width: 560px) { .two { grid-template-columns: 1fr 1fr; } }
  .mini { font-size: 13px; color: var(--muted); }
  .done { text-align: center; padding: 18px 6px 6px; display: none; }
  .done .big { font-size: 56px; animation: pop .6s cubic-bezier(.2,.9,.3,1.4) both; }
  @keyframes pop { from { transform: scale(.2); opacity: 0; } }
  footer { text-align: center; color: var(--muted); font-size: 12px; margin-top: 28px; }
  canvas#confetti { position: fixed; inset: 0; pointer-events: none; z-index: 5; }
</style>
</head>
<body>
<div class="glow"></div>
<canvas id="confetti"></canvas>
<div class="wrap">
  <header>
    <div class="logo">Fly</div>
  </header>

  <section class="hero">
    <div class="bird" aria-hidden="true">🐦</div>
    <h1>Delete your Fly account</h1>
    
    <p class="sub">Sad to see you go! You can delete your account inside the app, or ask us here if you no longer have the app.</p>
    
  </section>

  <div class="card">
    <h2><span class="badge">1</span><span>Delete it in the app (instant)</span></h2>
    <ol>
      <li>Open <b>Fly</b> and go to your <span class="path">Profile</span>.</li>
      <li>Tap the <span class="path">⋮</span> menu at the top right → <span class="path">Delete account</span>.</li>
      <li>Type <b>DELETE</b>, enter your password, and confirm.</li>
    </ol>
    
  </div>

  <div class="card" id="formCard">
    <h2><span class="badge">2</span><span>No app? Request deletion here</span></h2>
    <form id="f" novalidate>
      <label for="email"><span>Email you signed up with *</span></label>
      <input id="email" name="email" type="email" autocomplete="email" maxlength="200" required>
      <label for="username"><span>Your Fly name (optional)</span></label>
      <input id="username" name="username" maxlength="80">
      <label for="reason"><span>Anything you'd like to tell us? (optional)</span></label>
      <textarea id="reason" name="reason" maxlength="500"></textarea>
      <input class="hp" id="website" name="website" tabindex="-1" autocomplete="off" aria-hidden="true">
      <label class="check"><input id="ok" type="checkbox">
        <span>I understand my account and its data will be permanently deleted and can't be recovered.</span>
        
      </label>
      <button class="btn" id="go" type="submit"><span>Request deletion</span></button>
      <div class="err" id="err" role="alert"></div>
      <p class="mini">We check that the email matches a Fly account before deleting anything, so nobody can delete someone else's account.</p>
      
    </form>
    <div class="done" id="done">
      <div class="big">💜</div>
      <h2 style="justify-content:center"><span>Request received</span></h2>
      <p class="sub">We'll delete your account and data within <b>30 days</b>. Thanks for flying with us. 🐦</p>
      
    </div>
  </div>

  <div class="card">
    <h2><span class="badge">3</span><span>What gets deleted</span></h2>
    <div class="two">
      <div>
        <ul class="list del">
          <li>Your account and login</li>
          <li>Profile: name, photo, bio</li>
          <li>Your videos, stories and sounds</li>
          <li>Your comments, reactions and follows</li>
          <li>Saved videos, notifications and coins</li>
        </ul>
        
      </div>
      <div>
        <ul class="list keep">
          <li>Messages you sent stay in the other person's chat history.</li>
          <li>Backup copies are cleared within 90 days.</li>
          <li>Records we must keep for safety or legal reasons (for example, reports of abuse) may be kept as long as required.</li>
        </ul>
        
      </div>
    </div>
  </div>

  <footer>Fly · <span>Account deletion</span></footer>
</div>

<script>
(function () {
  var loadedAt = Date.now();
  var f = document.getElementById('f'), err = document.getElementById('err'), go = document.getElementById('go');
  function msg(text) { err.textContent = text; }

  f.addEventListener('submit', function (e) {
    e.preventDefault();
    var email = document.getElementById('email').value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { msg('Please enter a valid email.'); return; }
    if (!document.getElementById('ok').checked) { msg('Please tick the box to confirm.'); return; }
    err.textContent = ''; go.disabled = true;
    fetch(location.pathname.replace(/\/delete-account\/?$/, '') + '/delete-request', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: email,
        username: document.getElementById('username').value.trim(),
        reason: document.getElementById('reason').value.trim(),
        website: document.getElementById('website').value,
        elapsedMs: Date.now() - loadedAt
      })
    }).then(function (r) {
      if (!r.ok) throw new Error('bad');
      f.style.display = 'none';
      document.getElementById('done').style.display = 'block';
      confetti();
    }).catch(function () {
      go.disabled = false;
      msg("Couldn't send right now. Please try again.");
    });
  });

  function confetti() {
    var c = document.getElementById('confetti'), x = c.getContext('2d');
    var W = c.width = innerWidth, H = c.height = innerHeight;
    var cols = ['#FF4B6E', '#9C4DFF', '#3A8DFF', '#ffd166', '#ffffff'], ps = [];
    for (var i = 0; i < 140; i++) ps.push({ x: W / 2, y: H * 0.35, vx: (Math.random() - .5) * 12,
      vy: Math.random() * -12 - 4, s: Math.random() * 6 + 4, r: Math.random() * 6, c: cols[i % cols.length] });
    var t = 0;
    (function frame() {
      x.clearRect(0, 0, W, H);
      ps.forEach(function (p) { p.vy += .35; p.x += p.vx; p.y += p.vy; p.r += .1;
        x.save(); x.translate(p.x, p.y); x.rotate(p.r); x.fillStyle = p.c; x.fillRect(-p.s / 2, -p.s / 4, p.s, p.s / 2); x.restore(); });
      if (++t < 160) requestAnimationFrame(frame); else x.clearRect(0, 0, W, H);
    })();
  }
})();
</script>
</body>
</html>
`;

// The public Privacy Policy (GET /privacy), English only. Keep it free
// of backticks and ${ (String.raw template).
const PRIVACY_PAGE_HTML = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fly Privacy Policy</title>
<meta name="description" content="How Fly collects, uses and protects your information.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;800&display=swap" rel="stylesheet">
<style>
  :root {
    --pink: #FF4B6E; --purple: #9C4DFF; --blue: #3A8DFF;
    --bg: #07060b; --card: rgba(255,255,255,0.06); --line: rgba(255,255,255,0.12);
    --text: #f4f2fa; --muted: #a8a3b8;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    min-height: 100vh; color: var(--text); background: var(--bg);
    font-family: Poppins, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    line-height: 1.7; overflow-x: hidden;
  }
  .glow { position: fixed; inset: -20%; z-index: 0; pointer-events: none;
    background:
      radial-gradient(40% 35% at 20% 15%, rgba(255,75,110,.35), transparent 70%),
      radial-gradient(40% 35% at 85% 25%, rgba(156,77,255,.35), transparent 70%),
      radial-gradient(45% 40% at 50% 95%, rgba(58,141,255,.30), transparent 70%);
    filter: blur(10px); }
  .wrap { position: relative; z-index: 1; max-width: 720px; margin: 0 auto; padding: 20px 16px 48px; }
  .logo { font-weight: 800; font-size: 28px; letter-spacing: 1px;
    background: linear-gradient(90deg, var(--pink), var(--purple), var(--blue));
    -webkit-background-clip: text; background-clip: text; color: transparent; }
  h1 { font-size: 28px; margin: 14px 0 4px; }
  .sub, .mini { color: var(--muted); }
  .sub { margin: 0 0 14px; } .mini { font-size: 13px; }
  .tabs { display: flex; gap: 10px; margin: 10px 0 4px; }
  .tabs a { color: var(--text); text-decoration: none; border: 1px solid var(--line);
    background: var(--card); border-radius: 999px; padding: 6px 16px; font-size: 14px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 22px; padding: 20px;
    margin-top: 16px; backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); }
  .card h2 { font-size: 18px; margin: 0 0 10px; }
  .card h3 { font-size: 15px; margin: 14px 0 4px; color: var(--pink); }
  p { margin: 8px 0; } ul { margin: 6px 0; padding-left: 20px; } li { margin: 4px 0; }
  a { color: var(--blue); }
  .lang { margin-top: 36px; padding-top: 6px; border-top: 1px solid var(--line); }
  footer { text-align: center; color: var(--muted); font-size: 12px; margin-top: 28px; }
</style>
</head>
<body>
<div class="glow"></div>
<div class="wrap">
  <div class="logo">Fly</div>
  <h1>Privacy Policy</h1>
  <p class="sub">Last updated: 22 October 2026</p>
  <div class="tabs"><a href="/terms">Terms</a><a href="/terms#community-guidelines">Community Guidelines</a><a href="/privacy">Privacy</a></div>
  
  <section>
  <div class="card">
    <h2>About Fly</h2>
    <p>Fly is a short-video social app: you can watch and post videos and stories, chat and call friends, and go live. This policy explains what information Fly collects, why, who helps us handle it, and the choices you have. By using Fly you agree to this policy.</p>
  </div>

  <div class="card">
    <h2>Information we collect</h2>
    <h3>Information you give us</h3>
    <ul>
      <li><b>Account:</b> your email address and password (the password is handled by Firebase Authentication; we cannot read it), your display name and profile photo.</li>
      <li><b>Date of birth:</b> asked at sign-up only to check that you are 13 or older. It is checked on your phone and is <b>not saved</b>.</li>
      <li><b>Agreement to our rules:</b> which version of the Terms of Use you agreed to, and when.</li>
      <li><b>Content you create:</b> videos, stories, captions, hashtags, comments, reactions, sounds you share, and your "Sky Note".</li>
      <li><b>Messages and calls:</b> text messages, photos and voice notes you send in chats, and the audio and video of calls and live streams while they happen.</li>
      <li><b>Activity in the app:</b> who you follow, friends, blocked accounts, saved videos, views, coins and gifts, what you search for (your recent searches are kept privately on your account), and reports you send us.</li>
    </ul>
    <h3>Information from your phone</h3>
    <ul>
      <li><b>Camera and microphone</b>, only when you record a video, make a call or go live.</li>
      <li><b>Photos / files</b> you choose to upload.</li>
      <li><b>Notification token</b> (Firebase Cloud Messaging) so we can send you notifications such as messages, calls and friend requests.</li>
      <li><b>Online status:</b> whether you are online and when you were last active.</li>
    </ul>
    <p>We do not collect your precise location, contacts or advertising ID.</p>
  </div>

  <div class="card">
    <h2>How we use information</h2>
    <ul>
      <li>To run Fly: sign you in, show your profile and videos, deliver messages and calls, and show you the Home feed.</li>
      <li>To make search work: names, captions and hashtags are copied into a search index (in a normalised form, for example Zawgyi converted to Unicode) so people can find them.</li>
      <li>To send notifications you have allowed.</li>
      <li>To keep Fly safe: handling reports, blocking, copyright takedowns and abuse. Text you post for others to see (names, captions, comments, live comments and notes) is checked automatically for abusive content before it is shown.</li>
      <li>To fix problems and improve the app.</li>
    </ul>
    <p>We do <b>not</b> sell your personal information.</p>
  </div>

  <div class="card">
    <h2>Who helps us (service providers)</h2>
    <p>We use these companies to run Fly. They process data only to provide their service to us.</p>
    <ul>
      <li><b>Google Firebase</b> - sign-in, the database (Firestore) and notifications.</li>
      <li><b>Bunny.net</b> - storing and streaming videos, stories and images.</li>
      <li><b>Cloudflare</b> - our server (Workers) and the search index (D1).</li>
      <li><b>LiveKit</b> - real-time audio/video for calls and live streams.</li>
      <li><b>OpenAI</b> - automatic safety checks of text you post (its moderation service only; private chat messages are not sent).</li>
    </ul>
    <p>Your profile, videos and comments are visible to other Fly users according to how the feature works (for example, posts are public; messages are only between you and the other person). We may also share information when the law requires it, or to protect the safety of Fly and its users.</p>
  </div>

  <div class="card">
    <h2>Keeping and deleting your data</h2>
    <p>We keep your information while your account exists. You can delete your account inside the app (Profile → ⋮ → Delete account) or without the app at <a href="/delete-account">this page</a>. We delete your account and its data within 30 days, and backup copies are cleared within 90 days. Messages you sent may remain in the other person's chat. Records we must keep for safety or legal reasons (for example, reports of abuse) may be kept as long as required.</p>
  </div>

  <div class="card">
    <h2>Your choices</h2>
    <ul>
      <li>Edit your name and photo in Profile; delete your own posts, stories and comments.</li>
      <li>Block or report accounts and content.</li>
      <li>Turn off camera, microphone or notification permission in your phone's settings at any time (some features will stop working).</li>
      <li>Ask us to access, correct or delete your information by contacting us below.</li>
    </ul>
  </div>

  <div class="card">
    <h2>Children</h2>
    <p>Fly is for people aged <b>13 and over</b>. We do not knowingly collect information from children under 13. If you think a child under 13 has an account, contact us and we will delete it.</p>
  </div>

  <div class="card">
    <h2>Security and changes</h2>
    <p>We use trusted providers, encrypted connections (HTTPS) and access rules to protect your information, but no system is perfectly secure. Your data may be processed on servers outside your country. We may update this policy; when we do, we change the date at the top, and for big changes we will tell you in the app.</p>
  </div>

  <div class="card">
    <h2>Contact us</h2>
    <p>Questions or requests about your privacy: <a href="mailto:chakaboycom@gmail.com">chakaboycom@gmail.com</a></p>
  </div>
  </section>


  <footer>Fly · Privacy Policy</footer>
</div>
</body>
</html>
`;

// Terms of Use + Community Guidelines (22 Oct 2026) - GET /terms
// (aliases /terms-of-use, /community-guidelines). Same look as the
// Privacy page. Google Play needs Terms separate from the Privacy Policy
// for apps with user content. Keep free of backticks and ${.
// When the rules change in a way people must agree to again, bump the
// "Version" here AND kTermsVersion in lib/screens/terms_consent.dart.
const TERMS_PAGE_HTML = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fly Terms of Use</title>
<meta name="description" content="The rules for using Fly, including the Community Guidelines.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;800&display=swap" rel="stylesheet">
<style>
  :root {
    --pink: #FF4B6E; --purple: #9C4DFF; --blue: #3A8DFF;
    --bg: #07060b; --card: rgba(255,255,255,0.06); --line: rgba(255,255,255,0.12);
    --text: #f4f2fa; --muted: #a8a3b8;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    min-height: 100vh; color: var(--text); background: var(--bg);
    font-family: Poppins, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    line-height: 1.7; overflow-x: hidden;
  }
  .glow { position: fixed; inset: -20%; z-index: 0; pointer-events: none;
    background:
      radial-gradient(40% 35% at 20% 15%, rgba(255,75,110,.35), transparent 70%),
      radial-gradient(40% 35% at 85% 25%, rgba(156,77,255,.35), transparent 70%),
      radial-gradient(45% 40% at 50% 95%, rgba(58,141,255,.30), transparent 70%);
    filter: blur(10px); }
  .wrap { position: relative; z-index: 1; max-width: 720px; margin: 0 auto; padding: 20px 16px 48px; }
  .logo { font-weight: 800; font-size: 28px; letter-spacing: 1px;
    background: linear-gradient(90deg, var(--pink), var(--purple), var(--blue));
    -webkit-background-clip: text; background-clip: text; color: transparent; }
  h1 { font-size: 28px; margin: 14px 0 4px; }
  .sub, .mini { color: var(--muted); }
  .sub { margin: 0 0 14px; } .mini { font-size: 13px; }
  .tabs { display: flex; gap: 10px; margin: 10px 0 4px; }
  .tabs a { color: var(--text); text-decoration: none; border: 1px solid var(--line);
    background: var(--card); border-radius: 999px; padding: 6px 16px; font-size: 14px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 22px; padding: 20px;
    margin-top: 16px; backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); }
  .card h2 { font-size: 18px; margin: 0 0 10px; }
  .card h3 { font-size: 15px; margin: 14px 0 4px; color: var(--pink); }
  p { margin: 8px 0; } ul { margin: 6px 0; padding-left: 20px; } li { margin: 4px 0; }
  a { color: var(--blue); }
  .lang { margin-top: 36px; padding-top: 6px; border-top: 1px solid var(--line); }
  footer { text-align: center; color: var(--muted); font-size: 12px; margin-top: 28px; }
</style>
</head>
<body>
<div class="glow"></div>
<div class="wrap">
  <div class="logo">Fly</div>
  <h1>Terms of Use</h1>
  <p class="sub">Last updated: 22 October 2026 · Version 1</p>
  <div class="tabs"><a href="/terms">Terms</a><a href="/terms#community-guidelines">Community Guidelines</a><a href="/privacy">Privacy</a></div>

  <section>
  <div class="card">
    <h2>1. Welcome to Fly</h2>
    <p>Fly is a short-video social app where you can watch and post videos and stories, comment, chat and call friends, send gifts and go live. These Terms of Use and the <a href="#community-guidelines">Community Guidelines</a> below are the rules for using Fly. By creating an account or using Fly you agree to them. If you do not agree, please do not use Fly. How we handle your information is explained in our <a href="/privacy">Privacy Policy</a>.</p>
  </div>

  <div class="card">
    <h2>2. Who can use Fly</h2>
    <ul>
      <li>You must be <b>13 or older</b>. If the law where you live sets a higher age for using apps like Fly, you must meet that age or have your parent's or guardian's permission.</li>
      <li>One person, one real account. Do not pretend to be someone else, and do not create accounts to get around a block or a ban.</li>
      <li>Keep your password safe. You are responsible for what happens on your account.</li>
    </ul>
  </div>

  <div class="card">
    <h2>3. Your content</h2>
    <ul>
      <li>You own the videos, photos, sounds and text you post ("your content").</li>
      <li>So that Fly can work, you give us a worldwide, non-exclusive, royalty-free licence to host, store, copy, process, show and share your content inside Fly (for example in the feed, search and notifications) for as long as it is on Fly. If you share a sound so others can use it, they may use it in their Fly videos.</li>
      <li>You must have the rights to everything you post, including music and other people's work.</li>
      <li>When you delete your content or your account, we stop showing it; copies may stay in backups for a limited time (see the Privacy Policy).</li>
    </ul>
  </div>

  <div class="card" id="community-guidelines">
    <h2>4. Community Guidelines</h2>
    <p>Fly is for everyone, everywhere. These rules apply to everything you post or send: videos, stories, live streams, captions, hashtags, comments, names, notes, profile photos, sounds and messages.</p>
    <h3>Not allowed on Fly</h3>
    <ul>
      <li><b>Child safety:</b> anything that sexualises, exploits or endangers anyone under 18. We remove it, ban the account and report it to the authorities when the law requires.</li>
      <li><b>Hate:</b> attacking or insulting people because of their race, ethnicity, nationality, religion, caste, sex, gender, sexual orientation, disability or serious illness, including slurs.</li>
      <li><b>Harassment and bullying:</b> insults, threats, humiliating someone, or encouraging others to do so.</li>
      <li><b>Violence:</b> threats, praising or encouraging violence or terrorism, and graphic gore.</li>
      <li><b>Nudity and sexual content.</b></li>
      <li><b>Suicide and self-harm:</b> content that encourages or shows how to hurt yourself. If you are struggling, please reach out to someone you trust or a local helpline.</li>
      <li><b>Dangerous and illegal activities:</b> selling or promoting drugs, weapons or other illegal goods and services.</li>
      <li><b>Scams and spam:</b> fraud, fake giveaways, repeated unwanted posts, and links that move people to other apps to trick or sell to them.</li>
      <li><b>Impersonation:</b> pretending to be another person, a brand, or Fly staff.</li>
      <li><b>Privacy:</b> sharing other people's private information (addresses, phone numbers, IDs, private photos) without their permission.</li>
      <li><b>Copyright:</b> posting music, videos or other work you do not have the rights to.</li>
      <li><b>False information</b> that can cause real-world harm.</li>
    </ul>
    <h3>Be kind</h3>
    <p>Disagree without insulting. Respect people's choices to block you or not reply. Remember that real people, in many countries and languages, read what you write.</p>
  </div>

  <div class="card">
    <h2>5. How we keep Fly safe</h2>
    <ul>
      <li><b>Automatic checks.</b> Text you post for others to see (names, captions, comments, live comments and notes) is checked automatically before it appears, using word lists and an AI safety service. Text that breaks the rules is not posted and you are told why.</li>
      <li><b>Reports and blocks.</b> You can report and block accounts, videos, comments and sounds in the app. Who reported something is never shown to the person reported.</li>
      <li><b>What we may do.</b> Remove or hide content, limit features (for example posting, commenting or going live), or suspend or close accounts that break these rules - more strictly for serious or repeated breaks.</li>
      <li><b>Telling you and appeals.</b> When we act on your content or account, we tell you the reason. If you think we got it wrong, contact us (section 10) and a person will review it.</li>
    </ul>
  </div>

  <div class="card">
    <h2>6. Copyright</h2>
    <p>If you believe something on Fly uses your work without permission, use the Copyright option in the app or email <a href="mailto:aungnaungkyaw545778@gmail.com">aungnaungkyaw545778@gmail.com</a> with a link to the content and proof that you own the work. We remove content when a valid notice is received, and may close accounts that repeatedly infringe.</p>
  </div>

  <div class="card">
    <h2>7. Coins and gifts</h2>
    <p>Coins and gifts are virtual items for use inside Fly only. They have no cash value, cannot be exchanged for money and cannot be transferred outside Fly, except where Fly offers it or the law requires. We may change how coins and gifts work. Coins in an account that is closed for breaking these rules may be lost.</p>
  </div>

  <div class="card">
    <h2>8. Ending your account</h2>
    <p>You can delete your account at any time in the app (Profile → ⋮ → Delete account) or at <a href="/delete-account">this page</a>. We may suspend or close accounts that break these Terms, put others at risk, or where the law requires it.</p>
  </div>

  <div class="card">
    <h2>9. The legal part</h2>
    <ul>
      <li>Fly is provided "as is". We work hard to keep it running and safe, but we cannot promise it will always be available, error-free, or that everything other people post is accurate or appropriate.</li>
      <li>To the extent the law allows, Fly is not responsible for content posted by users, or for indirect or unexpected losses from using Fly. Nothing in these Terms limits rights you have under the law where you live that cannot be limited.</li>
      <li>We may update these Terms. When we do, we change the date and version at the top, and for important changes we will ask you to agree again in the app.</li>
    </ul>
  </div>

  <div class="card">
    <h2>10. Contact us</h2>
    <p>Questions, appeals or reports: <a href="mailto:chakaboycom@gmail.com">chakaboycom@gmail.com</a></p>
  </div>
  </section>

  <footer>Fly · Terms of Use</footer>
</div>
</body>
</html>
`;
// Report system step 3 (27 Oct 2026): Ko's review page, served by
// GET /admin. Everything people wrote (captions, comments, names, appeal
// messages) is put on the page with textContent - never as HTML.
// No "${" or backticks inside on purpose (this is a String.raw template).
const ADMIN_PAGE_HTML = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<title>Fly Review</title>
<style>
:root{
  --bg:#0d0a14;--card:#17121f;--card2:#1e1829;--line:rgba(255,255,255,.08);
  --text:#f4f1fa;--muted:#a49cb3;--dim:#6f6780;
  --pink:#ff4b6e;--purple:#9c4dff;--blue:#3a8dff;--green:#24d17e;--orange:#ff9f1c;--red:#ff4757;
  --grad:linear-gradient(120deg,#ff4b6e,#9c4dff 55%,#3a8dff);
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--text);
  font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
body{min-height:100vh;background:
  radial-gradient(600px 300px at 10% -10%,rgba(255,75,110,.18),transparent 70%),
  radial-gradient(600px 300px at 100% 0%,rgba(58,141,255,.14),transparent 70%),var(--bg)}
button{font:inherit;cursor:pointer;border:0;color:inherit}
.hide{display:none!important}
.grad-text{background:var(--grad);-webkit-background-clip:text;background-clip:text;color:transparent}

/* Login */
#login{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.login-box{width:100%;max-width:360px;text-align:center;padding:32px 24px;border-radius:24px;
  background:rgba(23,18,31,.75);backdrop-filter:blur(18px);border:1px solid var(--line);
  box-shadow:0 20px 60px rgba(0,0,0,.45);animation:pop .45s cubic-bezier(.2,1.4,.4,1)}
.logo{font-size:44px;font-weight:900;letter-spacing:-1px;margin:0}
.logo-bird{font-size:40px;display:inline-block;animation:flap 2.4s ease-in-out infinite}
.login-box p{color:var(--muted);margin:6px 0 22px}
.login-box input{width:100%;padding:14px 16px;border-radius:14px;border:1px solid var(--line);
  background:#0f0b16;color:var(--text);font-size:16px;outline:none;transition:border-color .2s}
.login-box input:focus{border-color:var(--purple)}
.btn-grad{width:100%;margin-top:12px;padding:14px;border-radius:14px;background:var(--grad);
  font-weight:700;font-size:16px;transition:transform .15s}
.btn-grad:active{transform:scale(.97)}
.err{color:var(--red);font-size:14px;min-height:20px;margin-top:10px}
.shake{animation:shake .4s}

/* Header */
header{position:sticky;top:0;z-index:5;padding:14px 16px 10px;
  background:rgba(13,10,20,.78);backdrop-filter:blur(16px);border-bottom:1px solid var(--line)}
.bar{max-width:760px;margin:0 auto;display:flex;align-items:center;gap:10px}
.bar h1{font-size:22px;margin:0;font-weight:850;flex:1;letter-spacing:-.3px}
.proj{font-size:11px;font-weight:800;padding:4px 8px;border-radius:8px;letter-spacing:.5px;
  background:rgba(36,209,126,.15);color:var(--green)}
.proj.dev{background:rgba(255,71,87,.18);color:var(--red)}
.icon-btn{width:38px;height:38px;border-radius:12px;background:var(--card2);display:grid;place-items:center;
  font-size:17px;transition:transform .15s}
.icon-btn:active{transform:scale(.9)}
.spin{animation:spin .8s linear infinite}
.chips{max-width:760px;margin:10px auto 0;display:flex;gap:8px;overflow-x:auto;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.chip{flex:none;padding:7px 12px;border-radius:999px;background:var(--card2);color:var(--muted);
  font-size:13px;font-weight:600;border:1px solid transparent;transition:all .2s}
.chip b{color:var(--text);margin-left:4px}
.chip.on{background:rgba(156,77,255,.18);border-color:rgba(156,77,255,.6);color:var(--text)}

main{max-width:760px;margin:0 auto;padding:14px 16px 80px}
.note{color:var(--dim);font-size:13px;text-align:center;margin:6px 0 14px}

/* Card */
.card{display:flex;gap:14px;padding:14px;margin-bottom:12px;border-radius:20px;background:var(--card);
  border:1px solid var(--line);animation:rise .35s cubic-bezier(.2,1.2,.4,1) both;
  transition:transform .35s cubic-bezier(.5,-.3,.6,1),opacity .35s,max-height .4s .2s,margin .4s .2s,padding .4s .2s}
.card.appeal{border-color:rgba(156,77,255,.55);box-shadow:0 0 0 1px rgba(156,77,255,.15),0 8px 30px rgba(156,77,255,.12)}
.card.high{border-color:rgba(255,71,87,.5)}
.card.out-ok{transform:translateX(110%) rotate(4deg);opacity:0}
.card.out-rm{transform:scale(.6);opacity:0;filter:blur(4px)}
.card.gone{max-height:0!important;margin:0;padding-top:0;padding-bottom:0;overflow:hidden;border-width:0}
.media{flex:none;width:92px;height:164px;border-radius:14px;overflow:hidden;position:relative;
  background:linear-gradient(160deg,#2a2236,#141019);display:grid;place-items:center}
.media img{width:100%;height:100%;object-fit:cover;display:block}
.media .play{position:absolute;inset:0;display:grid;place-items:center;font-size:28px;
  background:linear-gradient(transparent 55%,rgba(0,0,0,.55));color:#fff;text-shadow:0 2px 8px rgba(0,0,0,.6)}
.media.comment{font-size:36px;height:92px}
.body{flex:1;min-width:0}
.badges{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}
.badge{font-size:11px;font-weight:800;padding:3px 8px;border-radius:7px;letter-spacing:.3px;text-transform:uppercase}
.b-appeal{background:rgba(156,77,255,.2);color:#c9a4ff}
.b-high{background:rgba(255,71,87,.18);color:#ff8b95}
.b-hidden{background:rgba(255,159,28,.18);color:var(--orange)}
.b-limited{background:rgba(58,141,255,.18);color:#86b8ff}
.b-visible{background:rgba(36,209,126,.15);color:var(--green)}
.b-gone{background:rgba(255,255,255,.08);color:var(--muted)}
.b-type{background:rgba(255,255,255,.06);color:var(--muted)}
.owner{display:flex;align-items:center;gap:8px;margin-bottom:6px}
.avatar{width:26px;height:26px;border-radius:50%;object-fit:cover;background:var(--grad);flex:none}
.owner .name{font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.strike{font-size:12px;font-weight:700;color:var(--orange);white-space:nowrap}
.strike.zero{color:var(--dim);font-weight:500}
.text{color:#ddd6ea;margin:0 0 10px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;
  word-break:break-word;cursor:pointer}
.text.open{-webkit-line-clamp:unset}
.text.empty{color:var(--dim);font-style:italic}
.reasons{margin:4px 0 8px}
.r-row{display:flex;align-items:center;gap:8px;font-size:12.5px;margin:3px 0}
.r-label{width:46%;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.r-bar{flex:1;height:7px;border-radius:5px;background:rgba(255,255,255,.06);overflow:hidden}
.r-bar i{display:block;height:100%;border-radius:5px;background:var(--grad);transform-origin:left;animation:grow .6s cubic-bezier(.2,1,.3,1) both}
.r-n{width:22px;text-align:right;font-weight:700}
.meta{font-size:12px;color:var(--dim);margin-bottom:10px}
.appeal-msg{border-left:3px solid var(--purple);background:rgba(156,77,255,.08);padding:8px 10px;border-radius:0 10px 10px 0;
  font-size:13.5px;margin:0 0 10px;color:#e6dcf7;word-break:break-word}
.appeal-msg small{display:block;color:#b996f5;font-weight:700;font-size:11px;letter-spacing:.4px;text-transform:uppercase;margin-bottom:2px}
.actions{display:flex;gap:8px}
.act{flex:1;padding:11px 10px;border-radius:13px;font-weight:750;font-size:14px;transition:transform .15s,filter .15s}
.act:active{transform:scale(.95)}
.act[disabled]{filter:grayscale(1) opacity(.5);pointer-events:none}
.act.ok{background:rgba(36,209,126,.16);color:var(--green);border:1px solid rgba(36,209,126,.35)}
.act.rm{background:rgba(255,71,87,.14);color:#ff7a86;border:1px solid rgba(255,71,87,.35)}
.act.clear{background:var(--card2);color:var(--muted)}

/* Empty / error */
.empty-state{text-align:center;padding:70px 20px;color:var(--muted)}
.empty-state .big{font-size:64px;display:inline-block;animation:bounce 1.8s ease-in-out infinite}
.empty-state h2{color:var(--text);margin:10px 0 4px}

/* Sheet (confirm + player) */
.scrim{position:fixed;inset:0;z-index:20;background:rgba(0,0,0,.55);backdrop-filter:blur(6px);
  display:flex;align-items:flex-end;justify-content:center;animation:fade .2s}
.sheet{width:100%;max-width:480px;background:var(--card);border-radius:24px 24px 0 0;padding:10px 20px 24px;
  border:1px solid var(--line);animation:up .32s cubic-bezier(.2,1.2,.4,1)}
@media(min-width:560px){.scrim{align-items:center}.sheet{border-radius:24px}}
.grab{width:40px;height:4px;border-radius:2px;background:rgba(255,255,255,.2);margin:0 auto 14px}
.sheet h3{margin:0 0 8px;font-size:19px}
.sheet ul{margin:0 0 18px;padding-left:20px;color:var(--muted);font-size:14px}
.sheet li{margin:4px 0}
.player{width:100%;aspect-ratio:9/16;max-height:70vh;border:0;border-radius:16px;background:#000;display:block;margin:0 auto 12px}
.link{color:#8ab4ff;font-size:13px;word-break:break-all}

/* Toast */
#toast{position:fixed;left:50%;bottom:24px;transform:translate(-50%,140%);z-index:30;padding:12px 18px;border-radius:14px;
  background:rgba(30,24,41,.92);backdrop-filter:blur(12px);border:1px solid var(--line);font-weight:650;
  box-shadow:0 10px 30px rgba(0,0,0,.4);transition:transform .35s cubic-bezier(.2,1.4,.4,1),opacity .25s,visibility .35s;max-width:90vw;
  opacity:0;visibility:hidden}
#toast.show{transform:translate(-50%,0);opacity:1;visibility:visible}

@keyframes pop{from{transform:scale(.85);opacity:0}}
@keyframes rise{from{transform:translateY(14px);opacity:0}}
@keyframes up{from{transform:translateY(60px);opacity:0}}
@keyframes fade{from{opacity:0}}
@keyframes grow{from{transform:scaleX(0)}}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes shake{20%,60%{transform:translateX(-8px)}40%,80%{transform:translateX(8px)}}
@keyframes bounce{50%{transform:translateY(-12px) rotate(-6deg)}}
@keyframes flap{0%,100%{transform:translateY(0) rotate(0)}50%{transform:translateY(-6px) rotate(-8deg)}}
@media (max-width:420px){.media{width:78px;height:139px}.r-label{width:40%}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>

<section id="login">
  <form class="login-box" id="loginForm" autocomplete="off">
    <div class="logo-bird">🐦</div>
    <h1 class="logo grad-text">Fly Review</h1>
    <p>Reported videos and comments, one tap away.</p>
    <input id="token" type="password" placeholder="Admin token" autocomplete="off" spellcheck="false">
    <button class="btn-grad" type="submit">Open the queue</button>
    <div class="err" id="loginErr"></div>
  </form>
</section>

<section id="app" class="hide">
  <header>
    <div class="bar">
      <h1><span class="grad-text">Review queue</span></h1>
      <span class="proj" id="proj"></span>
      <button class="icon-btn" id="refresh" title="Refresh" aria-label="Refresh">↻</button>
      <button class="icon-btn" id="lock" title="Lock" aria-label="Lock">🔒</button>
    </div>
    <div class="chips" id="chips"></div>
  </header>
  <main>
    <div class="note">Appeals first, then high priority, then newest. Who reported is never shown.</div>
    <div id="list"></div>
  </main>
</section>

<div id="toast"></div>

<script>
(function () {
  'use strict';
  var KEY = 'flyAdminToken';
  var token = '';
  try { token = sessionStorage.getItem(KEY) || ''; } catch (e) {}
  var data = null;
  var filter = 'all';

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }
  function buzz() { try { if (navigator.vibrate) navigator.vibrate(12); } catch (e) {} }
  function toast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.classList.remove('show'); }, 2600);
  }
  function ago(ms) {
    if (!ms) return '';
    var s = Math.max(1, Math.round((Date.now() - ms) / 1000));
    if (s < 60) return s + 's ago';
    var m = Math.round(s / 60); if (m < 60) return m + 'm ago';
    var h = Math.round(m / 60); if (h < 48) return h + 'h ago';
    return Math.round(h / 24) + 'd ago';
  }

  function dayText(ms) {
    try {
      return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
    } catch (e) { return new Date(ms).toDateString(); }
  }
  // What Remove will do to the owner (same ladder as the Worker:
  // 1 = warning, 2 = 7 days, 3+ or child safety = 30 days). The count is
  // the one saved at the owner's last strike, so an expired one may still
  // be included here - the Worker counts exactly.
  function removeOutcome(it) {
    var next = (it.strikes || 0) + 1;
    if (it.mainReason === 'child_safety') {
      return 'Child safety: the owner gets a strike and can\'t post for 30 days. The account is marked "Check account".';
    }
    if (next >= 3) return 'The owner gets strike ' + next + ' and can\'t post for 30 days. The account is marked "Check account".';
    if (next === 2) return 'The owner gets a 2nd strike and can\'t post videos or stories for 7 days.';
    return 'The owner gets 1 strike = a warning (no posting limit yet). Strikes count for 90 days.';
  }

  function api(body) {
    return fetch('/admin-api', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Admin-Token': token },
      body: JSON.stringify(body)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.status === 401) { var e = new Error('token'); e.code = 401; throw e; }
        if (!r.ok) throw new Error(j.error || ('HTTP ' + r.status));
        return j;
      });
    });
  }

  // ---- Login ----
  $('loginForm').addEventListener('submit', function (ev) {
    ev.preventDefault();
    token = $('token').value.trim();
    if (!token) return;
    load(true);
  });
  $('lock').addEventListener('click', function () {
    try { sessionStorage.removeItem(KEY); } catch (e) {}
    token = ''; data = null;
    $('token').value = '';
    $('app').classList.add('hide');
    $('login').classList.remove('hide');
  });
  $('refresh').addEventListener('click', function () { buzz(); load(false); });

  function load(fromLogin) {
    $('refresh').classList.add('spin');
    return api({ action: 'queue' }).then(function (j) {
      data = j;
      try { sessionStorage.setItem(KEY, token); } catch (e) {}
      $('login').classList.add('hide');
      $('app').classList.remove('hide');
      var dev = /dev/i.test(j.project || '');
      $('proj').textContent = dev ? 'DEV' : 'PROD';
      $('proj').title = j.project || '';
      $('proj').className = 'proj' + (dev ? ' dev' : '');
      render();
    }).catch(function (e) {
      if (e.code === 401) {
        try { sessionStorage.removeItem(KEY); } catch (x) {}
        $('app').classList.add('hide');
        $('login').classList.remove('hide');
        $('loginErr').textContent = fromLogin ? 'That token is not right.' : 'Please sign in again.';
        var box = $('loginForm');
        box.classList.remove('shake'); void box.offsetWidth; box.classList.add('shake');
      } else {
        toast('😵 Could not load: ' + e.message);
      }
    }).then(function () { $('refresh').classList.remove('spin'); });
  }

  // ---- Render ----
  function matches(it) {
    if (filter === 'appeal') return it.appealed;
    if (filter === 'high') return it.priority === 'high';
    if (filter === 'post') return it.type === 'post';
    if (filter === 'comment') return it.type === 'comment';
    return true;
  }
  function renderChips() {
    var items = data.items;
    var defs = [
      ['all', 'All', items.length],
      ['appeal', '🙋 Appeals', items.filter(function (i) { return i.appealed; }).length],
      ['high', '🚨 High', items.filter(function (i) { return i.priority === 'high'; }).length],
      ['post', '🎬 Videos', items.filter(function (i) { return i.type === 'post'; }).length],
      ['comment', '💬 Comments', items.filter(function (i) { return i.type === 'comment'; }).length]
    ];
    var box = $('chips');
    box.textContent = '';
    defs.forEach(function (d) {
      var c = el('button', 'chip' + (filter === d[0] ? ' on' : ''), d[1]);
      c.appendChild(el('b', null, d[2]));
      c.addEventListener('click', function () { buzz(); filter = d[0]; render(); });
      box.appendChild(c);
    });
  }
  function render() {
    renderChips();
    var list = $('list');
    list.textContent = '';
    var shown = data.items.filter(matches);
    if (!shown.length) {
      var e = el('div', 'empty-state');
      e.appendChild(el('div', 'big', data.items.length ? '🔍' : '🎉'));
      e.appendChild(el('h2', null, data.items.length ? 'Nothing in this filter' : 'All clear!'));
      e.appendChild(el('div', null, data.items.length ? 'Try another chip above.' : 'Nothing is waiting for review. Fly on 🐦'));
      list.appendChild(e);
      return;
    }
    shown.forEach(function (it, i) {
      var c = card(it);
      c.style.animationDelay = Math.min(i, 8) * 40 + 'ms';
      list.appendChild(c);
    });
    if (data.more) list.appendChild(el('div', 'note', '+' + data.more + ' more - decide these first, then refresh.'));
  }

  function card(it) {
    var c = el('div', 'card' + (it.appealed ? ' appeal' : '') + (it.priority === 'high' ? ' high' : ''));

    // Media
    var m = el('div', 'media' + (it.type === 'comment' ? ' comment' : ''));
    if (it.type === 'post' && it.videoGuid && data.cdn) {
      var img = el('img');
      img.alt = '';
      img.loading = 'lazy';
      img.referrerPolicy = 'no-referrer';
      img.src = 'https://' + data.cdn + '/' + it.videoGuid + '/thumbnail.jpg';
      img.onerror = function () { img.remove(); };
      m.appendChild(img);
      m.appendChild(el('div', 'play', '▶'));
      m.style.cursor = 'pointer';
      m.addEventListener('click', function () { buzz(); openPlayer(it); });
    } else {
      m.textContent = it.type === 'comment' ? '💬' : '🎬';
    }
    c.appendChild(m);

    var b = el('div', 'body');
    var badges = el('div', 'badges');
    if (it.appealed) badges.appendChild(el('span', 'badge b-appeal', 'Appeal'));
    if (it.priority === 'high') badges.appendChild(el('span', 'badge b-high', 'High priority'));
    if (it.gone) badges.appendChild(el('span', 'badge b-gone', 'Already deleted'));
    else if (it.hidden) badges.appendChild(el('span', 'badge b-hidden', 'Hidden'));
    else if (it.limited) badges.appendChild(el('span', 'badge b-limited', 'Limited reach'));
    else badges.appendChild(el('span', 'badge b-visible', 'Visible'));
    badges.appendChild(el('span', 'badge b-type', it.type === 'post' ? 'Video' : (it.path.indexOf('/replies/') > 0 ? 'Reply' : 'Comment')));
    if (it.reviewedOk) badges.appendChild(el('span', 'badge b-visible', 'Restored before'));
    b.appendChild(badges);

    var o = el('div', 'owner');
    var av = el('img', 'avatar');
    av.alt = '';
    av.referrerPolicy = 'no-referrer';
    if (it.ownerPhoto && /^https:\/\//.test(it.ownerPhoto)) av.src = it.ownerPhoto;
    else av.style.visibility = 'visible';
    av.onerror = function () { av.removeAttribute('src'); };
    o.appendChild(av);
    o.appendChild(el('span', 'name', it.ownerName));
    o.appendChild(el('span', 'strike' + (it.strikes ? '' : ' zero'),
      it.strikes ? '⚠️ ' + it.strikes + ' strike' + (it.strikes > 1 ? 's' : '') : 'no strikes'));
    if (it.postBanUntil && it.postBanUntil > Date.now()) {
      o.appendChild(el('span', 'strike', '🚫 no posting until ' + dayText(it.postBanUntil)));
    }
    if (it.checkAccount) badges.appendChild(el('span', 'badge b-high', 'Check account'));
    b.appendChild(o);

    var t = el('p', 'text' + (it.text ? '' : ' empty'), it.text || (it.type === 'post' ? 'No caption' : '(empty)'));
    t.title = 'Tap to show all';
    t.addEventListener('click', function () { t.classList.toggle('open'); });
    b.appendChild(t);

    if (it.appealed) {
      var am = el('div', 'appeal-msg');
      am.appendChild(el('small', null, 'Owner says'));
      am.appendChild(document.createTextNode(it.appealMessage || '(no message - just asked for a review)'));
      b.appendChild(am);
    }

    var rs = el('div', 'reasons');
    var keys = Object.keys(it.reasons || {}).sort(function (x, y) { return it.reasons[y] - it.reasons[x]; });
    var max = 1;
    keys.forEach(function (k) { if (it.reasons[k] > max) max = it.reasons[k]; });
    keys.forEach(function (k) {
      var row = el('div', 'r-row');
      row.appendChild(el('span', 'r-label', (data.reasonLabels && data.reasonLabels[k]) || k));
      var bar = el('span', 'r-bar');
      var fill = el('i');
      fill.style.width = Math.round(it.reasons[k] / max * 100) + '%';
      bar.appendChild(fill);
      row.appendChild(bar);
      row.appendChild(el('span', 'r-n', it.reasons[k]));
      rs.appendChild(row);
    });
    if (keys.length) b.appendChild(rs);

    var ai = it.aiChecked ? 'AI: checked, found nothing' : 'AI: not checked yet';
    if (it.strictChecked && it.strictChecked.length) ai += ' · strict look: ' + it.strictChecked.join(', ');
    var meta = [it.reports + ' counted report' + (it.reports === 1 ? '' : 's'), ai];
    if (it.updatedAt) meta.push('updated ' + ago(it.updatedAt));
    if (it.type === 'post' && it.audience && !it.gone) meta.push('audience: ' + it.audience);
    b.appendChild(el('div', 'meta', meta.join(' · ')));

    var acts = el('div', 'actions');
    if (it.gone) {
      var clr = el('button', 'act clear', '🧹 Clear from queue');
      clr.addEventListener('click', function () { decide(it, 'restore', c, [clr]); });
      acts.appendChild(clr);
    } else {
      var actioned = it.hidden || it.limited;
      var ok = el('button', 'act ok', actioned ? '✅ Restore' : '👍 Keep up');
      var rm = el('button', 'act rm', '🗑️ Remove');
      ok.addEventListener('click', function () { buzz(); confirmSheet(it, 'restore', function () { decide(it, 'restore', c, [ok, rm]); }); });
      rm.addEventListener('click', function () { buzz(); confirmSheet(it, 'remove', function () { decide(it, 'remove', c, [ok, rm]); }); });
      acts.appendChild(ok);
      acts.appendChild(rm);
    }
    b.appendChild(acts);
    c.appendChild(b);
    return c;
  }

  // ---- Sheets ----
  function openSheet(build) {
    var scrim = el('div', 'scrim');
    var sh = el('div', 'sheet');
    sh.appendChild(el('div', 'grab'));
    function close() { scrim.remove(); document.removeEventListener('keydown', onKey); }
    function onKey(e) { if (e.key === 'Escape') close(); }
    build(sh, close);
    scrim.appendChild(sh);
    scrim.addEventListener('click', function (e) { if (e.target === scrim) close(); });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(scrim);
  }

  function confirmSheet(it, action, go) {
    var what = it.type === 'post' ? 'video' : 'comment';
    openSheet(function (sh, close) {
      var lines;
      if (action === 'restore') {
        sh.appendChild(el('h3', null, (it.hidden || it.limited) ? '✅ Restore this ' + what + '?' : '👍 Keep this ' + what + ' up?'));
        lines = [];
        if (it.hidden || it.limited) lines.push(it.type === 'post' ? 'Its audience goes back to what the owner chose.' : 'Everyone can see it again.');
        lines.push('The open reports are marked as rejected (3 rejections = that reporter stops counting).');
        if (it.type === 'post') lines.push('The same reports can not limit it again - only the AI can still hide it.');
        if (it.hidden || it.limited) lines.push('The owner gets a "good news" note from Fly.');
      } else {
        sh.appendChild(el('h3', null, '🗑️ Remove this ' + what + ' for good?'));
        lines = [
          it.type === 'post' ? 'The post, its video file and its Search entry are deleted. This can not be undone.' : 'The ' + what + ' is deleted. This can not be undone.',
          removeOutcome(it),
          'The reporters are thanked silently (their report counts as accepted).'
        ];
      }
      var ul = el('ul');
      lines.forEach(function (l) { ul.appendChild(el('li', null, l)); });
      sh.appendChild(ul);
      var row = el('div', 'actions');
      var no = el('button', 'act clear', 'Cancel');
      var yes = el('button', 'act ' + (action === 'restore' ? 'ok' : 'rm'), action === 'restore' ? 'Yes, restore' : 'Yes, remove');
      no.addEventListener('click', close);
      yes.addEventListener('click', function () { buzz(); close(); go(); });
      row.appendChild(no);
      row.appendChild(yes);
      sh.appendChild(row);
    });
  }

  function openPlayer(it) {
    openSheet(function (sh, close) {
      if (data.library) {
        var f = el('iframe', 'player');
        f.src = 'https://iframe.mediadelivery.net/embed/' + encodeURIComponent(data.library) + '/' +
          encodeURIComponent(it.videoGuid) + '?autoplay=true&preload=true';
        f.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
        f.setAttribute('allowfullscreen', '');
        f.referrerPolicy = 'no-referrer';
        sh.appendChild(f);
      }
      if (it.videoUrl) {
        var p = el('div', 'meta', 'Player blank? Open the stream directly: ');
        var a = el('a', 'link', it.videoUrl);
        a.href = it.videoUrl;
        a.target = '_blank';
        a.rel = 'noopener noreferrer';
        p.appendChild(a);
        sh.appendChild(p);
      }
      var x = el('button', 'act clear', 'Close');
      x.style.width = '100%';
      x.addEventListener('click', close);
      sh.appendChild(x);
    });
  }

  // ---- Decide ----
  function decide(it, action, cardEl, buttons) {
    buttons.forEach(function (bt) { bt.disabled = true; });
    api({ action: action, key: it.key }).then(function (j) {
      cardEl.style.maxHeight = cardEl.offsetHeight + 'px';
      cardEl.classList.add(action === 'remove' ? 'out-rm' : 'out-ok');
      setTimeout(function () { cardEl.classList.add('gone'); }, 300);
      setTimeout(function () {
        data.items = data.items.filter(function (x) { return x.key !== it.key; });
        render();
      }, 750);
      if (j.gone) toast('🧹 Cleared - it was already deleted');
      else if (action === 'remove') {
        toast(j.banDays
          ? '🗑️ Removed · strike ' + j.strikes + ' · no posting for ' + j.banDays + ' days'
          : '🗑️ Removed · strike 1 = warning · owner told');
      }
      else toast((it.hidden || it.limited) ? '✅ Restored · owner told' : '👍 Kept up · reports rejected');
    }).catch(function (e) {
      buttons.forEach(function (bt) { bt.disabled = false; });
      if (e.code === 401) { toast('🔒 Please sign in again'); $('lock').click(); return; }
      toast('😵 Did not work: ' + e.message);
    });
  }

  if (token) load(false);
  else $('token').focus();
})();
</script>
</body>
</html>
`;
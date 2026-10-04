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
//  POST /token          - mints a LiveKit access token
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
//  GET  /search-backfill  - (4 Oct 2026) one-time copy of existing users /
//                         posts into D1, a page at a time:
//                         /search-backfill?token=SEARCH_ADMIN_TOKEN&what=users
//                         (then what=posts). Shows a "Next page" link until
//                         done. Also creates the tables the first time.
//                         No Firebase sign-in - protected by the token.
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
// one for search (4 Oct 2026):
//   SEARCH_ADMIN_TOKEN      - any long random string, only for
//                             /search-backfill?token=...
// plus a D1 binding (Settings -> Bindings): SEARCH_DB -> fly-search.
// and one for the Bunny webhook:
//   BUNNY_WEBHOOK_TOKEN     - any long random string; the same value goes
//                             at the end of the Webhook URL set in Bunny
//                             (.../bunny-webhook?token=THAT_VALUE).

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
    if (request.method === 'POST' && url.pathname === '/delete-request') {
      return handleDeleteRequest(request, env);
    }
    // One-time search backfill, opened by Ko in a browser (token-protected).
    if (request.method === 'GET' && url.pathname === '/search-backfill') {
      return handleSearchBackfill(env, url);
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
    if (path === '/search') {
      return handleSearch(body, env);
    }
    if (path === '/search-sync-me') {
      return handleSearchSyncMe(env, caller);
    }
    if (path === '/create-video') {
      return handleCreateVideo(body, env);
    }
    return handleTokenRequest(body, env);
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

async function handleTokenRequest(body, env) {
  const roomName = body.room_name;
  const participantName = body.participant_name;
  if (!roomName || !participantName) {
    return new Response('room_name and participant_name are required', {
      status: 400,
    });
  }

  try {
    const token = await createLiveKitToken({
      apiKey: env.LIVEKIT_API_KEY,
      apiSecret: env.LIVEKIT_API_SECRET,
      room: roomName,
      identity: participantName,
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
        await firestorePatchByName(accessToken, name, {
          videoReady: ready,
          videoFailed: failed,
        });
        // A post whose video just became playable goes into search
        // (best-effort - search must never make Bunny retry the webhook).
        if (collection === 'posts' && ready && env.SEARCH_DB) {
          try {
            const doc = await firestoreGetByName(accessToken, name);
            if (doc) {
              await ensureSearchSchema(env);
              await searchUpsertPost(env, docIdFromName(name), doc.fields || {});
            }
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
          callerId: String(callerId || ''),
          callerName: String(callerName),
          callerPhoto: String(callerPhoto || ''),
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

// ---------------------------------------------------------------------
// Search (4 Oct 2026): Cloudflare D1 + SQLite FTS5
// ---------------------------------------------------------------------
// Plain tables hold one row per user / post; FTS5 "external content"
// indexes mirror them through triggers, so every upsert is ONE statement
// (the free plan allows 50 D1 queries per request). The trigram tokenizer
// finds text anywhere in a word ("ung" -> "Aung") for queries of 3+
// characters; 1-2 characters use a plain prefix match instead.
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
  const name = fsString(fields, 'displayName').trim().slice(0, 80);
  // Only writes when the name really changed (rows written cost quota).
  return env.SEARCH_DB.prepare(
    `INSERT INTO users (uid, name, updated_at) VALUES (?1, ?2, ?3)
     ON CONFLICT(uid) DO UPDATE SET name = excluded.name,
       updated_at = excluded.updated_at
     WHERE users.name IS NOT excluded.name`,
  ).bind(uid, name, Date.now());
}

function searchPostStatement(env, postId, fields) {
  const caption = fsString(fields, 'caption').slice(0, 500);
  const tags = fsStringArray(fields, 'hashtags')
    .map((t) => t.replace(/^#/, '').toLowerCase())
    .join(' ')
    .slice(0, 300);
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

async function handleSearch(body, env) {
  if (!env.SEARCH_DB) return jsonResponse({ error: 'search not set up' }, 503);
  // Keep letters/numbers/spaces of any language; drop punctuation.
  const raw = String(body.q || '').normalize('NFC').slice(0, 60);
  const q = raw.replace(/[^\p{L}\p{N}\p{M}\s]/gu, ' ').replace(/\s+/g, ' ').trim();
  if (!q) return jsonResponse({ users: [], posts: [] });

  try {
    await ensureSearchSchema(env);
    const db = env.SEARCH_DB;
    let userRows;
    let postRows;
    if ([...q].length >= 3) {
      const phrase = ftsPhrase(q);
      [userRows, postRows] = await db.batch([
        db.prepare(
          `SELECT u.uid AS id FROM users_fts f JOIN users u ON u.rowid = f.rowid
           WHERE users_fts MATCH ?1 ORDER BY f.rank LIMIT 20`,
        ).bind(`name : ${phrase}`),
        db.prepare(
          `SELECT p.post_id AS id FROM posts_fts f JOIN posts p ON p.rowid = f.rowid
           WHERE posts_fts MATCH ?1 ORDER BY p.created_at DESC LIMIT 20`,
        ).bind(phrase),
      ]);
    } else {
      // 1-2 characters: names / hashtags that START with it.
      [userRows, postRows] = await db.batch([
        db.prepare(
          `SELECT uid AS id FROM users WHERE name LIKE ?1 ESCAPE '\\'
           ORDER BY name COLLATE NOCASE LIMIT 20`,
        ).bind(`${q.replace(/[\\%_]/g, '\\$&')}%`),
        db.prepare(
          `SELECT post_id AS id FROM posts
           WHERE (' ' || tags) LIKE ?1 ESCAPE '\\'
           ORDER BY created_at DESC LIMIT 20`,
        ).bind(`% ${q.toLowerCase().replace(/[\\%_]/g, '\\$&')}%`),
      ]);
    }
    return jsonResponse({
      users: (userRows.results || []).map((r) => r.id),
      posts: (postRows.results || []).map((r) => r.id),
    });
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
      ]);
      return jsonResponse({ removed: true });
    }
    const result = await searchUserStatement(env, caller.uid, fields).run();
    return jsonResponse({ ok: true, changed: result.meta?.changes || 0 });
  } catch (err) {
    return jsonResponse({ error: `sync failed: ${err.message}` }, 500);
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

async function createLiveKitToken({ apiKey, apiSecret, room, identity }) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: apiKey,
    sub: identity,
    iat: now,
    nbf: now,
    exp: now + 60 * 60,
    jti: crypto.randomUUID(),
    video: {
      room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
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
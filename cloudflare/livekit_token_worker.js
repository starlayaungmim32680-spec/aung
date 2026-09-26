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
//                         incoming call, even if Fly is fully closed
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
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    const url = new URL(request.url);

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
      return handleCallPush(body, env);
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
      }
    }

    return new Response('OK', { status: 200 });
  } catch (err) {
    // 500 makes Bunny retry the webhook later.
    return new Response(`Webhook failed: ${err.message}`, { status: 500 });
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

async function handleCallPush(body, env) {
  const { fcmToken, callerName, callerPhoto, roomName, callerId, isVideo } =
      body;
  if (!fcmToken || !roomName || !callerName) {
    return new Response('fcmToken, roomName and callerName are required', {
      status: 400,
    });
  }

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
            data: {
              type: 'incoming_call',
              roomName: String(roomName),
              callerId: String(callerId || ''),
              callerName: String(callerName),
              callerPhoto: String(callerPhoto || ''),
              isVideo: String(!!isVideo),
            },
            android: {
              priority: 'high',
            },
            apns: {
              headers: { 'apns-priority': '10' },
              payload: {
                aps: {
                  'content-available': 1,
                  sound: 'default',
                },
              },
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
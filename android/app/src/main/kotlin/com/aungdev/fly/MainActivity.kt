package com.aungdev.fly

import android.app.KeyguardManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Adds a few things beyond the default FlutterActivity, all for calls:
//
//  1. "moveToBackground" - lets Dart minimize the app the way the Home
//     button would (video_call_screen.dart uses this for its explicit
//     minimize control), without touching the Flutter navigator stack or
//     the LiveKit room/CallKit session, so a minimized call keeps running.
//
//  2. "setCallActive"/"clearCallActive" - starts/stops
//     CallForegroundService.kt for the length of a call, so Android
//     treats Fly as a genuine foreground process and doesn't suspend it
//     just because the person switched to another app - see that file
//     for why this needs to be a real, separate Service rather than
//     relying on flutter_callkit_incoming's own internal one.
//
//  2b. "startPresenceService"/"stopPresenceService" - the same idea as
//      #2, but for as long as the person is logged in (not just during
//      a call), via a separate PresenceForegroundService.kt, so the
//      Chat/Profile online-status heartbeat in
//      main_navigation_screen.dart keeps running with the screen off.
//      Independent of the call service - either can run without the
//      other.
//
//  3. Picture-in-Picture for video calls - when there's an active video
//     call and the person leaves Fly entirely (Home button, switching
//     apps), onUserLeaveHint() automatically shrinks Fly's own window
//     into a small floating video bubble over whatever they open next,
//     instead of just disappearing.
//
//  5. "openEmailApp" (4 Nov 2026) - "Open Gmail" after a password-reset
//     email (password_reset.dart): opens the Gmail APP itself (not the
//     browser), else the phone's own email app, else returns false and
//     Dart opens Gmail in the browser. Needs the com.google.android.gm
//     <package> query in AndroidManifest.xml (Android 11+).
//
//  6. "fly/links" (6 Nov 2026) - the password-reset email link
//     https://<project>.firebaseapp.com/__/auth/action?... (App Link,
//     AndroidManifest.xml; the Worker's /auth-action is accepted too)
//     opens Fly. A link that started the app waits in pendingAuthLink until
//     Dart asks "takeAuthLink"; a link while Fly is already running goes
//     straight to Dart as "onAuthLink" (onNewIntent - singleInstance).
//
//  4. requestDismissKeyguard() in onCreate/onResume - on a phone with NO
//     secure lock (swipe-only, or no lock at all), this lets answering a
//     call go straight into VideoCallScreen without any extra prompt,
//     the same way showWhenLocked/turnScreenOn already let the ringing
//     screen itself show up front. On a phone with an actual PIN,
//     pattern, or password set, Android still requires that credential
//     here - that's an OS security guarantee no app (Fly included) can
//     bypass, not something fixable in code.
class MainActivity : FlutterActivity() {
    private val CHANNEL = "fly/background"
    private var callActive = false
    private var callIsVideo = false
    private var presenceActive = false
    private var linksChannel: MethodChannel? = null
    private var pendingAuthLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dismissKeyguardIfPossible()
        authLinkFrom(intent)?.let { pendingAuthLink = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = authLinkFrom(intent) ?: return
        val channel = linksChannel
        if (channel != null) {
            channel.invokeMethod("onAuthLink", link)
        } else {
            pendingAuthLink = link
        }
    }

    // Only Fly's https App Links: password reset, and since 7 Nov 2026 a
    // profile /u/<uid> (the Fly Pass QR) - nothing else. Dart decides
    // what each one opens (new_password_screen.dart AuthLinks).
    private fun authLinkFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        if (data.scheme != "https") return null
        val path = data.path ?: return null
        if (!path.startsWith("/__/auth/action") &&
            !path.startsWith("/auth-action") &&
            !path.startsWith("/u/")) return null
        return data.toString()
    }

    override fun onResume() {
        super.onResume()
        dismissKeyguardIfPossible()
    }

    private fun dismissKeyguardIfPossible() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val keyguardManager = getSystemService(KeyguardManager::class.java)
            try {
                keyguardManager?.requestDismissKeyguard(this, null)
            } catch (e: Exception) {
                // Non-critical - worst case, the person sees the normal
                // lock screen prompt they'd have seen anyway.
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        linksChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fly/links").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeAuthLink" -> {
                        result.success(pendingAuthLink)
                        pendingAuthLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBackground" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "setCallActive" -> {
                        callActive = true
                        callIsVideo = (call.argument<Boolean>("isVideo") == true)
                        startCallForegroundService(callIsVideo)
                        result.success(null)
                    }
                    "clearCallActive" -> {
                        callActive = false
                        callIsVideo = false
                        stopCallForegroundService()
                        result.success(null)
                    }
                    "startPresenceService" -> {
                        presenceActive = true
                        startPresenceForegroundService()
                        result.success(null)
                    }
                    "stopPresenceService" -> {
                        presenceActive = false
                        stopPresenceForegroundService()
                        result.success(null)
                    }
                    "openEmailApp" -> {
                        result.success(openEmailApp())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun openEmailApp(): Boolean {
        // 1. Gmail itself.
        try {
            val gmail = packageManager.getLaunchIntentForPackage("com.google.android.gm")
            if (gmail != null) {
                gmail.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(gmail)
                return true
            }
        } catch (e: Exception) {
            // fall through
        }
        // 2. Whatever email app the phone has (Outlook, Samsung Email...).
        try {
            val any = Intent.makeMainSelectorActivity(
                Intent.ACTION_MAIN, Intent.CATEGORY_APP_EMAIL)
            any.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(any)
            return true
        } catch (e: Exception) {
            return false
        }
    }

    private fun startPresenceForegroundService() {
        val intent = Intent(this, PresenceForegroundService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopPresenceForegroundService() {
        stopService(Intent(this, PresenceForegroundService::class.java))
    }

    private fun startCallForegroundService(isVideo: Boolean) {
        val intent = Intent(this, CallForegroundService::class.java)
        intent.putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopCallForegroundService() {
        stopService(Intent(this, CallForegroundService::class.java))
    }

    // Called automatically by Android right as the person leaves Fly for
    // the Home screen or another app (not for a normal Flutter navigator
    // pop, which stays inside the app) - the natural place to decide
    // whether to shrink into a PiP bubble instead of just backgrounding
    // normally.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (callActive && callIsVideo && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(9, 16))
                .build()
            try {
                enterPictureInPictureMode(params)
            } catch (e: Exception) {
                // Some OEMs restrict PiP even when the API says it's
                // supported - falling back to a normal background is
                // fine, not worth crashing over.
            }
        }
    }

    override fun onDestroy() {
        // Safety net - never leave a foreground service (and its
        // persistent notification) running past the Activity's own
        // lifecycle if it somehow never got explicitly cleared.
        if (callActive) stopCallForegroundService()
        if (presenceActive) stopPresenceForegroundService()
        super.onDestroy()
    }
}
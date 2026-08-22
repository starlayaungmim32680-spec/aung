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
//  3. Picture-in-Picture for video calls - when there's an active video
//     call and the person leaves Fly entirely (Home button, switching
//     apps), onUserLeaveHint() automatically shrinks Fly's own window
//     into a small floating video bubble over whatever they open next,
//     instead of just disappearing.
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dismissKeyguardIfPossible()
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
                    else -> result.notImplemented()
                }
            }
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
        // Safety net - never leave the foreground service (and its
        // persistent notification) running past the Activity's own
        // lifecycle if a call somehow never explicitly cleared it.
        if (callActive) stopCallForegroundService()
        super.onDestroy()
    }
}
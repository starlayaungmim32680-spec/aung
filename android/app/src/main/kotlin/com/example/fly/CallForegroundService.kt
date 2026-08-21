package com.example.fly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

// A genuine Android foreground service, deliberately simple: its only
// job is to exist and be foreground, which is what tells Android "this
// process is doing something the person cares about right now, don't
// freeze or kill it" - the actual call (LiveKit's Room, its WebRTC
// connection, CallKit's own session) all keep running exactly as they
// already do, in the same app process, once that process is protected
// this way. Nothing about the call logic itself lives here.
//
// Started/stopped from MainActivity.kt's method channel, which
// video_call_screen.dart calls when a call connects and when it truly
// ends (not when just minimized in-app, since the process is never
// backgrounded in that case anyway).
//
// IMPORTANT: only declare the foreground-service types actually in use
// at that moment (Android 14+ enforces this) - claiming "camera" for a
// voice call that never touches the camera throws a
// MissingForegroundServiceTypeException and crashes the call right at
// connect time, which is exactly what including it unconditionally did.
class CallForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "fly_call_service"
        const val NOTIFICATION_ID = 4821
        const val EXTRA_IS_VIDEO = "isVideo"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false
        startForegroundCompat(isVideo)
        return START_STICKY
    }

    private fun startForegroundCompat(isVideo: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Fly call",
                NotificationManager.IMPORTANCE_LOW,
            )
            manager?.createNotificationChannel(channel)
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Fly call in progress")
            .setContentText("Tap to return to your call")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (isVideo) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
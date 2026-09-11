package com.aungdev.fly

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

// A genuine Android foreground service whose only job is to keep Fly's
// process alive while someone is logged in and hasn't force-closed the
// app, so the online-status heartbeat in main_navigation_screen.dart
// (Dart) can keep refreshing `lastActive` in Firestore even with the
// screen off/locked. Without this, Android suspends Fly's background
// process - especially aggressive on some OEMs like vivo's Funtouch OS -
// and the heartbeat simply stops, making the person look offline within
// about a minute even though they never actually closed Fly.
//
// Started right after login (MainNavigationScreen's initState) and
// stopped on logout or when Fly is swiped away from Recents - see
// MainActivity.kt's method channel handlers.
//
// Deliberately uses IMPORTANCE_MIN so the notification collapses under
// "Silent" and stays out of the way as much as Android allows - it can't
// be hidden entirely (Android's own rule for any foreground service),
// but this keeps it as unobtrusive as possible. See CallForegroundService.kt
// for the identical pattern this is based on (that one for the length of
// a call, this one for as long as the person is logged in).
class PresenceForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "fly_presence_service"
        const val NOTIFICATION_ID = 4822
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Fly online status",
                NotificationManager.IMPORTANCE_MIN,
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
            .setContentTitle("Fly")
            .setContentText("You're online")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
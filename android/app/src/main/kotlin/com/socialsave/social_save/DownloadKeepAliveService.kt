package com.socialsave.social_save

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
import io.flutter.plugin.common.MethodChannel

object DownloadEvents {
    var channel: MethodChannel? = null

    fun emit(action: String, id: String) {
        val messenger = channel ?: return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            messenger.invokeMethod("downloadAction", mapOf("action" to action, "id" to id))
        }
    }
}

class DownloadKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra(EXTRA_ID) ?: ""
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "SocialSave"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Downloading"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
        val notification = buildNotification(id, title, text, progress, paused)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun buildNotification(
        id: String,
        title: String,
        text: String,
        progress: Int,
        paused: Boolean,
    ): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Downloads",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val toggle = actionIntent(if (paused) "resume" else "pause", id, 1)
        val cancel = actionIntent("cancel", id, 2)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(!paused)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setProgress(100, progress.coerceIn(0, 100), progress <= 0 && !paused)
            .addAction(0, if (paused) "Resume" else "Pause", toggle)
            .addAction(0, "Cancel", cancel)
            .build()
    }

    private fun actionIntent(action: String, id: String, request: Int): PendingIntent {
        val intent = Intent(this, DownloadActionReceiver::class.java).apply {
            this.action = ACTION_BROADCAST
            putExtra("action", action)
            putExtra("id", id)
        }
        return PendingIntent.getBroadcast(
            this,
            request,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        const val CHANNEL_ID = "socialsave_downloads"
        const val NOTIFICATION_ID = 42
        const val ACTION_STOP = "socialsave.STOP_KEEP_ALIVE"
        const val ACTION_BROADCAST = "socialsave.DOWNLOAD_ACTION"
        const val EXTRA_ID = "id"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_PAUSED = "paused"
    }
}

class DownloadActionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: android.content.Context, intent: Intent) {
        val action = intent.getStringExtra("action") ?: return
        val id = intent.getStringExtra("id") ?: return
        DownloadEvents.emit(action, id)
    }
}

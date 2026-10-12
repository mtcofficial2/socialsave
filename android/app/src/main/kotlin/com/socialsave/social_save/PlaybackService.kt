package com.socialsave.social_save

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.media.session.MediaSession
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Lets PhoneBody hear notification buttons. */
object PlaybackEvents {
    var handler: ((String) -> Unit)? = null
    var token: MediaSession.Token? = null
}

/**
 * Foreground "media playback" service. It keeps the app process (and the
 * player's audio) running while the screen is off or the app is in the
 * background, and shows the media notification / lock-screen controls.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always go foreground first: a stop can arrive right after a
        // startForegroundService() call, and Android kills the app if the
        // service ends before startForeground().
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val playing = if (intent?.action == ACTION_STOP) {
            false
        } else {
            intent?.getBooleanExtra(EXTRA_PLAYING, true) ?: true
        }
        lastTitle = title
        goForeground(title, playing)
        if (intent?.action == ACTION_STOP) {
            releaseWake()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (playing) holdWake() else releaseWake()
        return START_NOT_STICKY
    }

    private fun goForeground(title: String, playing: Boolean) {
        val notification = try {
            build(title, playing)
        } catch (_: Exception) {
            val fallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            fallback.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(title).build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        releaseWake()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        releaseWake()
        super.onDestroy()
    }

    private fun holdWake() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(PowerManager::class.java) ?: return
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SocialSave:playback").apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWake() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun build(title: String, playing: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            10,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        PlaybackEvents.token?.let { style.setMediaSession(it) }
        builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setLargeIcon(BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setContentTitle(title)
            .setContentText("SocialSave")
            .setContentIntent(open)
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(style)
            .addAction(action(android.R.drawable.ic_media_rew, "Back 10 s", "rewind", 11))
            .addAction(
                if (playing) {
                    action(android.R.drawable.ic_media_pause, "Pause", "pause", 12)
                } else {
                    action(android.R.drawable.ic_media_play, "Play", "play", 13)
                },
            )
            .addAction(action(android.R.drawable.ic_media_ff, "Forward 10 s", "forward", 14))
            .addAction(action(android.R.drawable.ic_media_next, "Next", "next", 15))
        return builder.build()
    }

    private fun action(icon: Int, label: String, name: String, request: Int): Notification.Action {
        val intent = Intent(this, PlaybackActionReceiver::class.java).apply {
            action = ACTION_BUTTON
            putExtra("action", name)
        }
        val pending = PendingIntent.getBroadcast(
            this,
            request,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(icon, label, pending).build()
    }

    companion object {
        const val CHANNEL_ID = "socialsave_playback"
        const val NOTIFICATION_ID = 43
        const val ACTION_STOP = "socialsave.STOP_PLAYBACK"
        const val ACTION_BUTTON = "socialsave.PLAYBACK_BUTTON"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PLAYING = "playing"

        @Volatile var running = false
        @Volatile private var started = false
        private var lastTitle = "SocialSave"

        fun update(context: Context, title: String, playing: Boolean) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PLAYING, playing)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                started = true
            } catch (_: Exception) {
                // Starting from the background can be refused; playback still works in the app.
            }
        }

        fun stop(context: Context) {
            // Nothing to stop: don't create the service just to end it.
            if (!started && !running) return
            started = false
            try {
                val intent = Intent(context, PlaybackService::class.java).setAction(ACTION_STOP)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
            }
        }
    }
}

class PlaybackActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra("action") ?: return
        PlaybackEvents.handler?.invoke(action)
    }
}

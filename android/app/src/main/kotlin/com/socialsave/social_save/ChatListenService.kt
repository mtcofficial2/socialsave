package com.socialsave.social_save

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the signed-in chat socket alive after the phone is locked or the
 * app is swiped away, so a new message can still pop. The status line is
 * silent. The message itself uses the chat channel.
 *
 * Channel `socialsave/chat_listen`: start, stop, screenOn -> bool.
 */
object ChatListen {
    private const val TAG = "SocialSaveChat"

    @Volatile
    var active = false

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        channel = MethodChannel(messenger, "socialsave/chat_listen").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            active = true
                            ChatListenService.start(app)
                            result.success(true)
                        }
                        "stop" -> {
                            active = false
                            ChatListenService.stop(app)
                            result.success(true)
                            if (!SessionBridge.activityAlive && !SessionBridge.active) {
                                main.postDelayed({
                                    if (!active && !SessionBridge.active && !SessionBridge.activityAlive) {
                                        MainActivity.destroyDetachedEngine()
                                    }
                                }, 1500)
                            }
                        }
                        "screenOn" -> {
                            val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.isInteractive)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "chat listen ${call.method} failed", e)
                    result.success(false)
                }
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

class ChatListenService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (running) shutdown() else stopSelf()
            return START_NOT_STICKY
        }
        val notification = build(this)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                try {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "remoteMessaging refused, using dataSync: $e")
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                }
            } else if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "could not go foreground: $e")
        }
        running = true
        acquireLock()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from Recents: keep listening so a message can still pop.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        releaseLock()
        super.onDestroy()
    }

    @Suppress("WakelockTimeout")
    private fun acquireLock() {
        try {
            if (wakeLock != null) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SocialSave:chat").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "wake lock: $e")
        }
    }

    private fun releaseLock() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun shutdown() {
        running = false
        releaseLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    companion object {
        private const val TAG = "SocialSaveChat"
        const val CHANNEL_ID = "socialsave_chat_listen"
        const val NOTIFICATION_ID = 4812
        const val ACTION_STOP = "socialsave.CHAT_LISTEN_STOP"

        @Volatile
        var running = false

        fun start(context: Context) {
            val intent = Intent(context, ChatListenService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "start refused: $e")
            }
        }

        fun stop(context: Context) {
            try {
                context.startService(
                    Intent(context, ChatListenService::class.java).apply { action = ACTION_STOP },
                )
            } catch (_: Exception) {
                try {
                    context.stopService(Intent(context, ChatListenService::class.java))
                } catch (_: Exception) {
                }
            }
        }

        private fun channel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Message listener",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps Social Save able to pop a message after the app is closed"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }

        fun build(context: Context): Notification {
            channel(context)
            val open = PendingIntent.getActivity(
                context,
                30,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Social Save")
                .setContentText("Waiting for messages")
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setShowBadge(false)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(open)
                .build()
        }
    }
}

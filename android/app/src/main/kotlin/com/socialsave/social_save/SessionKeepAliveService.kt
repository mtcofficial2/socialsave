package com.socialsave.social_save

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between the Dart ShareSession and Android for a connected
 * (Xender-style) session: a foreground service with a persistent
 * "Connected to …" notification, wake + Wi-Fi locks, "file received"
 * notifications and the battery-optimisation exemption.
 *
 * Channel `socialsave/session`:
 *  Dart -> Android: start/update {title, text}, stop, received {title, text, path?},
 *                   batteryExempt -> bool, requestBatteryExempt, canKeepAlive
 *  Android -> Dart: disconnect (notification action), open (notification tap)
 */
object SessionBridge {
    private const val TAG = "SocialSaveSession"

    /** True while a session is connected (keeps the engine alive). */
    @Volatile
    var active = false

    /** MainActivity instances alive (created and not destroyed). */
    @Volatile
    var activities = 0
    val activityAlive get() = activities > 0

    /** Asked from the notification before the Dart side was ready. */
    var pendingOpen = false

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    /** Called when the session ends while no activity is around. */
    var onIdleWithoutActivity: (() -> Unit)? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        channel = MethodChannel(messenger, "socialsave/session").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start", "update" -> {
                            active = true
                            val title = call.argument<String>("title") ?: "Connected"
                            val text = call.argument<String>("text") ?: ""
                            if (call.method == "start" || !SessionKeepAliveService.running) {
                                SessionKeepAliveService.start(app, title, text)
                            } else {
                                SessionKeepAliveService.update(app, title, text)
                            }
                            result.success(true)
                        }
                        "stop" -> {
                            active = false
                            SessionKeepAliveService.stop(app)
                            result.success(true)
                            if (!activityAlive) main.postDelayed({ if (!active && !activityAlive) onIdleWithoutActivity?.invoke() }, 1500)
                        }
                        "received" -> {
                            SessionKeepAliveService.notifyReceived(
                                app,
                                call.argument<String>("title") ?: "File received",
                                call.argument<String>("text") ?: "",
                            )
                            result.success(true)
                        }
                        "batteryExempt" -> result.success(isExempt(app))
                        "requestBatteryExempt" -> result.success(requestExempt(context))
                        "takeOpen" -> {
                            val v = pendingOpen
                            pendingOpen = false
                            result.success(v)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "session call ${call.method} failed", e)
                    result.success(false)
                }
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    fun sendToDart(method: String): Boolean {
        val c = channel ?: return false
        main.post {
            try {
                c.invokeMethod(method, null)
            } catch (_: Exception) {
            }
        }
        return true
    }

    private fun isExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    @SuppressLint("BatteryLife")
    private fun requestExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23 || isExempt(context)) return true
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
            if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}

class SessionKeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var wifiLockPerf: android.net.wifi.WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT -> {
                // Dart ends the session on both devices and then calls stop.
                if (!SessionBridge.sendToDart("disconnect")) shutdown()
                return START_NOT_STICKY
            }
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        lastTitle = title
        lastText = text
        val n = build(this, title, text)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                try {
                    startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                } catch (e: Exception) {
                    Log.w("SocialSaveSession", "connectedDevice FGS refused, using dataSync: $e")
                    startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                }
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (e: Exception) {
            Log.w("SocialSaveSession", "could not go foreground: $e")
        }
        running = true
        acquireLocks()
        return START_NOT_STICKY
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "socialsave:session").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            if (wifiLock == null) {
                @Suppress("DEPRECATION")
                val mode = if (Build.VERSION.SDK_INT >= 29) android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY else android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifiLock = wifi.createWifiLock(mode, "socialsave-session").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wifiLockPerf == null) {
                @Suppress("DEPRECATION")
                wifiLockPerf = wifi.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "socialsave-session-perf").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (e: Exception) {
            Log.w("SocialSaveSession", "locks: $e")
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.release() } catch (_: Exception) {}
        try { wifiLock?.release() } catch (_: Exception) {}
        try { wifiLockPerf?.release() } catch (_: Exception) {}
        wakeLock = null
        wifiLock = null
        wifiLockPerf = null
    }

    private fun shutdown() {
        running = false
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from Recents: stay connected (the notification has Disconnect).
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        releaseLocks()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "socialsave_session"
        const val RECEIVED_CHANNEL_ID = "socialsave_received"
        const val NOTIFICATION_ID = 4711
        const val ACTION_STOP = "socialsave.SESSION_STOP"
        const val ACTION_DISCONNECT = "socialsave.SESSION_DISCONNECT"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_OPEN_SESSION = "socialsave_open_session"

        @Volatile
        var running = false
        private var lastTitle = "Connected"
        private var lastText = ""
        private var receivedId = 5000

        fun start(context: Context, title: String, text: String) {
            lastTitle = title
            lastText = text
            val intent = Intent(context, SessionKeepAliveService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (e: Exception) {
                // Android 12+ refuses to start a foreground service from the background.
                Log.w("SocialSaveSession", "start refused: $e")
            }
        }

        fun update(context: Context, title: String, text: String) {
            lastTitle = title
            lastText = text
            try {
                val nm = context.getSystemService(NotificationManager::class.java)
                nm.notify(NOTIFICATION_ID, build(context, title, text))
            } catch (_: Exception) {
            }
        }

        fun stop(context: Context) {
            if (!running) return
            try {
                context.startService(Intent(context, SessionKeepAliveService::class.java).apply { action = ACTION_STOP })
            } catch (_: Exception) {
                try {
                    context.stopService(Intent(context, SessionKeepAliveService::class.java))
                } catch (_: Exception) {
                }
            }
        }

        private fun channels(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Connected device", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows while SocialSave stays connected to another device"
                    setShowBadge(false)
                })
            }
            if (nm.getNotificationChannel(RECEIVED_CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(RECEIVED_CHANNEL_ID, "Files received", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Files that arrived from a connected device"
                })
            }
        }

        private fun openIntent(context: Context, request: Int): PendingIntent {
            val open = Intent(context, MainActivity::class.java).apply {
                putExtra(EXTRA_OPEN_SESSION, true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            return PendingIntent.getActivity(context, request, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        fun build(context: Context, title: String, text: String): Notification {
            channels(context)
            val disconnect = PendingIntent.getService(
                context,
                11,
                Intent(context, SessionKeepAliveService::class.java).apply { action = ACTION_DISCONNECT },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(openIntent(context, 10))
                .addAction(0, "Open", openIntent(context, 12))
                .addAction(0, "Disconnect", disconnect)
                .build()
        }

        fun notifyReceived(context: Context, title: String, text: String) {
            try {
                channels(context)
                val n = NotificationCompat.Builder(context, RECEIVED_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setAutoCancel(true)
                    .setContentIntent(openIntent(context, 20))
                    .build()
                val nm = context.getSystemService(NotificationManager::class.java)
                nm.notify(receivedId++, n)
            } catch (_: Exception) {
            }
        }
    }
}

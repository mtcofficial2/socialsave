package com.socialsave.social_save

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.os.SystemClock
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat

/** Optional floating bubble (needs "Display over other apps"). Tapping it opens an
 *  invisible activity that may read the clipboard, then shows [LinkPrompt]. */
class BubbleService : Service() {
    companion object {
        var instance: BubbleService? = null
        private const val CHANNEL = "link_bubble"
        private const val NOTIF_ID = 4107

        fun canDraw(c: Context) = Settings.canDrawOverlays(c)

        fun start(c: Context) {
            val i = Intent(c, BubbleService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }

        /** Starts the bubble again when it is switched on (accessibility service start, app start). */
        fun autostart(c: Context) {
            try {
                val p = c.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                if (instance == null && canDraw(c) && p.getBoolean("flutter.bgdetect.enabled", false) &&
                    p.getBoolean("flutter.bgdetect.bubble", false)) start(c)
            } catch (_: Exception) {}
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, BubbleService::class.java))
        }
    }

    private var wm: WindowManager? = null
    private var bubble: TextView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Link bubble", NotificationManager.IMPORTANCE_MIN))
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Link bubble is on")
            .setContentText("Tap the bubble after copying a video link")
            .setContentIntent(open)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        if (canDraw(this)) addBubble() else stopSelf()
    }

    private fun addBubble() {
        val m = getSystemService(WINDOW_SERVICE) as WindowManager
        wm = m
        val d = resources.displayMetrics.density
        val size = (52 * d).toInt()
        val v = TextView(this).apply {
            text = "\u2193"
            textSize = 24f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#E64C8DFF"))
            }
            elevation = 8 * d
            contentDescription = "Download copied link"
        }
        val lp = WindowManager.LayoutParams(
            size, size,
            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = (260 * d).toInt()
        }
        var sx = 0f; var sy = 0f; var ox = 0; var oy = 0; var moved = false
        v.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { sx = e.rawX; sy = e.rawY; ox = lp.x; oy = lp.y; moved = false; true }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - sx).toInt(); val dy = (e.rawY - sy).toInt()
                    if (kotlin.math.abs(dx) > 8 || kotlin.math.abs(dy) > 8) moved = true
                    lp.x = ox + dx; lp.y = oy + dy
                    try { m.updateViewLayout(v, lp) } catch (_: Exception) {}
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) peek()
                    true
                }
                else -> false
            }
        }
        try { m.addView(v, lp); bubble = v } catch (_: Exception) { stopSelf() }
    }

    private fun peek() {
        val i = Intent(this, ClipboardPeekActivity::class.java)
            .putExtra("t0", SystemClock.uptimeMillis())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        try { startActivity(i) } catch (_: Exception) {}
    }

    /** A copy is probably happening: a short attention pulse on the bubble. */
    fun pulse() {
        val v = bubble ?: return
        v.post {
            v.animate().cancel()
            v.scaleX = 1f; v.scaleY = 1f
            v.animate().scaleX(1.35f).scaleY(1.35f).setDuration(220).withEndAction {
                v.animate().scaleX(1f).scaleY(1f).setDuration(220).withEndAction {
                    v.animate().scaleX(1.35f).scaleY(1.35f).setDuration(220).withEndAction {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(220).start()
                    }.start()
                }.start()
            }.start()
        }
    }

    fun prompt(url: String) {
        LinkPrompt.show(this, if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE, url)
    }

    override fun onDestroy() {
        try { bubble?.let { wm?.removeView(it) } } catch (_: Exception) {}
        bubble = null
        LinkPrompt.dismiss()
        instance = null
        super.onDestroy()
    }
}

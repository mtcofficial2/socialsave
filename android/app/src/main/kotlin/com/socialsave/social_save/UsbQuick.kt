package com.socialsave.social_save

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 1.0.46: when a USB cable links this phone to a computer (USB data, not
 * just a charger), show one heads-up notification "Connected to PC by USB"
 * with a "Share files" action that opens the share session screen.
 *
 * Listens to the system USB_STATE broadcast while SocialSave's process is
 * alive (the app, its link bubble or a running session). No polling. Once
 * per plug-in; the state already present when we start listening is not
 * announced. Off with the "USB cable: offer Share files" setting.
 */
object UsbQuick {
    private const val TAG = "SocialSaveUsb"
    const val CHANNEL = "socialsave_usb"
    private const val NOTIFY_ID = 0x5553
    private const val PREF = "flutter.socialsave_usbQuickAction"
    private var registered = false
    private var announced = false

    fun register(c: Context) {
        if (registered) return
        registered = true
        val app = c.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, i: Intent) {
                val connected = i.getBooleanExtra("connected", false)
                val configured = i.getBooleanExtra("configured", false)
                if (!connected) {
                    if (announced) cancel(app)
                    announced = false
                    return
                }
                if (isInitialStickyBroadcast) {
                    // Already plugged in when we started: don't announce it.
                    announced = true
                    return
                }
                if (announced || !configured) return
                announced = true
                notify(app)
            }
        }
        try {
            val f = IntentFilter("android.hardware.usb.action.USB_STATE")
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, f, Context.RECEIVER_EXPORTED)
            } else {
                app.registerReceiver(receiver, f)
            }
        } catch (e: Exception) {
            Log.w(TAG, "register failed: $e")
        }
    }

    private fun enabled(c: Context): Boolean = try {
        c.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean(PREF, true)
    } catch (_: Exception) {
        true
    }

    fun notify(c: Context) {
        if (!enabled(c)) return
        Log.i(TAG, "usb plugged: offering Share files")
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "USB cable", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Share files when a USB cable connects to a PC"
                    setSound(null, null)
                }
            )
        }
        val open = Intent(c, MainActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_QUICK_ACTION, "usb_share")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            c, 0x55, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Connected to PC by USB")
            .setContentText("Share files: send and receive over the cable")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .addAction(0, "Share files", pi)
            .build()
        try {
            nm.notify(NOTIFY_ID, n)
        } catch (e: SecurityException) {
            Log.w(TAG, "no notification permission: $e")
        }
    }

    fun cancel(c: Context) {
        try {
            (c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFY_ID)
        } catch (_: Exception) {}
    }
}

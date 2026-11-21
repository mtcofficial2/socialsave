package com.socialsave.social_save

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

/**
 * Asks the owner back when Social Save has sat closed for about six hours,
 * then again through the day until they open it. Quiet from 22:00 to 08:00.
 * Lines stay the same as returnReminderLines in return_reminder.dart.
 */
object ReturnReminder {
    private const val request = 51
    private const val notice = 51
    private const val channelId = "return_reminders"
    private const val gapMs = 6L * 60L * 60L * 1000L
    private const val enabledKey = "flutter.socialsave_returnReminders"
    private const val openedKey = "flutter.socialsave_lastOpenMs"
    private val lines = arrayOf(
        "Social Save is still here. Open it to save a video or check your chats.",
        "You have not opened Social Save in a while. Your library is waiting.",
        "Open Social Save so it stays easy to find on this phone.",
        "A quick visit keeps Social Save close. Paste a link or open a chat.",
    )

    fun install(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, "socialsave/return_reminder").setMethodCallHandler { call, result ->
            when (call.method) {
                "schedule" -> {
                    val at = call.argument<Number>("at")?.toLong() ?: 0L
                    hide(app)
                    schedule(app, at)
                    result.success(true)
                }
                "cancel" -> {
                    cancel(app)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun scheduleFromPrefs(context: Context) {
        val app = context.applicationContext
        val prefs = prefs(app)
        if (!enabled(prefs)) return
        val opened = prefs.getLong(openedKey, 0L)
        val now = System.currentTimeMillis()
        val base = if (opened <= 0L) now else opened
        schedule(app, nextAt(base, now))
    }

    fun schedule(context: Context, at: Long) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val whenAt = if (at <= System.currentTimeMillis()) {
            System.currentTimeMillis() + 60_000L
        } else {
            at
        }
        try {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenAt, pending(app))
        } catch (e: Exception) {
            Log.w("SocialSave", "return reminder: $e")
            try {
                am.set(AlarmManager.RTC_WAKEUP, whenAt, pending(app))
            } catch (again: Exception) {
                Log.w("SocialSave", "return reminder fallback: $again")
            }
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(app))
        hide(app)
    }

    fun onAlarm(context: Context) {
        val app = context.applicationContext
        val prefs = prefs(app)
        if (!enabled(prefs)) {
            cancel(app)
            return
        }
        val now = System.currentTimeMillis()
        val opened = prefs.getLong(openedKey, 0L)
        val fresh = opened > 0L && now - opened < gapMs
        if (fresh || quiet(now)) {
            val base = if (opened > 0L) opened else now
            schedule(app, nextAt(base, now))
            return
        }
        show(app, now)
        schedule(app, nextAt(now, now))
    }

    private fun show(context: Context, now: Long) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Reminders",
                NotificationManager.IMPORTANCE_HIGH,
            )
            channel.description = "A reminder when Social Save has not been opened"
            channel.enableVibration(true)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            context,
            request,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val cal = Calendar.getInstance()
        cal.timeInMillis = now
        val text = lines[(cal.get(Calendar.DAY_OF_YEAR) - 1).mod(lines.size)]
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_return_reminder)
            .setContentTitle("Open Social Save")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        manager.notify(notice, notification)
    }

    private fun hide(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notice)
    }

    private fun pending(context: Context): PendingIntent {
        val intent = Intent(context, ReturnReminderReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            request,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    private fun enabled(prefs: android.content.SharedPreferences): Boolean {
        if (!prefs.contains(enabledKey)) return true
        return prefs.getBoolean(enabledKey, true)
    }

    private fun nextAt(lastOpen: Long, now: Long): Long {
        var at = lastOpen + gapMs
        if (at <= now) at = now + 60_000L
        return awake(at)
    }

    private fun quiet(at: Long): Boolean {
        val cal = Calendar.getInstance()
        cal.timeInMillis = at
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        return hour >= 22 || hour < 8
    }

    private fun awake(at: Long): Long {
        if (!quiet(at)) return at
        val cal = Calendar.getInstance()
        cal.timeInMillis = at
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        if (hour >= 22) cal.add(Calendar.DAY_OF_YEAR, 1)
        cal.set(Calendar.HOUR_OF_DAY, 8)
        cal.set(Calendar.MINUTE, 15)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}

class ReturnReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        ReturnReminder.onAlarm(context.applicationContext)
    }
}

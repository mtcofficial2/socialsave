package com.socialsave.social_save

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/**
 * Wakes the message listener about once a minute, including during Doze.
 * The screen-on receiver cannot run after the process has been killed.
 */
object ChatListenAlarm {
    private const val request = 47
    private const val gapMs = 60_000L

    fun schedule(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val whenAt = System.currentTimeMillis() + gapMs
        try {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenAt, pending(app))
        } catch (e: Exception) {
            Log.w("SocialSaveChat", "listen alarm: $e")
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(app))
    }

    private fun pending(context: Context): PendingIntent {
        val intent = Intent(context, ChatListenAlarmReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            request,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class ChatListenAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val app = context.applicationContext
        if (ChatWatch.credentials(app) == null) {
            ChatListenAlarm.cancel(app)
            return
        }
        ChatListenAlarm.schedule(app)
        val pendingResult = goAsync()
        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SocialSave:chatAlarm")
        lock.setReferenceCounted(false)
        lock.acquire(40_000L)
        Thread {
            try {
                try {
                    ChatListenService.start(app)
                } catch (_: Exception) {
                }
                ChatWatch.pullBlocking(app)
                try {
                    Thread.sleep(3_000)
                } catch (_: InterruptedException) {
                }
                ChatWatch.pullBlocking(app)
            } finally {
                try {
                    if (lock.isHeld) lock.release()
                } catch (_: Exception) {
                }
                pendingResult.finish()
            }
        }.start()
    }
}

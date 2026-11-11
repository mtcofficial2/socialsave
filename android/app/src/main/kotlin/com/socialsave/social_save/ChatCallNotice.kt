package com.socialsave.social_save

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import org.json.JSONObject

/// Incoming audio call. Answer opens that call. Hang up declines it here,
/// so the phone does not have to be unlocked first.
object ChatCallNotice {
    const val ACTION_DECLINE = "com.socialsave.social_save.CALL_DECLINE"
    const val EXTRA_ACTION = "socialsave.call.action"
    const val EXTRA_ID = "socialsave.call.id"
    const val NOTICE_ID = 910085
    private const val channelId = "calls_v2"
    private val idPattern = Regex("^[A-Za-z0-9]{2,80}$")

    fun show(context: Context, callId: String, name: String, api: String, token: String) {
        val id = callId.trim()
        if (!idPattern.matches(id)) return
        val who = name.trim().ifEmpty { "Audio call" }
        ensureChannel(context)
        val fullScreen = if (Build.VERSION.SDK_INT >= 34) {
            context.getSystemService(NotificationManager::class.java)?.canUseFullScreenIntent() == true
        } else {
            true
        }
        val open = activity(context, "open", id, 0x0C11)
        val answer = activity(context, "answer", id, 0x0C12)
        val decline = PendingIntent.getBroadcast(
            context,
            0x0C13,
            Intent(context, ChatCallReceiver::class.java)
                .setAction(ACTION_DECLINE)
                .setData(Uri.parse("socialsave://call/$id"))
                .putExtra(EXTRA_ID, id)
                .putExtra(ChatReply.EXTRA_API, api)
                .putExtra(ChatReply.EXTRA_TOKEN, token),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val built = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(who)
            .setContentText("Incoming audio call")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Incoming audio call"))
            .setContentIntent(open)
            .setDeleteIntent(decline)
            .apply { if (fullScreen) setFullScreenIntent(open, true) }
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(0xFF00C853.toInt())
            .setColorized(true)
            .setOngoing(false)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(50_000)
            .addAction(
                NotificationCompat.Action.Builder(R.drawable.ic_notification, "Answer", answer)
                    .setShowsUserInterface(true)
                    .build(),
            )
            .addAction(
                NotificationCompat.Action.Builder(R.drawable.ic_notification, "Hang up", decline)
                    .setShowsUserInterface(false)
                    .build(),
            )
            .build()
        built.flags = built.flags or Notification.FLAG_INSISTENT
        try {
            NotificationManagerCompat.from(context).notify(NOTICE_ID, built)
        } catch (_: Exception) {
        }
    }

    fun cancel(context: Context) {
        try {
            NotificationManagerCompat.from(context).cancel(NOTICE_ID)
        } catch (_: Exception) {
        }
    }

    /// Declines only while the call is still ringing. An answered call is left alone.
    fun decline(api: String, token: String, callId: String): Boolean {
        val id = callId.trim()
        if (!idPattern.matches(id) || token.isBlank()) return false
        val base = api.trim().trimEnd('/')
        val uri = try {
            URI(base)
        } catch (_: Exception) {
            return false
        }
        if (!uri.scheme.equals("https", true) || uri.host.isNullOrBlank() || uri.userInfo != null) {
            return false
        }
        val connection = (URL("$base/api/v1/chat/calls/$id/answer").openConnection() as HttpURLConnection)
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.instanceFollowRedirects = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-Chat-Token", token)
            val bytes = JSONObject().put("accept", false).toString().toByteArray(Charsets.UTF_8)
            connection.outputStream.use { it.write(bytes) }
            connection.responseCode in 200..299
        } catch (_: Exception) {
            false
        } finally {
            connection.disconnect()
        }
    }

    private fun activity(context: Context, action: String, callId: String, code: Int): PendingIntent {
        return PendingIntent.getActivity(
            context,
            code,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(EXTRA_ACTION, action)
                .putExtra(EXTRA_ID, callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(channelId) != null) return
        val audio = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(channelId, "Calls", NotificationManager.IMPORTANCE_MAX)
        channel.description = "Incoming audio calls"
        channel.setSound(Uri.parse("android.resource://${context.packageName}/${R.raw.ss_ring}"), audio)
        channel.enableVibration(true)
        channel.vibrationPattern = longArrayOf(0, 500, 200, 500)
        channel.enableLights(true)
        channel.lightColor = 0xFF00C853.toInt()
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }
}

class ChatCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ChatCallNotice.ACTION_DECLINE) return
        val pending = goAsync()
        val app = context.applicationContext
        val id = intent.getStringExtra(ChatCallNotice.EXTRA_ID).orEmpty()
        val api = intent.getStringExtra(ChatReply.EXTRA_API).orEmpty()
        val token = intent.getStringExtra(ChatReply.EXTRA_TOKEN).orEmpty()
        ChatCallNotice.cancel(app)
        ChatReplyBridge.tellCall("decline|$id")
        Thread {
            try {
                if (api.isNotEmpty() && token.isNotEmpty()) {
                    ChatCallNotice.decline(api, token, id)
                } else {
                    val stored = ChatWatch.credentials(app)
                    if (stored != null) ChatCallNotice.decline(stored.api, stored.token, id)
                }
            } finally {
                pending.finish()
            }
        }.start()
    }
}

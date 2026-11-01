package com.socialsave.social_save

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import org.json.JSONObject

/// Reply typed on a chat notification.
///
/// The reply is posted here, not by opening Social Save. Opening the app
/// dropped the person into that chat. A second Flutter engine for a
/// background reply never finished, so the spinner stayed up.
object ChatReplyBridge {
    private const val channelName = "socialsave/chat_notify"
    private var channel: MethodChannel? = null
    private var listening = false
    private var pending: String? = null

    fun install(context: Context, messenger: BinaryMessenger) {
        val next = MethodChannel(messenger, channelName)
        channel = next
        next.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    ChatReply.show(context.applicationContext, call)
                    result.success(null)
                }
                "pending" -> {
                    listening = true
                    val value = pending
                    pending = null
                    result.success(value)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun note(intent: Intent?) {
        val payload = intent?.getStringExtra(ChatReply.EXTRA_OPEN) ?: return
        if (!payload.startsWith("chat|")) return
        intent.removeExtra(ChatReply.EXTRA_OPEN)
        if (listening) {
            channel?.invokeMethod("opened", payload)
        } else {
            pending = payload
        }
    }
}

object ChatReply {
    const val ACTION = "com.socialsave.social_save.CHAT_REPLY"
    const val EXTRA_OPEN = "socialsave.chat.open"
    const val EXTRA_ID = "socialsave.chat.id"
    const val EXTRA_PAYLOAD = "socialsave.chat.payload"
    const val EXTRA_API = "socialsave.chat.api"
    const val EXTRA_TOKEN = "socialsave.chat.token"
    const val KEY_TEXT = "socialsave.chat.reply"
    private const val channelLoud = "chats_v2"
    private const val channelQuiet = "chats_quiet"
    private const val failedId = 0x52454641
    private val threadId = Regex("^[A-Za-z0-9]{2,80}$")

    fun show(context: Context, call: MethodCall) {
        val rawId = call.argument<Any>("id")
        val id = when (rawId) {
            is Int -> rawId
            is Long -> rawId.toInt()
            else -> return
        }
        val title = call.argument<String>("title")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        val payload = call.argument<String>("payload")?.trim().orEmpty()
        if (title.isEmpty() || !payload.startsWith("chat|")) return
        val sound = call.argument<Boolean>("sound") != false
        val api = call.argument<String>("api")?.trim().orEmpty()
        val token = call.argument<String>("token")?.trim().orEmpty()
        ensureChannels(context)
        val open = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(EXTRA_OPEN, payload),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val replyIntent = Intent(context, ChatReplyReceiver::class.java)
            .setAction(ACTION)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_PAYLOAD, payload)
            .putExtra(EXTRA_API, api)
            .putExtra(EXTRA_TOKEN, token)
        val replyFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val reply = PendingIntent.getBroadcast(
            context,
            id,
            replyIntent,
            replyFlags,
        )
        val input = RemoteInput.Builder(KEY_TEXT).setLabel("Message").build()
        val action = NotificationCompat.Action.Builder(0, "Reply", reply)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(true)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()
        val logo = BitmapFactory.decodeResource(context.resources, R.drawable.ic_notification_logo)
        val face = faceOf(call.argument<ByteArray>("picture"))
        val notification = NotificationCompat.Builder(context, if (sound) channelLoud else channelQuiet)
            .setSmallIcon(R.drawable.ic_notification)
            .setLargeIcon(face ?: logo)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .addAction(action)
            .build()
        NotificationManagerCompat.from(context).notify(id, notification)
    }

    fun post(api: String, token: String, payload: String, text: String): Boolean {
        val id = threadOf(payload) ?: return false
        if (token.isBlank() || text.isBlank()) return false
        val base = api.trim().trimEnd('/')
        val uri = try {
            URI(base)
        } catch (_: Exception) {
            return false
        }
        if (!uri.scheme.equals("https", true) || uri.host.isNullOrBlank() || uri.userInfo != null) {
            return false
        }
        val connection = (URL("$base/api/v1/chat/threads/$id").openConnection() as HttpURLConnection)
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15000
            connection.readTimeout = 45000
            connection.instanceFollowRedirects = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-Chat-Token", token)
            val bytes = JSONObject().put("text", text).toString().toByteArray(Charsets.UTF_8)
            connection.outputStream.use { it.write(bytes) }
            connection.responseCode in 200..299
        } catch (_: Exception) {
            false
        } finally {
            connection.disconnect()
        }
    }

    fun failed(context: Context) {
        ensureChannels(context)
        val notification = NotificationCompat.Builder(context, channelLoud)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Message not sent")
            .setContentText("Open the chat and send it again.")
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        NotificationManagerCompat.from(context).notify(failedId, notification)
    }

    private fun faceOf(bytes: ByteArray?): Bitmap? {
        if (bytes == null || bytes.isEmpty()) return null
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val side = minOf(decoded.width, decoded.height)
        if (side <= 0) return null
        val left = (decoded.width - side) / 2
        val top = (decoded.height - side) / 2
        val square = Bitmap.createBitmap(decoded, left, top, side, side)
        val size = 192
        val scaled = if (side == size) square else Bitmap.createScaledBitmap(square, size, size, true)
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(scaled, 0f, 0f, paint)
        return out
    }

    private fun threadOf(payload: String): String? {
        val parts = payload.split('|')
        if (parts.size < 2 || parts[0] != "chat") return null
        val id = parts[1].trim()
        if (!threadId.matches(id)) return null
        return id
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val loud = NotificationChannel(channelLoud, "Chats", NotificationManager.IMPORTANCE_HIGH)
        loud.description = "New messages"
        val quiet = NotificationChannel(channelQuiet, "Chats", NotificationManager.IMPORTANCE_LOW)
        quiet.description = "New messages"
        quiet.setSound(null, null)
        quiet.enableVibration(false)
        manager.createNotificationChannel(loud)
        manager.createNotificationChannel(quiet)
    }
}

class ChatReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ChatReply.ACTION) return
        val pending = goAsync()
        val app = context.applicationContext
        val id = intent.getIntExtra(ChatReply.EXTRA_ID, 0)
        NotificationManagerCompat.from(app).cancel(id)
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(ChatReply.KEY_TEXT)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (text.isEmpty()) {
            pending.finish()
            return
        }
        val payload = intent.getStringExtra(ChatReply.EXTRA_PAYLOAD).orEmpty()
        val api = intent.getStringExtra(ChatReply.EXTRA_API).orEmpty()
        val token = intent.getStringExtra(ChatReply.EXTRA_TOKEN).orEmpty()
        Thread {
            try {
                if (!ChatReply.post(api, token, payload, text)) ChatReply.failed(app)
            } catch (_: Exception) {
                ChatReply.failed(app)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

package com.socialsave.social_save

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.net.Uri
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger
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
        try {
            showInner(context, call)
        } catch (t: Throwable) {
            Log.e("SocialSaveReply", "notification failed", t)
            showPlain(context, call)
        }
    }

    private fun showInner(context: Context, call: MethodCall) {
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
        // The tap action is immutable. One UI 7 drops the reply text when the
        // reply uses that same PendingIntent, and then tells the person to
        // open the app. The reply has its own request code and starts a
        // foreground service, which is allowed because they tapped Send.
        val reply = replyPending(context, id, payload, api, token)
        val input = RemoteInput.Builder(KEY_TEXT).setLabel("Message").build()
        val action = NotificationCompat.Action.Builder(R.drawable.ic_notification, "Reply", reply)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(false)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()
        val silent = call.argument<Boolean>("silent") == true
        val faces = try {
            facesOf(pictureBytes(call))
        } catch (_: Exception) {
            null
        }
        val builder = NotificationCompat.Builder(context, if (sound) channelLoud else channelQuiet)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .setSilent(silent)
            .addAction(action)
        if (faces != null) {
            // Android 12 uses the shortcut icon as the profile circle. The app
            // logo in that slot is what was covering the sender.
            val shortcutId = shortcutIdOf(payload)
            val personIcon = IconCompat.createWithBitmap(faces.circle)
            val sender = Person.Builder()
                .setName(title)
                .setKey(shortcutId)
                .setIcon(personIcon)
                .setImportant(true)
                .build()
            val me = Person.Builder().setName("You").setKey("socialsave-me").build()
            builder
                .setLargeIcon(faces.circle)
                .setStyle(
                    NotificationCompat.MessagingStyle(me)
                        .setGroupConversation(false)
                        .addMessage(body, System.currentTimeMillis(), sender),
                )
                .addPerson(sender)
            if (publishFace(context, shortcutId, title, faces.square, sender, payload)) {
                builder.setShortcutId(shortcutId).setLocusId(LocusIdCompat(shortcutId))
            }
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        }
        NotificationManagerCompat.from(context).notify(id, builder.build())
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

    private class FaceBitmaps(val square: Bitmap, val circle: Bitmap)

    private fun pictureBytes(call: MethodCall): ByteArray? {
        val args = call.arguments as? Map<*, *> ?: return null
        val raw = args["picture"] ?: return null
        return when (raw) {
            is ByteArray -> if (raw.isEmpty()) null else raw
            is List<*> -> {
                if (raw.isEmpty()) return null
                val out = ByteArray(raw.size)
                for (i in raw.indices) {
                    val n = raw[i] as? Number ?: return null
                    out[i] = n.toInt().toByte()
                }
                out
            }
            else -> null
        }
    }

    private fun facesOf(bytes: ByteArray?): FaceBitmaps? {
        if (bytes == null || bytes.isEmpty()) return null
        val decoded = decodeSampled(bytes) ?: return null
        val side = minOf(decoded.width, decoded.height)
        if (side <= 0) return null
        val left = (decoded.width - side) / 2
        val top = (decoded.height - side) / 2
        val cropped = Bitmap.createBitmap(decoded, left, top, side, side)
        val size = 192
        val square = if (cropped.width == size && cropped.height == size) {
            cropped
        } else {
            Bitmap.createScaledBitmap(cropped, size, size, true)
        }
        val circle = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(circle)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(square, 0f, 0f, paint)
        return FaceBitmaps(square, circle)
    }

    private fun decodeSampled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        val maxSide = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxSide / sample > 512) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    private fun shortcutIdOf(payload: String): String {
        val id = threadOf(payload)
        if (id != null) return "c$id"
        return "c${payload.hashCode().toUInt().toString(16)}"
    }

    private fun replyPending(
        context: Context,
        id: Int,
        payload: String,
        api: String,
        token: String,
    ): PendingIntent {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val code = id xor 0x5A5A5A5A
        val data = Uri.parse("socialsave://reply/$id")
        fun fill(target: Intent): Intent = target
            .setAction(ACTION)
            .setData(data)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_PAYLOAD, payload)
            .putExtra(EXTRA_API, api)
            .putExtra(EXTRA_TOKEN, token)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                return PendingIntent.getForegroundService(
                    context,
                    code,
                    fill(Intent(context, ChatReplyService::class.java)),
                    flags,
                )
            } catch (t: Throwable) {
                Log.w("SocialSaveReply", "service reply refused", t)
            }
        }
        return PendingIntent.getBroadcast(
            context,
            code,
            fill(Intent(context, ChatReplyReceiver::class.java)),
            flags,
        )
    }

    private fun showPlain(context: Context, call: MethodCall) {
        try {
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
            val api = call.argument<String>("api")?.trim().orEmpty()
            val token = call.argument<String>("token")?.trim().orEmpty()
            val sound = call.argument<Boolean>("sound") != false
            ensureChannels(context)
            val open = PendingIntent.getActivity(
                context,
                id,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    .putExtra(EXTRA_OPEN, payload),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val input = RemoteInput.Builder(KEY_TEXT).setLabel("Message").build()
            val action = NotificationCompat.Action.Builder(
                R.drawable.ic_notification,
                "Reply",
                replyPending(context, id, payload, api, token),
            )
                .addRemoteInput(input)
                .setAllowGeneratedReplies(false)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
                .setShowsUserInterface(false)
                .build()
            val notification = NotificationCompat.Builder(
                context,
                if (sound) channelLoud else channelQuiet,
            )
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .addAction(action)
                .build()
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (t: Throwable) {
            Log.e("SocialSaveReply", "plain notification failed", t)
        }
    }

    fun markSending(context: Context, id: Int, payload: String) {
        if (id == 0) return
        try {
            ensureChannels(context)
            val title = titleOf(payload)
            val notification = NotificationCompat.Builder(context, channelQuiet)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText("Sending…")
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (_: Exception) {
        }
    }

    private fun titleOf(payload: String): String {
        val parts = payload.split('|')
        if (parts.size < 3 || parts[0] != "chat") return "Social Save"
        val title = parts.drop(2).joinToString("|").trim()
        return if (title.isEmpty()) "Social Save" else title
    }

    private fun publishFace(
        context: Context,
        shortcutId: String,
        title: String,
        square: Bitmap,
        sender: Person,
        payload: String,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return false
        return try {
            val label = if (title.length > 40) title.substring(0, 40) else title
            val open = Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN, payload)
            val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(label)
                .setLongLived(true)
                .setRank(0)
                .setIcon(IconCompat.createWithAdaptiveBitmap(square))
                .setIntent(open)
                .setPerson(sender)
                .setCategories(setOf("android.shortcut.conversation"))
                .setLocusId(LocusIdCompat(shortcutId))
                .build()
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
            ShortcutManagerCompat.reportShortcutUsed(context, shortcutId)
            true
        } catch (_: Exception) {
            false
        }
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

/**
 * Sends the notification reply. One UI 7 does not deliver a reply broadcast
 * while Social Save is asleep, and tells the person to open the app. The
 * reply button starts this service directly, which Android allows because
 * the person tapped the notification.
 */
class ChatReplyService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = applicationContext
        val incoming = intent
        goForeground()
        val text = if (incoming == null) {
            ""
        } else {
            RemoteInput.getResultsFromIntent(incoming)
                ?.getCharSequence(ChatReply.KEY_TEXT)
                ?.toString()
                ?.trim()
                .orEmpty()
        }
        if (incoming == null || incoming.action != ChatReply.ACTION || text.isEmpty()) {
            stopIfIdle()
            return START_NOT_STICKY
        }
        val id = incoming.getIntExtra(ChatReply.EXTRA_ID, 0)
        val payload = incoming.getStringExtra(ChatReply.EXTRA_PAYLOAD).orEmpty()
        val api = incoming.getStringExtra(ChatReply.EXTRA_API).orEmpty()
        val token = incoming.getStringExtra(ChatReply.EXTRA_TOKEN).orEmpty()
        ChatReply.markSending(app, id, payload)
        inflight.incrementAndGet()
        holdWake(app)
        Thread {
            try {
                val sent = ChatReply.post(api, token, payload, text)
                if (id != 0) NotificationManagerCompat.from(app).cancel(id)
                if (!sent) ChatReply.failed(app)
            } catch (_: Exception) {
                if (id != 0) NotificationManagerCompat.from(app).cancel(id)
                ChatReply.failed(app)
            } finally {
                if (inflight.decrementAndGet() == 0) {
                    dropWake()
                    Handler(Looper.getMainLooper()).post { stopIfIdle() }
                }
            }
        }.start()
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val notification = statusNotification(this)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                try {
                    startForeground(
                        STATUS_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "remoteMessaging refused, using dataSync: $e")
                    startForeground(
                        STATUS_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                }
            } else if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    STATUS_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(STATUS_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "reply foreground refused: $e")
        }
    }

    private fun stopIfIdle() {
        if (inflight.get() != 0) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
        }
        stopSelf()
    }

    companion object {
        private const val TAG = "SocialSaveReply"
        private const val STATUS_ID = 4813
        private val inflight = AtomicInteger(0)
        private var wake: PowerManager.WakeLock? = null

        private fun holdWake(context: Context) {
            if (wake != null) return
            try {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SocialSave:reply").apply {
                    setReferenceCounted(false)
                    acquire(60_000L)
                }
            } catch (e: Exception) {
                Log.w(TAG, "wake lock: $e")
            }
        }

        private fun dropWake() {
            try {
                wake?.release()
            } catch (_: Exception) {
            }
            wake = null
        }

        private fun statusNotification(context: Context): android.app.Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(NotificationManager::class.java)
                if (manager != null && manager.getNotificationChannel(ChatListenService.CHANNEL_ID) == null) {
                    manager.createNotificationChannel(
                        NotificationChannel(
                            ChatListenService.CHANNEL_ID,
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
            }
            return NotificationCompat.Builder(context, ChatListenService.CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Social Save")
                .setContentText("Sending a message")
                .setSilent(true)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }
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

package com.socialsave.social_save

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.media.AudioAttributes
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
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
    private var pendingCall: String? = null

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
                "pendingCall" -> {
                    listening = true
                    val value = pendingCall
                    pendingCall = null
                    result.success(value)
                }
                "showCall" -> {
                    val callId = call.argument<String>("id")?.trim().orEmpty()
                    val name = call.argument<String>("name")?.trim().orEmpty()
                    val api = call.argument<String>("api")?.trim().orEmpty()
                    val token = call.argument<String>("token")?.trim().orEmpty()
                    ChatCallNotice.show(context.applicationContext, callId, name, api, token)
                    result.success(null)
                }
                "cancelCall" -> {
                    ChatCallNotice.cancel(context.applicationContext)
                    result.success(null)
                }
                "hidePop" -> {
                    ChatPop.dismiss(cancelNotice = false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun note(intent: Intent?) {
        val payload = intent?.getStringExtra(ChatReply.EXTRA_OPEN)
        if (payload != null && payload.startsWith("chat|")) {
            intent.removeExtra(ChatReply.EXTRA_OPEN)
            if (listening) {
                channel?.invokeMethod("opened", payload)
            } else {
                pending = payload
            }
        }
        val action = intent?.getStringExtra(ChatCallNotice.EXTRA_ACTION)?.trim().orEmpty()
        val callId = intent?.getStringExtra(ChatCallNotice.EXTRA_ID)?.trim().orEmpty()
        if (action != "answer" && action != "open" && action != "decline") return
        if (callId.isEmpty()) return
        intent?.removeExtra(ChatCallNotice.EXTRA_ACTION)
        val notice = "$action|$callId"
        if (listening) {
            channel?.invokeMethod("call", notice)
        } else {
            pendingCall = notice
        }
    }

    fun tellCall(payload: String) {
        if (payload.isEmpty()) return
        if (!listening) {
            pendingCall = payload
            return
        }
        try {
            channel?.invokeMethod("call", payload)
        } catch (_: Exception) {
        }
    }

    fun tellMute(threadId: String) {
        if (!listening || threadId.isEmpty()) return
        try {
            channel?.invokeMethod("muted", threadId)
        } catch (_: Exception) {
        }
    }

    enum class EngineReply { Sent, Refused, Away }

    /// Asks the already-running app to send. A second engine is not started.
    /// Sent and Refused are final. Away means the app process is not listening,
    /// so the caller sends over HTTP itself.
    fun ask(payload: String, text: String): EngineReply {
        val messenger = channel
        if (!listening || messenger == null) return EngineReply.Away
        if (Looper.myLooper() == Looper.getMainLooper()) return EngineReply.Away
        val latch = CountDownLatch(1)
        val box = AtomicReference(EngineReply.Away)
        Handler(Looper.getMainLooper()).post {
            try {
                messenger.invokeMethod(
                    "reply",
                    mapOf("payload" to payload, "text" to text),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            box.set(
                                if (result == true) EngineReply.Sent else EngineReply.Refused,
                            )
                            latch.countDown()
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) {
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            latch.countDown()
                        }
                    },
                )
            } catch (_: Exception) {
                latch.countDown()
            }
        }
        val finished = try {
            latch.await(80, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            false
        }
        if (!finished) {
            Log.w("SocialSaveReply", "reply engine timed out")
            return EngineReply.Refused
        }
        return box.get()
    }
}

object ChatReply {
    const val ACTION = "com.socialsave.social_save.CHAT_REPLY"
    const val ACTION_MUTE = "com.socialsave.social_save.CHAT_MUTE"
    const val ACTION_DISMISS = "com.socialsave.social_save.CHAT_DISMISS"
    const val EXTRA_OPEN = "socialsave.chat.open"
    const val EXTRA_ID = "socialsave.chat.id"
    const val EXTRA_PAYLOAD = "socialsave.chat.payload"
    const val EXTRA_API = "socialsave.chat.api"
    const val EXTRA_TOKEN = "socialsave.chat.token"
    const val KEY_TEXT = "socialsave.chat.reply"
    private const val channelLoud = "chats_v3"
    private const val channelQuiet = "chats_quiet"
    private const val holdMs = 300_000L
    private val attention = 0xFF00C853.toInt()
    private var brand: Bitmap? = null
    private const val failedId = 0x52454641
    private const val replyPrefs = "socialsave_chat_reply"
    private val threadPattern = Regex("^[A-Za-z0-9]{2,80}$")

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
        // The tap action is immutable, so the reply must use its own request
        // code or One UI 7 opens the app instead of sending. Android 14+
        // starts a foreground service for that send. Android 13 and older,
        // including the AQUOS, keep the broadcast that already sends.
        val reply = replyPending(context, id, payload, api, token)
        val input = RemoteInput.Builder(KEY_TEXT).setLabel("Message").build()
        val action = NotificationCompat.Action.Builder(R.drawable.ic_notification, "Reply", reply)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(true)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()
        val mute = muteAction(context, id, payload)
        val dismiss = dismissAction(context, id)
        val silent = call.argument<Boolean>("silent") == true
        val faces = try {
            facesOf(pictureBytes(call))
        } catch (_: Exception) {
            null
        }
        val alert = sound && !silent
        val builder = NotificationCompat.Builder(context, channelLoud)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(!alert)
            .setSilent(!alert)
            .setShowWhen(true)
            .addAction(action)
            .addAction(dismiss)
            .addAction(mute)
        dress(builder, alert)
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
            asMessage(context, builder, title, body, brandIcon(context))
        }
        deliver(context, builder, alert, id, title, body, payload, api, token)
    }

    /// Keeps the chat and the sign-in beside the notice. A reply on some
    /// phones arrives with the typed text and without these extras.
    fun remember(context: Context, id: Int, payload: String, api: String, token: String) {
        if (id == 0) return
        val edit = context.applicationContext
            .getSharedPreferences(replyPrefs, Context.MODE_PRIVATE)
            .edit()
        if (payload.isNotBlank() && threadOf(payload) != null) {
            edit.putString("p$id", payload)
            edit.putString("latest", payload)
        }
        val base = api.trim().trimEnd('/')
        if (base.isNotEmpty()) edit.putString("api", base)
        val key = token.trim()
        if (key.isNotEmpty()) edit.putString("token", key)
        edit.commit()
    }

    /// Sends a reply that was typed on a notice. Reads the chat and the
    /// sign-in from the intent, then from the copy saved when the notice
    /// was posted, then from the signed-in phone.
    fun isReply(action: String?): Boolean {
        return action == ACTION || (action != null && action.startsWith("$ACTION/"))
    }

    fun postedId(intent: Intent): Int {
        val id = noticeId(intent)
        if (id != 0) return id
        return replyParts(intent.action)?.first ?: 0
    }

    fun sendFrom(context: Context, intent: Intent, text: String): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(replyPrefs, Context.MODE_PRIVATE)
        val fromAction = replyParts(intent.action)
        var id = noticeId(intent)
        if (id == 0) id = fromAction?.first ?: 0
        var payload = intent.getStringExtra(EXTRA_PAYLOAD).orEmpty()
        if (threadOf(payload) == null) {
            val saved = if (id != 0) prefs.getString("p$id", null).orEmpty() else ""
            val fromUri = payloadFromUri(intent.data)
            val latest = prefs.getString("latest", null).orEmpty()
            payload = when {
                threadOf(saved) != null -> saved
                threadOf(fromUri) != null -> fromUri
                fromAction != null -> "chat|${fromAction.second}|"
                threadOf(latest) != null -> latest
                else -> ""
            }
        }
        if (threadOf(payload) == null) {
            Log.w("SocialSaveReply", "reply stopped thread=false api=false token=false")
            return false
        }
        return send(
            context,
            intent.getStringExtra(EXTRA_API).orEmpty(),
            intent.getStringExtra(EXTRA_TOKEN).orEmpty(),
            payload,
            text,
        )
    }

    fun send(context: Context, api: String, token: String, payload: String, text: String): Boolean {
        val clean = text.trim()
        val thread = threadOf(payload)
        if (thread == null || clean.isEmpty()) {
            Log.w("SocialSaveReply", "reply stopped thread=${thread != null} api=false token=false")
            return false
        }
        when (ChatReplyBridge.ask(payload, clean)) {
            ChatReplyBridge.EngineReply.Sent -> {
                Log.i("SocialSaveReply", "reply sent in app")
                return true
            }
            ChatReplyBridge.EngineReply.Refused -> {
                Log.w("SocialSaveReply", "reply refused in app")
                return false
            }
            ChatReplyBridge.EngineReply.Away -> Log.i("SocialSaveReply", "reply engine away")
        }
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(replyPrefs, Context.MODE_PRIVATE)
        val watch = ChatWatch.credentials(app)
        val apis = LinkedHashSet<String>()
        val tokens = LinkedHashSet<String>()
        fun addApi(value: String?) {
            val base = value?.trim()?.trimEnd('/').orEmpty()
            if (base.isNotEmpty()) apis.add(base)
        }
        fun addToken(value: String?) {
            val key = value?.trim().orEmpty()
            if (key.isNotEmpty()) tokens.add(key)
        }
        addApi(api)
        addApi(prefs.getString("api", null))
        addApi(watch?.api)
        addToken(token)
        addToken(prefs.getString("token", null))
        addToken(watch?.token)
        addToken(flutterToken(app))
        if (apis.isEmpty() || tokens.isEmpty()) {
            Log.w(
                "SocialSaveReply",
                "reply stopped thread=true api=${apis.isNotEmpty()} token=${tokens.isNotEmpty()}",
            )
            return false
        }
        for (key in tokens) {
            for (base in apis) {
                var code = attempt(base, key, thread, clean)
                if (code == -1) code = attempt(base, key, thread, clean)
                if (code in 200..299) {
                    Log.i("SocialSaveReply", "reply sent")
                    return true
                }
                if (code == 401 || code == 403 || code == -1) continue
                Log.w("SocialSaveReply", "reply http failed")
                return false
            }
        }
        Log.w("SocialSaveReply", "reply http failed")
        return false
    }

    private fun attempt(api: String, token: String, thread: String, text: String): Int {
        val base = api.trim().trimEnd('/')
        val uri = try {
            URI(base)
        } catch (_: Exception) {
            return -1
        }
        val host = uri.host
        if (!uri.scheme.equals("https", true) || host.isNullOrBlank() || uri.userInfo != null) {
            return -1
        }
        var url = "$base/api/v1/chat/threads/$thread"
        var hops = 0
        while (hops < 2) {
            val bytes = JSONObject().put("text", text).toString().toByteArray(Charsets.UTF_8)
            val connection = (URL(url).openConnection() as HttpURLConnection)
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 20000
                connection.readTimeout = 45000
                connection.instanceFollowRedirects = false
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.setRequestProperty("Accept", "application/json")
                connection.setRequestProperty("X-Chat-Token", token)
                connection.outputStream.use { it.write(bytes) }
                val code = connection.responseCode
                if (code in 300..399 && hops == 0) {
                    val next = connection.getHeaderField("Location")?.trim().orEmpty()
                    val dest = try {
                        URI(next)
                    } catch (_: Exception) {
                        null
                    }
                    if (dest != null &&
                        dest.scheme.equals("https", true) &&
                        host.equals(dest.host, true) &&
                        dest.userInfo == null
                    ) {
                        url = next
                        hops += 1
                        continue
                    }
                }
                if (code !in 200..299) Log.w("SocialSaveReply", "send status $code")
                return code
            } catch (e: Exception) {
                Log.w("SocialSaveReply", "send failed ${e.javaClass.simpleName}")
                return -1
            } finally {
                connection.disconnect()
            }
        }
        return -1
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
        // The thread id lives in the data, which a reply still carries when
        // the phone drops the extras.
        val thread = threadOf(payload) ?: "x"
        val data = Uri.Builder()
            .scheme("socialsave")
            .authority("reply")
            .appendPath(id.toString())
            .appendPath(thread)
            .build()
        fun fill(target: Intent): Intent = target
            .setAction("$ACTION/$id/$thread")
            .setData(data)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_PAYLOAD, payload)
            .putExtra(EXTRA_API, api)
            .putExtra(EXTRA_TOKEN, token)
        // getForegroundService is an Android 14+ exemption. On the AQUOS
        // (Android 12/13) that call is refused and the reply never leaves.
        if (Build.VERSION.SDK_INT >= 34) {
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
                .setAllowGeneratedReplies(true)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
                .setShowsUserInterface(false)
                .build()
            val mute = muteAction(context, id, payload)
            val dismiss = dismissAction(context, id)
            val alert = sound
            val builder = NotificationCompat.Builder(context, channelLoud)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setOnlyAlertOnce(!alert)
                .setSilent(!alert)
                .setShowWhen(true)
                .addAction(action)
                .addAction(dismiss)
                .addAction(mute)
            asMessage(context, builder, title, body, brandIcon(context))
            dress(builder, alert)
            deliver(context, builder, alert, id, title, body, payload, api, token)
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
        val seen = if (parts.size > 3) parts.drop(3).joinToString("|").trim() else ""
        if (seen.isNotEmpty()) return seen
        val title = parts[2].trim()
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

    fun applyMute(context: Context, intent: Intent) {
        val id = intent.getIntExtra(EXTRA_ID, 0)
        if (id != 0) {
            try {
                NotificationManagerCompat.from(context).cancel(id)
            } catch (_: Exception) {
            }
        }
        val thread = threadOf(intent.getStringExtra(EXTRA_PAYLOAD).orEmpty()) ?: return
        rememberMute(context, thread)
        ChatReplyBridge.tellMute(thread)
    }

    private fun muteAction(context: Context, id: Int, payload: String): NotificationCompat.Action {
        val pending = PendingIntent.getBroadcast(
            context,
            id xor 0x3C3C3C3C,
            Intent(context, ChatReplyReceiver::class.java)
                .setAction(ACTION_MUTE)
                .setData(Uri.parse("socialsave://mute/$id"))
                .putExtra(EXTRA_ID, id)
                .putExtra(EXTRA_PAYLOAD, payload),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(R.drawable.ic_notification, "Mute", pending)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MUTE)
            .setShowsUserInterface(false)
            .build()
    }

    private fun dismissAction(context: Context, id: Int): NotificationCompat.Action {
        val pending = PendingIntent.getBroadcast(
            context,
            id xor 0x17171717,
            Intent(context, ChatReplyReceiver::class.java)
                .setAction(ACTION_DISMISS)
                .setData(Uri.parse("socialsave://dismiss/$id"))
                .putExtra(EXTRA_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(R.drawable.ic_notification, "Cancel", pending)
            .setShowsUserInterface(false)
            .build()
    }

    /// Stays for five minutes unless it is cancelled, replied to, or swiped away.
    /// A loud notice also keeps a green popup up for that long.
    private fun dress(builder: NotificationCompat.Builder, loud: Boolean) {
        builder
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(attention)
            .setColorized(true)
            .setTimeoutAfter(holdMs)
        if (!loud) return
        builder
            .setLights(attention, 400, 180)
            .setVibrate(longArrayOf(0, 280, 120, 280, 120, 480))
    }

    private fun brandIcon(context: Context): Bitmap {
        brand?.let { return it }
        val raw = BitmapFactory.decodeResource(context.resources, R.drawable.ic_notification_logo)
        val bmp = if (raw == null) {
            Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        } else if (raw.width == 256 && raw.height == 256) {
            raw
        } else {
            Bitmap.createScaledBitmap(raw, 256, 256, true)
        }
        brand = bmp
        return bmp
    }

    /// The Social Save logo stands in for a missing face, the way a chat app
    /// keeps its own mark in the notification.
    private fun asMessage(
        context: Context,
        builder: NotificationCompat.Builder,
        title: String,
        body: String,
        icon: Bitmap,
    ) {
        val sender = Person.Builder()
            .setName(title)
            .setIcon(IconCompat.createWithBitmap(icon))
            .setImportant(true)
            .build()
        val me = Person.Builder().setName("You").setKey("socialsave-me").build()
        builder
            .setLargeIcon(icon)
            .setStyle(
                NotificationCompat.MessagingStyle(me)
                    .setGroupConversation(false)
                    .addMessage(body, System.currentTimeMillis(), sender),
            )
            .addPerson(sender)
    }

    private fun deliver(
        context: Context,
        builder: NotificationCompat.Builder,
        alert: Boolean,
        id: Int,
        title: String,
        body: String,
        payload: String,
        api: String,
        token: String,
    ) {
        remember(context, id, payload, api, token)
        val pop = alert && ChatPop.wanted(context)
        if (pop && !ChatPop.canDraw(context)) {
            builder.setFullScreenIntent(
                ChatPop.launch(context, id, title, body, payload, api, token),
                true,
            )
        }
        try {
            NotificationManagerCompat.from(context).notify(id, builder.build())
        } catch (_: Exception) {
        }
        if (pop) ChatPop.show(context, id, title, body, payload, api, token)
    }

    /// Same list Social Save reads as chat.list.muted.v1. A mute from the
    /// notification still holds after the app process is gone.
    private fun rememberMute(context: Context, threadId: String) {
        if (!threadPattern.matches(threadId)) return
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val key = "flutter.chat.list.muted.v1"
        val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
        val raw = prefs.getString(key, null)
        val ids = LinkedHashSet<String>()
        if (raw != null) {
            if (!raw.startsWith(prefix)) return
            try {
                val arr = JSONArray(raw.substring(prefix.length))
                for (i in 0 until arr.length()) {
                    val item = arr.optString(i).trim()
                    if (threadPattern.matches(item)) ids.add(item)
                }
            } catch (_: Exception) {
                return
            }
        }
        ids.add(threadId)
        prefs.edit().putString(key, prefix + JSONArray(ids.toList()).toString()).commit()
    }

    private fun replyParts(action: String?): Pair<Int, String>? {
        if (action == null || !action.startsWith("$ACTION/")) return null
        val rest = action.substring(ACTION.length + 1)
        val slash = rest.indexOf('/')
        if (slash <= 0 || slash >= rest.length - 1) return null
        val id = rest.substring(0, slash).toIntOrNull() ?: 0
        val thread = rest.substring(slash + 1).trim()
        if (!threadPattern.matches(thread)) return null
        return id to thread
    }

    private fun noticeId(intent: Intent): Int {
        val extra = intent.getIntExtra(EXTRA_ID, 0)
        if (extra != 0) return extra
        val data = intent.data ?: return 0
        if (!data.scheme.equals("socialsave", true) || data.host != "reply") return 0
        return data.pathSegments.firstOrNull()?.toIntOrNull() ?: 0
    }

    private fun payloadFromUri(data: Uri?): String {
        if (data == null || !data.scheme.equals("socialsave", true) || data.host != "reply") return ""
        val parts = data.pathSegments
        if (parts.size < 2) return ""
        val thread = parts[1].trim()
        if (!threadPattern.matches(thread)) return ""
        return "chat|$thread|"
    }

    private fun flutterToken(context: Context): String {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.chat.token.v1", null) ?: return ""
        val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHN0cmluZy4"
        val value = if (raw.startsWith(prefix)) raw.substring(prefix.length) else raw
        return value.trim()
    }

    private fun threadOf(payload: String): String? {
        val parts = payload.split('|')
        if (parts.size < 2 || parts[0] != "chat") return null
        val id = parts[1].trim()
        if (!threadPattern.matches(id)) return null
        return id
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val loud = NotificationChannel(channelLoud, "Chats", NotificationManager.IMPORTANCE_MAX)
        loud.description = "New messages"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audio = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            loud.setSound(
                Uri.parse("android.resource://${context.packageName}/${R.raw.ss_message}"),
                audio,
            )
            loud.enableLights(true)
            loud.lightColor = attention
            loud.enableVibration(true)
            loud.vibrationPattern = longArrayOf(0, 280, 120, 280, 120, 480)
            loud.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        val quiet = NotificationChannel(channelQuiet, "Chats", NotificationManager.IMPORTANCE_LOW)
        quiet.description = "New messages"
        quiet.setSound(null, null)
        quiet.enableVibration(false)
        manager.createNotificationChannel(loud)
        manager.createNotificationChannel(quiet)
    }
}

/**
 * Sends a notification reply on Android 14 and newer. One UI 7 does not
 * deliver a reply broadcast while Social Save is asleep. Android 13 and
 * older, including the AQUOS, use ChatReplyReceiver instead.
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
        if (incoming == null || !ChatReply.isReply(incoming.action) || text.isEmpty()) {
            stopIfIdle()
            return START_NOT_STICKY
        }
        val id = ChatReply.postedId(incoming)
        ChatPop.dismiss()
        val payload = incoming.getStringExtra(ChatReply.EXTRA_PAYLOAD).orEmpty()
        ChatReply.markSending(app, id, payload)
        inflight.incrementAndGet()
        holdWake(app)
        Thread {
            try {
                val sent = ChatReply.sendFrom(app, incoming, text)
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
            if (Build.VERSION.SDK_INT < 34) {
                try {
                    startForeground(STATUS_ID, notification)
                } catch (e2: Exception) {
                    Log.w(TAG, "plain foreground refused: $e2")
                }
            }
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
                    acquire(150_000L)
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
        if (intent.action == ChatReply.ACTION_DISMISS) {
            val id = intent.getIntExtra(ChatReply.EXTRA_ID, 0)
            if (id != 0) {
                try {
                    NotificationManagerCompat.from(context.applicationContext).cancel(id)
                } catch (_: Exception) {
                }
            }
            return
        }
        if (intent.action == ChatReply.ACTION_MUTE) {
            ChatReply.applyMute(context.applicationContext, intent)
            return
        }
        if (!ChatReply.isReply(intent.action)) return
        val pending = goAsync()
        ChatPop.dismiss()
        val app = context.applicationContext
        val id = ChatReply.postedId(intent)
        if (id != 0) NotificationManagerCompat.from(app).cancel(id)
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(ChatReply.KEY_TEXT)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (text.isEmpty()) {
            pending.finish()
            return
        }
        Thread {
            var wake: PowerManager.WakeLock? = null
            try {
                val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SocialSave:reply").apply {
                    setReferenceCounted(false)
                    acquire(150_000L)
                }
            } catch (_: Exception) {
            }
            try {
                if (!ChatReply.sendFrom(app, intent, text)) ChatReply.failed(app)
            } catch (_: Exception) {
                ChatReply.failed(app)
            } finally {
                try {
                    wake?.release()
                } catch (_: Exception) {
                }
                pending.finish()
            }
        }.start()
    }
}

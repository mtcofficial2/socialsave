package com.socialsave.social_save

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Title and words of notifications, kept only after the owner says yes.
 * A password or a code is stored only after the owner allows that too.
 */
object PhoneNotes {
    private const val fileName = "phone_notes.json"
    private const val cap = 200
    private const val hiddenSentence = "Hidden. This notification looks like a password or a code."
    private const val keptHidden =
        "These words were hidden before you allowed passwords. That notification is no longer on the phone."
    private val gate = Any()

    fun ownerAllows(context: Context): Boolean {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return prefs.getString("flutter.socialsave_full_log", "") == "yes"
    }

    /** True only when the fuller log is on and the owner allowed passwords and codes. */
    fun secretsAllowed(context: Context): Boolean {
        if (!ownerAllows(context)) return false
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return prefs.getString("flutter.socialsave_secret_log", "") == "yes"
    }

    fun allowed(context: Context): Boolean {
        val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?: return false
        return flat.contains(context.packageName)
    }

    fun openSettingsIfNeeded(context: Context): Boolean {
        if (allowed(context)) return false
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return true
    }

    fun clear(context: Context) {
        synchronized(gate) {
            File(context.filesDir, fileName).delete()
            File(context.filesDir, "$fileName.tmp").delete()
        }
    }

    fun remember(context: Context, posted: StatusBarNotification) {
        if (!ownerAllows(context)) return
        val pkg = posted.packageName ?: return
        if (pkg == "android" || pkg.endsWith(".systemui")) return
        val flags = posted.notification?.flags ?: return
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        val secrets = secretsAllowed(context)
        val words = wordsOf(posted, secrets)
        if (words.isEmpty()) return
        val name = PhoneUsage.label(context, pkg)
        val hidden = words.startsWith("Hidden.")
        val secret = hidden || looksSecret(words.lowercase())
        val text = if (hidden) words else sentence(name, words)
        val now = PhoneUsage.iso(System.currentTimeMillis())
        synchronized(gate) {
            val file = File(context.filesDir, fileName)
            val array = readArray(file)
            var found = -1
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                if (item.optString("key") == posted.key) {
                    found = i
                    break
                }
            }
            val obj = JSONObject()
                .put("key", posted.key)
                .put("at", now)
                .put("kind", if (secret) "secret" else "notification")
                .put("title", name)
                .put("detail", words)
                .put("text", text)
            if (found >= 0) {
                array.put(found, obj)
            } else {
                array.put(obj)
            }
            while (array.length() > cap) array.remove(0)
            writeArray(file, array)
        }
    }

    fun recent(context: Context): List<Map<String, String>> {
        if (!ownerAllows(context)) return emptyList()
        val secrets = secretsAllowed(context)
        val array = synchronized(gate) { readArray(File(context.filesDir, fileName)) }
        val rows = ArrayList<Map<String, String>>()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            var text = item.optString("text").trim()
            val title = item.optString("title").trim()
            if (text.isEmpty() || title.isEmpty()) continue
            var detail = item.optString("detail")
            val kind = item.optString("kind").ifBlank { "notification" }
            if (secrets && (detail.startsWith("Hidden.") || text.startsWith("Hidden."))) {
                detail = keptHidden
                text = keptHidden
            }
            rows.add(
                mapOf(
                    "at" to item.optString("at"),
                    "kind" to kind,
                    "title" to title,
                    "detail" to detail,
                    "text" to text,
                ),
            )
        }
        return rows
    }

    /// Reads notifications that are still on screen after the owner allows passwords.
    fun rescan(context: Context) {
        if (!secretsAllowed(context) || !allowed(context)) return
        val name = ComponentName(context, NoteWatch::class.java)
        NotificationListenerService.requestUnbind(name)
        Handler(Looper.getMainLooper()).postDelayed({
            NotificationListenerService.requestRebind(name)
        }, 400)
    }

    /** Replaces stored passwords and codes after the owner turns that switch off. */
    fun concealSecrets(context: Context) {
        val hidden = hiddenSentence
        synchronized(gate) {
            val file = File(context.filesDir, fileName)
            val array = readArray(file)
            var changed = false
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val detail = item.optString("detail")
                val text = item.optString("text")
                val secret = item.optString("kind") == "secret" ||
                    looksSecret(detail.lowercase()) ||
                    looksSecret(text.lowercase())
                if (!secret || detail == hidden) continue
                item.put("kind", "secret")
                item.put("detail", hidden)
                item.put("text", hidden)
                changed = true
            }
            if (changed) writeArray(file, array)
        }
    }

    private fun wordsOf(posted: StatusBarNotification, secrets: Boolean): String {
        val extras = posted.notification?.extras ?: return ""
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val sub = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim().orEmpty()
        val summary = extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString()?.trim().orEmpty()
        val info = extras.getCharSequence(Notification.EXTRA_INFO_TEXT)?.toString()?.trim().orEmpty()
        val conversation = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim().orEmpty()
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.map { it.toString().trim() }
            ?.filter { it.isNotEmpty() }
            .orEmpty()
        val messages = messageLines(extras)
        val body = when {
            messages.isNotEmpty() -> messages.joinToString("\n")
            big.isNotEmpty() -> big
            lines.isNotEmpty() -> lines.joinToString("\n")
            else -> text
        }
        val combined = when {
            title.isNotEmpty() && body.isNotEmpty() && !body.startsWith(title) -> "$title\n$body"
            body.isNotEmpty() -> body
            else -> title
        }
        val extrasText = listOf(conversation, sub, summary, info)
            .filter { bit -> bit.isNotEmpty() && !combined.contains(bit) }
        val full = if (extrasText.isEmpty()) combined else combined + "\n" + extrasText.joinToString("\n")
        return tidy(full, secrets)
    }

    private fun messageLines(extras: Bundle): List<String> {
        val raw = if (Build.VERSION.SDK_INT >= 33) {
            extras.getParcelableArray(Notification.EXTRA_MESSAGES, Parcelable::class.java)
        } else {
            @Suppress("DEPRECATION")
            extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        } ?: return emptyList()
        val out = ArrayList<String>()
        for (item in raw) {
            val bundle = item as? Bundle ?: continue
            val text = bundle.getCharSequence("text")?.toString()?.trim().orEmpty()
            if (text.isEmpty()) continue
            val sender = bundle.getCharSequence("sender")?.toString()?.trim().orEmpty()
            out.add(if (sender.isEmpty()) text else "$sender: $text")
        }
        if (out.size <= 8) return out
        return out.takeLast(8)
    }

    private fun looksSecret(lower: String): Boolean {
        return listOf(
            "password",
            "token",
            "bearer",
            "authorization",
            "api_key",
            "secret",
            "otp",
            "passcode",
            "one-time",
            "verification code",
        ).any { lower.contains(it) }
    }

    private fun tidy(raw: String, secrets: Boolean): String {
        val lines = raw.replace("\r\n", "\n").replace('\r', '\n')
            .lines()
            .map { it.replace(Regex("[\\t ]+"), " ").trim() }
            .filter { it.isNotEmpty() }
        var clean = lines.joinToString("\n")
        if (clean.isEmpty()) return ""
        if (looksSecret(clean.lowercase()) && !secrets) {
            return "Hidden. This notification looks like a password or a code."
        }
        if (clean.length > 800) clean = clean.take(797) + "…"
        return clean
    }

    private fun sentence(name: String, words: String): String {
        val one = words.replace('\n', ' ').replace(Regex("\\s+"), " ").trim()
        val text = "$name: $one"
        if (text.endsWith(".") || text.endsWith("!") || text.endsWith("?")) return text
        return "$text."
    }

    private fun readArray(file: File): JSONArray {
        if (!file.exists()) return JSONArray()
        return try {
            JSONArray(file.readText())
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun writeArray(file: File, array: JSONArray) {
        val tmp = File(file.parentFile, "$fileName.tmp")
        tmp.writeText(array.toString())
        if (!tmp.renameTo(file)) {
            file.writeText(array.toString())
            tmp.delete()
        }
    }
}

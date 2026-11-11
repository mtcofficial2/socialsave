package com.socialsave.social_save

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.Calendar
import org.json.JSONObject

/// Pulls new messages and ringing calls while the Flutter engine is gone.
/// A signed-in phone that was offline posts them as soon as a network returns,
/// without anyone opening Social Save.
object ChatWatch {
    private const val TAG = "SocialSaveChat"
    private const val PREFS = "socialsave_chat_watch"
    private const val ENGINE_ID = "socialsave_main"
    private val handler = Handler(Looper.getMainLooper())
    private val gate = Any()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var ticking = false
    private var pulling = false
    private var again = false

    class Creds(val api: String, val token: String, val me: String)

    fun credentials(context: Context): Creds? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("armed", false)) return null
        val api = prefs.getString("api", null)?.trim().orEmpty()
        val token = prefs.getString("token", null)?.trim().orEmpty()
        if (api.isEmpty() || token.isEmpty()) return null
        return Creds(api, token, prefs.getString("me", null)?.trim().orEmpty())
    }

    fun save(context: Context, api: String, token: String, me: String) {
        val base = api.trim().trimEnd('/')
        val key = token.trim()
        if (base.isEmpty() || key.isEmpty()) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("armed", true)
            .putString("api", base)
            .putString("token", key)
            .putString("me", me.trim())
            .apply()
    }

    fun beat(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("beat", System.currentTimeMillis())
            .apply()
    }

    fun remember(context: Context, ids: Map<*, *>) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seen = readSeen(prefs)
        for ((key, value) in ids) {
            val id = key?.toString()?.trim().orEmpty()
            val last = when (value) {
                is Int -> value
                is Long -> value.toInt()
                is Number -> value.toInt()
                else -> continue
            }
            if (id.isEmpty() || last <= 0) continue
            val prev = seen.optInt(id, 0)
            if (last > prev) seen.put(id, last)
        }
        prefs.edit().putBoolean("seeded", true).putString("seen", seen.toString()).apply()
    }

    fun disarm(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("armed", false)
            .remove("token")
            .apply()
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("ringing").apply()
        ChatCallNotice.cancel(context)
    }

    fun ensure(context: Context) {
        val app = context.applicationContext
        if (!ticking) {
            ticking = true
            handler.post(object : Runnable {
                override fun run() {
                    if (!ticking) return
                    poke(app)
                    handler.postDelayed(this, 8_000)
                }
            })
        }
        if (callback != null) return
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val next = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                poke(app)
            }
        }
        try {
            cm.registerDefaultNetworkCallback(next)
            callback = next
        } catch (e: Exception) {
            Log.w(TAG, "network watch: $e")
        }
    }

    fun pause(context: Context) {
        ticking = false
        handler.removeCallbacksAndMessages(null)
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val current = callback
        callback = null
        if (cm != null && current != null) {
            try {
                cm.unregisterNetworkCallback(current)
            } catch (_: Exception) {
            }
        }
    }

    fun poke(context: Context) {
        val app = context.applicationContext
        if (dartCovers(app)) return
        synchronized(gate) {
            if (pulling) {
                again = true
                return
            }
            pulling = true
        }
        Thread {
            try {
                pull(app)
            } finally {
                val rerun = synchronized(gate) {
                    pulling = false
                    val more = again
                    again = false
                    more
                }
                if (rerun) poke(app)
            }
        }.start()
    }

    private fun pull(context: Context) {
        if (dartCovers(context)) return
        val creds = credentials(context) ?: return
        val inbox = getJson("${creds.api}/api/v1/chat/threads", creds.token)
        if (inbox != null && !dartCovers(context)) applyInbox(context, creds, inbox)
        if (dartCovers(context)) return
        val calls = getJson("${creds.api}/api/v1/chat/calls", creds.token) ?: return
        if (!dartCovers(context)) applyCalls(context, creds, calls)
    }

    /// The open app already posts notices. Native steps in when that loop has gone quiet.
    private fun dartCovers(context: Context): Boolean {
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) == null) return false
        val beat = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("beat", 0L)
        if (beat == 0L) return true
        return System.currentTimeMillis() - beat < 20_000
    }

    private fun applyInbox(context: Context, creds: Creds, body: JSONObject) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seeded = prefs.getBoolean("seeded", false)
        val seen = readSeen(prefs)
        val rows = body.optJSONArray("threads") ?: return
        val flutter = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val muted = mutedIds(flutter)
        val modes = notifyModes(flutter)
        val soundOn = flutterBool(flutter, "flutter.chat.pref.sound.v1", true) && !quietNow(flutter)
        var changed = false
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            val id = row.optString("id").trim()
            val lastId = row.optInt("lastId", 0)
            if (id.length < 2 || lastId <= 0) continue
            val prev = seen.optInt(id, 0)
            if (lastId > prev) {
                seen.put(id, lastId)
                changed = true
            }
            if (!seeded || lastId <= prev) continue
            val from = row.optString("lastFrom").trim()
            if (sameUser(from, creds.me) || muted.contains(id)) continue
            val text = row.optString("lastText").trim().ifEmpty { "New message" }
            val group = row.optBoolean("group") || id.startsWith("g")
            if (dartCovers(context) || !allows(id, group, text, creds.me, modes)) continue
            val username = row.optString("username").trim()
            val name = row.optString("name").trim()
            val title = name.ifEmpty { username.ifEmpty { "New message" } }
            val payload = if (name.isEmpty() || name == username) {
                "chat|$id|$username"
            } else {
                "chat|$id|$username|$name"
            }
            val mode = modes[id] ?: "all"
            ChatReply.show(
                context,
                io.flutter.plugin.common.MethodCall(
                    "show",
                    mapOf(
                        "id" to (id.hashCode() and 0x7fffffff),
                        "title" to title,
                        "body" to text,
                        "payload" to payload,
                        "sound" to (soundOn && mode != "silent"),
                        "silent" to false,
                        "api" to creds.api,
                        "token" to creds.token,
                    ),
                ),
            )
        }
        if (!seeded || changed) {
            prefs.edit().putBoolean("seeded", true).putString("seen", seen.toString()).apply()
        }
    }

    private fun applyCalls(context: Context, creds: Creds, body: JSONObject) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val rows = body.optJSONArray("calls") ?: return
        var ringing = ""
        var name = ""
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            if (row.optString("state") != "ringing") continue
            val id = row.optString("id").trim()
            val who = row.optString("fromName").trim()
            if (id.isEmpty() || who.isEmpty() || sameUser(who, creds.me)) continue
            ringing = id
            name = who
            break
        }
        val shown = prefs.getString("ringing", "").orEmpty()
        if (ringing.isEmpty()) {
            if (shown.isNotEmpty()) {
                prefs.edit().remove("ringing").apply()
                ChatCallNotice.cancel(context)
            }
            return
        }
        if (ringing == shown) return
        prefs.edit().putString("ringing", ringing).apply()
        ChatCallNotice.show(context, ringing, name, creds.api, creds.token)
    }

    private fun readSeen(prefs: SharedPreferences): JSONObject {
        return try {
            JSONObject(prefs.getString("seen", null) ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun sameUser(a: String, b: String): Boolean {
        fun clean(value: String) = value.trim().removePrefix("@").lowercase()
        val left = clean(a)
        return left.isNotEmpty() && left == clean(b)
    }

    private fun allows(
        threadId: String,
        group: Boolean,
        text: String,
        me: String,
        modes: Map<String, String>,
    ): Boolean {
        if ((modes[threadId] ?: "all") != "mentions") return true
        if (!group) return true
        val name = me.trim().removePrefix("@").lowercase()
        if (name.isEmpty()) return false
        return text.lowercase().contains("@$name")
    }

    private fun mutedIds(prefs: SharedPreferences): Set<String> {
        val raw = prefs.getString("flutter.chat.list.muted.v1", null) ?: return emptySet()
        val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
        if (!raw.startsWith(prefix)) return emptySet()
        return try {
            val arr = org.json.JSONArray(raw.substring(prefix.length))
            buildSet {
                for (i in 0 until arr.length()) {
                    val id = arr.optString(i).trim()
                    if (id.length >= 2) add(id)
                }
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun notifyModes(prefs: SharedPreferences): Map<String, String> {
        val raw = flutterString(prefs, "flutter.chat.pref.notify.v1")
        if (raw.isEmpty()) return emptyMap()
        val out = HashMap<String, String>()
        for (line in raw.split('\n')) {
            val cut = line.split('|')
            if (cut.size != 2) continue
            val id = cut[0].trim()
            val mode = cut[1].trim()
            if (id.isNotEmpty() && (mode == "mentions" || mode == "silent")) out[id] = mode
        }
        return out
    }

    private fun quietNow(prefs: SharedPreferences): Boolean {
        val raw = flutterString(prefs, "flutter.chat.pref.quiet.v1")
        val parts = raw.split(',')
        if (parts.size != 2) return false
        val start = parts[0].toIntOrNull() ?: return false
        val end = parts[1].toIntOrNull() ?: return false
        if (start < 0 || end < 0 || start >= 24 * 60 || end >= 24 * 60 || start == end) return false
        val clock = Calendar.getInstance()
        val minute = clock.get(Calendar.HOUR_OF_DAY) * 60 + clock.get(Calendar.MINUTE)
        if (start < end) return minute in start until end
        return minute >= start || minute < end
    }

    private fun flutterString(prefs: SharedPreferences, key: String): String {
        val raw = prefs.getString(key, null) ?: return ""
        val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHN0cmluZy4"
        return if (raw.startsWith(prefix)) raw.substring(prefix.length) else raw
    }

    private fun flutterBool(prefs: SharedPreferences, key: String, fallback: Boolean): Boolean {
        if (!prefs.contains(key)) return fallback
        return try {
            prefs.getBoolean(key, fallback)
        } catch (_: Exception) {
            fallback
        }
    }

    private fun getJson(url: String, token: String): JSONObject? {
        val uri = try {
            URI(url)
        } catch (_: Exception) {
            return null
        }
        if (!uri.scheme.equals("https", true) || uri.host.isNullOrBlank() || uri.userInfo != null) {
            return null
        }
        val connection = (URL(url).openConnection() as HttpURLConnection)
        return try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-Chat-Token", token)
            if (connection.responseCode !in 200..299) return null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                val out = StringBuilder()
                val buf = CharArray(4096)
                while (out.length < 256 * 1024) {
                    val n = reader.read(buf)
                    if (n < 0) break
                    out.append(buf, 0, n)
                }
                if (out.isEmpty()) return null
                out.toString()
            }
            JSONObject(text)
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }
}

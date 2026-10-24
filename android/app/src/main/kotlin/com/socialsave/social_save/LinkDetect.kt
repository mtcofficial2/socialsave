package com.socialsave.social_save

import android.content.Context

/** Finds a public video link in copied text and keeps the on/off + duplicate state.
 *  Everything here stays on the phone: nothing is stored beyond the last link seen
 *  (to avoid asking twice) and nothing is sent anywhere. */
object LinkDetect {
    private val urlRe = Regex("https?://[^\\s<>\"]+", RegexOption.IGNORE_CASE)
    private val hosts = listOf(
        "tiktok.com", "instagram.com", "facebook.com", "fb.watch", "fb.com",
        "x.com", "twitter.com", "youtube.com", "youtu.be", "reddit.com", "redd.it",
        "pinterest.com", "pin.it",
    )

    fun videoUrl(text: CharSequence?): String? {
        val raw = text?.toString()?.trim().orEmpty()
        if (raw.isEmpty() || raw.length > 2000) return null
        val m = urlRe.find(raw) ?: return null
        val url = m.value.trimEnd('.', ',', ')', ']')
        val host = try {
            java.net.URI(url).host?.lowercase()?.removePrefix("www.")?.removePrefix("m.")
        } catch (_: Exception) { null } ?: return null
        val ok = hosts.any { host == it || host.endsWith(".$it") }
        return if (ok) url else null
    }

    /** A public playlist, TikTok profile, Instagram highlight, or Facebook album. */
    fun isSet(url: String): Boolean {
        val uri = try { java.net.URI(url) } catch (_: Exception) { return false }
        val host = uri.host?.lowercase()?.removePrefix("www.")?.removePrefix("m.") ?: return false
        val path = uri.path ?: ""
        val segs = path.split('/').filter { it.isNotEmpty() }
        if (segs.any { it == "login" || it == "accounts" || it == "challenge" || it == "checkpoint" || it == "recover" || it == "signup" }) return false
        val query = uri.rawQuery ?: ""
        fun q(name: String): String? {
            for (part in query.split('&')) {
                val i = part.indexOf('=')
                if (i <= 0) continue
                if (part.substring(0, i) == name) return part.substring(i + 1)
            }
            return null
        }
        if (host.endsWith("youtube.com") || host == "youtu.be" || host.endsWith("youtube-nocookie.com")) {
            if (path == "/playlist" || path.endsWith("/playlist")) return true
            val list = q("list")
            val video = q("v")
            if (!list.isNullOrEmpty() && video.isNullOrEmpty() && !path.startsWith("/shorts/")) return true
            if (segs.isNotEmpty() && segs[0].startsWith("@") && segs[0].length > 1) {
                if (segs.size == 1) return true
                val tabs = setOf(
                    "videos", "shorts", "streams", "live", "playlists", "releases",
                    "podcasts", "posts", "community", "about", "featured", "channels",
                )
                if (segs.size == 2 && tabs.contains(segs[1].lowercase())) return true
            }
            if (segs.size >= 2 && (segs[0] == "channel" || segs[0] == "c" || segs[0] == "user") && segs[1].isNotEmpty()) return true
            return false
        }
        if (host.endsWith("tiktok.com") && host != "vm.tiktok.com" && host != "vt.tiktok.com") {
            return segs.size == 1 && segs[0].startsWith("@") && segs[0].length > 1
        }
        if (host.endsWith("instagram.com") || host == "instagr.am") {
            return segs.size >= 3 && segs[0] == "stories" && segs[1] == "highlights" && segs[2].isNotEmpty()
        }
        if (host.endsWith("facebook.com") || host == "fb.com" || host.endsWith("fb.watch")) {
            val lower = path.lowercase()
            if (lower.contains("/media/set") || lower.contains("/albums/") || lower.contains("/album/")) return true
            return !q("set").isNullOrEmpty()
        }
        return false
    }

    fun platformName(url: String): String {
        val u = url.lowercase()
        return when {
            "tiktok" in u -> "TikTok"
            "instagram" in u -> "Instagram"
            "facebook" in u || "fb.watch" in u || "fb.com" in u -> "Facebook"
            "youtu" in u -> "YouTube"
            "reddit" in u || "redd.it" in u -> "Reddit"
            "pin" in u -> "Pinterest"
            "x.com" in u || "twitter" in u -> "X"
            else -> "Video"
        }
    }

    private fun flutter(c: Context) = c.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    /** Master switch in Settings AND the existing "Offer to download copied links". */
    fun enabled(c: Context): Boolean {
        val p = flutter(c)
        return p.getBoolean("flutter.socialsave_offerCopiedLinks", true) &&
            p.getBoolean("flutter.bgdetect.enabled", true)
    }

    /** True once per distinct link (a repeat within a minute is ignored). */
    @Synchronized
    fun fresh(c: Context, url: String): Boolean {
        val p = c.getSharedPreferences("ss_linkdetect", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (p.getString("last", null) == url && now - p.getLong("at", 0) < 60_000) return false
        p.edit().putString("last", url).putLong("at", now).apply()
        return true
    }
}

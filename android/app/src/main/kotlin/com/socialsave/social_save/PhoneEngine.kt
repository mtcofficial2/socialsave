package com.socialsave.social_save

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * "Download on this phone (no server)": yt-dlp + Python + ffmpeg + QuickJS
 * run on the phone through youtubedl-android (the engine Seal uses).
 * Only bundled for arm64-v8a; [supported] is false elsewhere.
 * Format ids match the server's ("original", "<h>p", "auto", "audio",
 * "audio-mp3") so the existing quality picker keeps working.
 */
object PhoneEngine {
    private const val CHANNEL = "socialsave/phone_engine"
    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newCachedThreadPool()
    private val jobs = ConcurrentHashMap<String, Job>()
    @Volatile private var ready = false
    private const val TAG = "PhoneEngine"
    /** Info JSON from the last analyze per link, so the save skips a second extraction. */
    private val infoCache = ConcurrentHashMap<String, Pair<Long, File>>()
    private const val INFO_TTL_MS = 20 * 60 * 1000L
    private lateinit var app: Context

    private class Job(val id: String, val dir: File) {
        @Volatile var state = "processing"
        @Volatile var progress = 0.0
        @Volatile var eta = -1L
        val tracker = EngineProgress()
        @Volatile var path: String? = null
        @Volatile var error: String? = null
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "prepare" -> background(result) { prepare(); status() }
                // App start / switch on: unpack Python + ffmpeg and start the
                // interpreter once, so the first paste does not pay for it.
                "warm" -> { pool.execute { try { prepare(); warmPython() } catch (_: Throwable) {} }; result.success(true) }
                "update" -> background(result) {
                    prepare()
                    val outcome = try {
                        YoutubeDL.updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
                    } catch (e: Exception) {
                        YoutubeDL.updateYoutubeDL(app, YoutubeDL.UpdateChannel.NIGHTLY)
                    }
                    mapOf("status" to (outcome?.name ?: "UNKNOWN"), "version" to YoutubeDL.version(app))
                }
                "ytSignedIn" -> result.success(YouTubeLogin.signedIn(app))
                "ytSignIn" -> { YouTubeLogin.start(app); result.success(true) }
                "ytSignOut" -> { YouTubeLogin.signOut(app); result.success(true) }
                "info" -> {
                    val url = call.argument<String>("url") ?: ""
                    background(result) { info(url) }
                }
                "start" -> {
                    val id = call.argument<String>("id") ?: ""
                    val url = call.argument<String>("url") ?: ""
                    // "<id>+tt" asks for the TikTok-ready pick. Only "auto" changes:
                    // "tiktok" is capped at 1080p/30fps H.264, plain "auto" keeps the best.
                    val raw = call.argument<String>("formatId") ?: "auto"
                    val formatId = if (raw.endsWith("+tt")) raw.removeSuffix("+tt").let { if (it == "auto") "tiktok" else it } else raw
                    try { start(id, url, formatId); result.success(true) }
                    catch (e: Exception) { result.error("engine", e.message ?: "Could not start", null) }
                }
                "job" -> {
                    val job = jobs[call.argument<String>("id") ?: ""]
                    result.success(job?.let {
                        mapOf("state" to it.state, "progress" to it.progress, "eta" to it.eta,
                            "path" to it.path, "error" to it.error,
                            "downloaded_bytes" to it.tracker.downloaded, "total_bytes" to it.tracker.total,
                            "speed" to it.tracker.speed, "phase" to it.tracker.phase)
                    })
                }
                "cancel" -> {
                    val id = call.argument<String>("id") ?: ""
                    jobs[id]?.let { it.state = "cancelled" }
                    try { YoutubeDL.destroyProcessById(id) } catch (_: Exception) {}
                    result.success(true)
                }
                "cleanup" -> {
                    val id = call.argument<String>("id") ?: ""
                    jobs.remove(id)?.dir?.deleteRecursively()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // Old partial work from a killed process.
        pool.execute { File(app.cacheDir, "phone_engine").listFiles()?.forEach { it.deleteRecursively() } }
    }

    private fun supported(): Boolean =
        Build.SUPPORTED_ABIS.contains("arm64-v8a") &&
            File(app.applicationInfo.nativeLibraryDir, "libpython.zip.so").exists() &&
            File(app.applicationInfo.nativeLibraryDir, "libffmpeg.zip.so").exists()

    private fun status(): Map<String, Any?> = mapOf(
        "supported" to supported(),
        "ready" to ready,
        "version" to if (ready) YoutubeDL.version(app) else null,
    )

    @Synchronized
    private fun prepare() {
        if (ready) return
        if (!supported()) throw IllegalStateException("This phone can't run the on-phone engine (needs a 64-bit ARM phone).")
        YoutubeDL.init(app)
        FFmpeg.init(app)
        ready = true
    }

    @Volatile private var warmed = false
    /** First yt-dlp run loads Python modules from flash; do it before the user pastes. */
    private fun warmPython() {
        if (warmed) return
        try { YoutubeDL.execute(YoutubeDLRequest(emptyList()).addOption("--version")) } catch (_: Throwable) {}
        warmed = true
    }

    private val ytId = Regex("""(?:youtu\.be/|[?&]v=|/(?:shorts|embed|live|v)/)([A-Za-z0-9_-]{11})""")
    private val trackingParam = Regex("""^(si|feature|pp|utm_[a-z]+|igsh|igshid|is_from_webapp|sender_device|_r|_t)=""")

    /** One key per video: shorts, youtu.be, watch and embed links (with or without si=) match. */
    private fun cacheKey(url: String): String {
        val u = url.trim()
        if (isYouTube(u)) ytId.find(u)?.let { return "yt:" + it.groupValues[1] }
        val q = u.indexOf('?')
        if (q < 0) return u.removeSuffix("/")
        val kept = u.substring(q + 1).split('&').filter { it.isNotEmpty() && !trackingParam.containsMatchIn(it) }
        val base = u.substring(0, q).removeSuffix("/")
        return if (kept.isEmpty()) base else base + "?" + kept.joinToString("&")
    }

    private fun cachedInfo(url: String): File? {
        val hit = infoCache[cacheKey(url)] ?: return null
        if (SystemClock.elapsedRealtime() - hit.first > INFO_TTL_MS || !hit.second.isFile) {
            infoCache.remove(cacheKey(url)); return null
        }
        return hit.second
    }

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        pool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                val message = cleanError(e.message ?: e.javaClass.simpleName)
                main.post { result.error("engine", message, null) }
            }
        }
    }

    private fun info(url: String): String {
        prepare()
        return withClients(url) { clients ->
            val request = YoutubeDLRequest(url)
                .addOption("--dump-single-json")
                .addOption("--no-playlist")
                .addOption("--ignore-config")
                .addOption("--no-warnings")
                .addOption("--socket-timeout", if (clients != null) 8 else 25)
            youtubeOptions(request, clients)
            val out = YoutubeDL.execute(request).out
            if (clients != null && !hasVideo(out)) throw IllegalStateException("requested format is not available ($clients: no video formats)")
            remember(url, out)
            out
        }
    }

    private fun remember(url: String, out: String) {
        try {
            val start = out.indexOf('{')
            if (start < 0) return
            val dir = File(app.cacheDir, "phone_engine_info").apply { mkdirs() }
            val file = File(dir, "i${cacheKey(url).hashCode().toUInt()}.json")
            file.writeText(out.substring(start))
            infoCache[cacheKey(url)] = SystemClock.elapsedRealtime() to file
        } catch (_: Throwable) {}
    }

    private fun isYouTube(url: String): Boolean {
        val u = url.lowercase()
        return u.contains("youtube.com/") || u.contains("youtu.be/") || u.contains("youtube-nocookie.com/")
    }

    private fun isBotCheck(message: String?): Boolean {
        val m = (message ?: "").lowercase()
        return m.contains("not a bot") || m.contains("sign in to confirm") ||
            m.contains("page needs to be reloaded") || m.contains("requested format is not available") ||
            m.contains("http error 403") || m.contains("po token")
    }

    /**
     * Player clients to try in order (Oct 2026). On flagged IPs YouTube answers
     * web, tv and android_vr with "confirm you're not a bot"; web_embedded still
     * returns full DASH formats with no login or PO token; mweb/android give 360p.
     * Signed in, the cookie-friendly web clients go first.
     */
    private fun clientSets(): List<String> {
        val sets = mutableListOf<String>()
        prefs().getString(LAST_CLIENT, null)?.let { sets += it }
        if (YouTubeLogin.signedIn(app)) sets += "default,web_safari"
        // One client per attempt: a combined set makes yt-dlp query each in
        // turn, which took 34 s on the phone even when the first one worked.
        sets += listOf("web_embedded", "android_vr", "tv_simply", "default", "mweb", "android")
        val now = System.currentTimeMillis()
        val all = sets.distinct()
        return all.filter { prefs().getLong(SLOW_PREFIX + it, 0L) < now }.ifEmpty { all }
    }

    private const val LAST_CLIENT = "yt_last_client"
    private const val SLOW_PREFIX = "yt_slow2_" // v2: ignores marks a network outage set
    private const val SLOW_MS = 15_000L
    private fun prefs() = app.getSharedPreferences("phone_engine", Context.MODE_PRIVATE)

    /** At least one format with a picture (an all-audio or empty list is a refusal). */
    private fun hasVideo(json: String): Boolean =
        Regex(""""vcodec":\s*"(?!none")[^"]+"""").containsMatchIn(json)

    private fun youtubeOptions(request: YoutubeDLRequest, clients: String?) {
        if (clients != null) request.addOption("--extractor-args", "youtube:player_client=$clients")
        YouTubeLogin.cookieFile(app)?.let { request.addOption("--cookies", it.absolutePath) }
        // Keep yt-dlp's cache (player JS and solved n/sig challenges) between
        // runs; without it every YouTube run re-downloads and re-solves the
        // player in QuickJS (about 35 s on this phone).
        request.addOption("--cache-dir", File(app.filesDir, "yt-dlp-cache").absolutePath)
        // yt-dlp keeps its preprocessed-player cache off by default, so QuickJS
        // re-parses the whole player on every run. A tiny plugin turns it on.
        jscPluginDir()?.let { request.addOption("--plugin-dirs", it) }
    }

    private const val JSC_PLUGIN = "# SocialSave: reuse the preprocessed YouTube player between runs.\n" +
        "from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP\n" +
        "EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = True\n"

    @Volatile private var jscPlugin: String? = null
    private fun jscPluginDir(): String? = jscPlugin ?: try {
        // --plugin-dirs needs yt-dlp 2025.02 or newer.
        val v = YoutubeDL.version(app) ?: ""
        if (v < "2025.02") return null
        val root = File(app.filesDir, "yt-dlp-plugins")
        val file = File(root, "socialsave/yt_dlp_plugins/extractor/ss_jsc.py")
        if (!file.exists() || file.readText() != JSC_PLUGIN) {
            file.parentFile?.mkdirs()
            file.writeText(JSC_PLUGIN)
        }
        root.absolutePath.also { jscPlugin = it }
    } catch (e: Throwable) { Log.w(TAG, "jsc plugin: ${e.message}"); null }

    /** No network: every client would fail the same way, so stop and blame nothing. */
    private fun isNetworkError(message: String?): Boolean {
        val m = (message ?: "").lowercase()
        return m.contains("errno 7]") || m.contains("errno 101]") || m.contains("errno 111]") ||
            m.contains("no address associated") || m.contains("network is unreachable") ||
            m.contains("failed to resolve") || m.contains("connection refused") || m.contains("name or service not known")
    }

    /** Runs [work] with each client set until one gets past the bot check. */
    private fun <T> withClients(url: String, work: (String?) -> T): T {
        if (!isYouTube(url)) return work(null)
        var last: Throwable? = null
        for (clients in clientSets()) {
            val t0 = SystemClock.elapsedRealtime()
            try {
                val value = work(clients)
                prefs().edit().putString(LAST_CLIENT, clients).apply()
                return value
            } catch (e: YoutubeDL.CanceledException) { throw e }
            catch (e: Throwable) {
                val ms = SystemClock.elapsedRealtime() - t0
                val timedOut = (e.message ?: "").contains("timed out", true)
                Log.w(TAG, "youtube client $clients failed after ${ms}ms: ${(e.message ?: e.javaClass.simpleName).lines().lastOrNull { it.isNotBlank() }?.take(160)}")
                if (isNetworkError(e.message)) throw e
                if (prefs().getString(LAST_CLIENT, null) == clients) prefs().edit().remove(LAST_CLIENT).apply()
                // A client that fails slowly is skipped for a day.
                if (ms > SLOW_MS || timedOut) prefs().edit().putLong(SLOW_PREFIX + clients, System.currentTimeMillis() + 86_400_000L).apply()
                if (!isBotCheck(e.message) && !timedOut) throw e
                last = e
            }
        }
        throw last ?: IllegalStateException("YouTube refused every client")
    }

    private const val H264 = "[vcodec~='^(avc|h264)']"
    private const val AAC = "[acodec~='^(mp4a|aac)']"
    // TikTok's "download" format is the watermarked share copy.
    private const val NOWM = "[format_id!=download]"

    /**
     * "auto" is the default and the TikTok-ready pick: up to 1080p, H.264 + AAC,
     * up to 30 fps first, so the prep step only has to repack. YouTube's only
     * progressive H.264 is 360p, so YouTube goes DASH-first; TikTok and the
     * rest offer progressive H.264 with sound, so those go progressive-first
     * (no merge). "original" and explicit heights keep higher quality.
     */
    private fun selector(formatId: String, url: String): String {
        if (formatId == "audio") return "ba[ext=m4a]/ba/b"
        if (formatId == "audio-mp3") return "ba/b"
        if (formatId == "original") return "bv*+ba/b"
        val height = formatId.removeSuffix("p").toIntOrNull()
        if (formatId == "auto" || (height == null && formatId != "tiktok")) {
            // Best quality, no cap. The -S sort still takes H.264 at equal height.
            return "bv*+ba/b"
        }
        if (height == null || formatId == "tiktok") {
            // Long side <= 1920 means up to 1080p in portrait and landscape.
            val c = "[height<=?1920][width<=?1920]"
            return if (isYouTube(url)) {
                "bv*$c$H264[fps<=?30]+ba$AAC/bv*$c$H264+ba$AAC/bv*$c$H264+ba/bv*$c+ba/b$c/b"
            } else {
                "b$c$H264$NOWM[acodec!=none][fps<=?30]/b$c$H264$NOWM[acodec!=none]/bv*$c$H264$NOWM+ba/b$c$NOWM[acodec!=none]/bv*$c+ba/b"
            }
        }
        val dash = "bv*[height<=$height]+ba/b[height<=$height][acodec!=none][vcodec!=none]/b[height<=$height]/b"
        // H.264 + AAC at the asked height. VP9, AV1, or Opus in an MP4 is
        // still 1080p or 720p, and TikTok says it could not decode it.
        // YouTube has no H.264 above 1080p. 70% of the height still counts
        // (a letterboxed 1920x804 frame is a 1080p film).
        val lo = height * 7 / 10
        return if (height <= 1080) {
            "bv*[height<=$height][height>=$lo]$H264+ba$AAC/" +
                "bv*[height<=$height][height>=$lo]$H264+ba[ext=m4a]/" +
                "b[height<=$height][height>=$lo]$H264[acodec!=none]/" +
                "bv*[height<=$height]$H264+ba$AAC/$dash"
        } else dash
    }

    private fun start(id: String, url: String, formatId: String) {
        if (id.isEmpty() || url.isEmpty()) throw IllegalArgumentException("Missing link")
        val dir = File(File(app.cacheDir, "phone_engine"), id)
        dir.deleteRecursively()
        dir.mkdirs()
        val job = Job(id, dir)
        jobs[id] = job
        pool.execute {
            try {
                prepare()
                val cached = cachedInfo(url)
                var done = false
                if (cached != null) {
                    // Reuse the analyze result: no second extraction.
                    try {
                        fetch(job, dir, url, formatId, null, cached)
                        done = true
                    } catch (e: YoutubeDL.CanceledException) { throw e }
                    catch (e: Throwable) {
                        if (job.state == "cancelled") throw e
                        Log.w(TAG, "load-info-json failed, extracting again: ${(e.message ?: e.javaClass.simpleName).lines().lastOrNull { it.isNotBlank() }?.take(200)}")
                        infoCache.remove(cacheKey(url))
                    }
                }
                if (!done) withClients(url) { clients -> fetch(job, dir, url, formatId, clients, null) }
                if (job.state == "cancelled") return@execute
                val file = dir.listFiles()
                    ?.filter { it.isFile && !it.name.endsWith(".part") && !it.name.endsWith(".ytdl") }
                    ?.maxByOrNull { it.length() }
                    ?: throw IllegalStateException("The engine finished but no file was saved.")
                job.path = file.absolutePath
                job.progress = 1.0
                job.state = "ready"
            } catch (e: YoutubeDL.CanceledException) {
                job.state = "cancelled"
                dir.deleteRecursively()
            } catch (e: Throwable) {
                if (job.state == "cancelled") { dir.deleteRecursively(); return@execute }
                job.error = cleanError(e.message ?: e.javaClass.simpleName)
                job.state = "failed"
                dir.deleteRecursively()
            }
        }
    }

    private fun fetch(job: Job, dir: File, url: String, formatId: String, clients: String?, infoJson: File?) {
                if (job.state == "cancelled") return
                dir.listFiles()?.forEach { it.deleteRecursively() }
                val request = YoutubeDLRequest(if (infoJson != null) emptyList() else listOf(url))
                    .addOption("--no-playlist")
                    .addOption("--ignore-config")
                    .addOption("--newline")
                    .addOption("--progress")
                    .addOption("--no-part")
                    .addOption("--retries", 3)
                    .addOption("--fragment-retries", 3)
                    .addOption("--socket-timeout", 25)
                    .addOption("--concurrent-fragments", 8)
                    // Fixed 256 KB reads so progress arrives in steady steps
                    // (yt-dlp otherwise doubles its read size: 1, 2, 4 MB...).
                    .addOption("--buffer-size", "256K")
                    .addOption("--no-resize-buffer")
                    .addOption("-f", selector(formatId, url))
                    .addOption("-o", File(dir, "media.%(ext)s").absolutePath)
                if (infoJson != null) request.addOption("--load-info-json", infoJson.absolutePath)
                if (formatId == "tiktok") request.addOption("-S", "res:1080,fps:30,vcodec:h264,acodec:aac")
            // Same height in H.264 beats AV1/VP9: the phone has no AV1 chip, so an AV1 pick makes "TikTok-ready" a slow software decode.
            else if (formatId != "original" && !formatId.startsWith("audio")) request.addOption("-S", "res,fps,vcodec:h264,acodec:aac")
                youtubeOptions(request, clients)
                when (formatId) {
                    "audio" -> request.addOption("-x").addOption("--audio-format", "m4a")
                    "audio-mp3" -> request.addOption("-x").addOption("--audio-format", "mp3").addOption("--audio-quality", "0")
                    else -> request
                        .addOption("--merge-output-format", "mp4")
                        .addOption("--remux-video", "mp4")
                        .addOption("--postprocessor-args", "ffmpeg:-movflags +faststart")
                }
                YoutubeDL.execute(request, job.id) { _, eta, line ->
                    // One smooth value over the video, the audio and the merge.
                    job.tracker.line(line)
                    job.progress = maxOf(job.progress, job.tracker.value)
                    job.eta = eta
                }
    }

    /** yt-dlp's stderr is long; keep the ERROR line people can act on. */
    private fun cleanError(raw: String): String {
        if (raw.lowercase().contains("not a bot") || raw.lowercase().contains("sign in to confirm")) {
            return if (YouTubeLogin.signedIn(app))
                "YouTube asked this phone to prove it isn't a bot, even signed in. Tap Sign in to YouTube to sign in again, then Retry."
            else "YouTube asked this phone to prove it isn't a bot. Tap Sign in to YouTube, then Retry."
        }
        val line = raw.lines().lastOrNull { it.contains("ERROR:") } ?: raw.lines().firstOrNull { it.isNotBlank() } ?: raw
        return line.substringAfter("ERROR:").trim().take(300)
    }
}

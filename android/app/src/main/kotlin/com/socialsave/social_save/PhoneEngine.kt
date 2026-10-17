package com.socialsave.social_save

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
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
    private lateinit var app: Context

    private class Job(val dir: File) {
        @Volatile var state = "processing"
        @Volatile var progress = 0.0
        @Volatile var eta = -1L
        @Volatile var path: String? = null
        @Volatile var error: String? = null
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "prepare" -> background(result) { prepare(); status() }
                "update" -> background(result) {
                    prepare()
                    val outcome = YoutubeDL.updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
                    mapOf("status" to (outcome?.name ?: "UNKNOWN"), "version" to YoutubeDL.version(app))
                }
                "info" -> {
                    val url = call.argument<String>("url") ?: ""
                    background(result) { info(url) }
                }
                "start" -> {
                    val id = call.argument<String>("id") ?: ""
                    val url = call.argument<String>("url") ?: ""
                    val formatId = call.argument<String>("formatId") ?: "auto"
                    try { start(id, url, formatId); result.success(true) }
                    catch (e: Exception) { result.error("engine", e.message ?: "Could not start", null) }
                }
                "job" -> {
                    val job = jobs[call.argument<String>("id") ?: ""]
                    result.success(job?.let {
                        mapOf("state" to it.state, "progress" to it.progress, "eta" to it.eta,
                            "path" to it.path, "error" to it.error)
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
        val request = YoutubeDLRequest(url)
            .addOption("--dump-single-json")
            .addOption("--no-playlist")
            .addOption("--ignore-config")
            .addOption("--no-warnings")
            .addOption("--socket-timeout", 25)
        return YoutubeDL.execute(request).out
    }

    private fun selector(formatId: String): String {
        if (formatId == "audio") return "ba[ext=m4a]/ba/b"
        if (formatId == "audio-mp3") return "ba/b"
        val height = formatId.removeSuffix("p").toIntOrNull()
        if (height == null || formatId == "auto" || formatId == "original") return "bv*+ba/b"
        val dash = "bv*[height<=$height]+ba/b[height<=$height][acodec!=none][vcodec!=none]/b[height<=$height]/b"
        // Phones decode H.264 in hardware everywhere; AV1/VP9 often not. YouTube
        // has no H.264 above 1080p, so 1440p/4K use the normal choice.
        return if (height <= 1080) {
            "bv*[height<=$height][height>=${height / 2}][vcodec^=avc1]+ba[ext=m4a]/$dash"
        } else dash
    }

    private fun start(id: String, url: String, formatId: String) {
        if (id.isEmpty() || url.isEmpty()) throw IllegalArgumentException("Missing link")
        val dir = File(File(app.cacheDir, "phone_engine"), id)
        dir.deleteRecursively()
        dir.mkdirs()
        val job = Job(dir)
        jobs[id] = job
        pool.execute {
            try {
                prepare()
                val request = YoutubeDLRequest(url)
                    .addOption("--no-playlist")
                    .addOption("--ignore-config")
                    .addOption("--newline")
                    .addOption("--progress")
                    .addOption("--no-part")
                    .addOption("--retries", 3)
                    .addOption("--fragment-retries", 3)
                    .addOption("--socket-timeout", 25)
                    .addOption("--concurrent-fragments", 8)
                    .addOption("-f", selector(formatId))
                    .addOption("-o", File(dir, "media.%(ext)s").absolutePath)
                when (formatId) {
                    "audio" -> request.addOption("-x").addOption("--audio-format", "m4a")
                    "audio-mp3" -> request.addOption("-x").addOption("--audio-format", "mp3").addOption("--audio-quality", "0")
                    else -> request.addOption("--merge-output-format", "mp4").addOption("--remux-video", "mp4")
                }
                YoutubeDL.execute(request, id) { progress, eta, _ ->
                    if (progress >= 0) job.progress = (progress / 100.0).coerceIn(0.0, 0.99)
                    job.eta = eta
                }
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

    /** yt-dlp's stderr is long; keep the ERROR line people can act on. */
    private fun cleanError(raw: String): String {
        val line = raw.lines().lastOrNull { it.contains("ERROR:") } ?: raw.lines().firstOrNull { it.isNotBlank() } ?: raw
        return line.substringAfter("ERROR:").trim().take(300)
    }
}

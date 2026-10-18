package com.socialsave.social_save

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileInputStream

/**
 * Runs the SocialSave Dart pipeline (analyse, enqueue, download) with no
 * activity: a headless FlutterEngine started on demand (entrypoint bgMain in
 * lib/bg_main.dart). When the app's own engine is alive, commands go to it
 * instead. Progress reaches the floating card through the same channel
 * methods (overlayMeta / overlayProgress) the app uses.
 */
object HeadlessEngine {
    private const val TAG = "LinkWatch"
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var ch: MethodChannel? = null
    private var ready = false
    private val pending = ArrayList<Pair<String, Any?>>()
    private var lastTouch = 0L
    private val reaper = object : Runnable {
        override fun run() {
            if (android.os.SystemClock.uptimeMillis() - lastTouch > 45000) shutdown() else main.postDelayed(this, 5000)
        }
    }

    val alive: Boolean get() = engine != null

    /** True when the app's own Dart engine can take the command. */
    private fun appChannel(): MethodChannel? {
        val c = DownloadEvents.channel
        return if (c != null && c !== ch) c else null
    }

    private fun touch() { lastTouch = android.os.SystemClock.uptimeMillis() }

    /** Sends [method] to whichever Dart side is alive. Returns false if none could be started. */
    fun send(context: Context, method: String, args: Any?): Boolean {
        var ok = true
        val run = Runnable {
            val app = appChannel()
            if (app != null) {
                try { app.invokeMethod(method, args) } catch (e: Exception) { android.util.Log.w(TAG, "app send failed: $e"); ok = false }
                return@Runnable
            }
            touch()
            if (!ensure(context.applicationContext)) { ok = false; return@Runnable }
            if (ready) ch?.invokeMethod(method, args) else pending.add(method to args)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else main.post(run)
        return ok
    }

    private fun ensure(app: Context): Boolean {
        if (engine != null) return true
        return try {
            val t = android.os.SystemClock.uptimeMillis()
            val e = FlutterEngine(app)
            GeneratedPluginRegistrant.registerWith(e)
            PhoneEngine.register(app, e.dartExecutor.binaryMessenger)
            val media = MethodChannel(e.dartExecutor.binaryMessenger, "socialsave/media")
            media.setMethodCallHandler { call, result -> handle(app, call.method, call.arguments, result) }
            ch = media
            DownloadEvents.channel = media
            engine = e
            ready = false
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    io.flutter.FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    "package:social_save/bg_main.dart",
                    "bgMain",
                ),
            )
            android.util.Log.i(TAG, "headless engine started in ${android.os.SystemClock.uptimeMillis() - t} ms")
            main.postDelayed(reaper, 5000)
            true
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "headless engine failed: $e")
            shutdown()
            false
        }
    }

    fun shutdown() {
        main.removeCallbacks(reaper)
        val e = engine ?: return
        engine = null
        ready = false
        pending.clear()
        if (DownloadEvents.channel === ch) DownloadEvents.channel = null
        ch = null
        try { e.destroy() } catch (_: Exception) {}
        android.util.Log.i(TAG, "headless engine stopped")
    }

    /** The app is opening: free the headless engine unless a download is running in it. */
    fun yieldToApp() {
        if (engine != null && android.os.SystemClock.uptimeMillis() - lastTouch > 3000) shutdown()
    }

    private fun handle(app: Context, method: String, a: Any?, result: MethodChannel.Result) {
        val m = a as? Map<*, *>
        when (method) {
            "bgReady" -> {
                ready = true
                val c = ch
                for ((mm, aa) in pending) c?.invokeMethod(mm, aa)
                pending.clear()
                result.success(true)
            }
            "overlayMeta" -> {
                if (m != null) LinkPrompt.meta(
                    (m["url"] as? String) ?: "",
                    (m["title"] as? String) ?: "",
                    (m["heights"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList(),
                    (m["audio"] as? Boolean) ?: false,
                )
                result.success(true)
            }
            "overlayProgress" -> {
                if (m != null) {
                    val st = (m["state"] as? String) ?: "running"
                    if (st == "running") touch()
                    ProgressCard.update(
                        (m["id"] as? String) ?: "",
                        m["title"] as? String,
                        (m["percent"] as? Number)?.toDouble() ?: -1.0,
                        m["speed"] as? String,
                        st,
                    )
                }
                result.success(true)
            }
            "moveToBack", "consumeQuickAction", "consumeSharedText" -> result.success(null)
            "log" -> { android.util.Log.i("SocialSaveSession", (m?.get("m") as? String) ?: ""); result.success(null) }
            "scanFile" -> {
                val p = m?.get("path") as? String
                if (!p.isNullOrBlank()) MediaScannerConnection.scanFile(app, arrayOf(p), null, null)
                result.success(p)
            }
            "saveToDownloads", "saveToGallery" -> {
                val p = m?.get("path") as? String
                if (p.isNullOrBlank()) { result.error("missing", "No file path", null); return }
                try {
                    result.success(save(app, p, (m?.get("name") as? String) ?: "video.mp4", (m?.get("mime") as? String) ?: "video/mp4", method == "saveToGallery"))
                } catch (e: Exception) { result.error("save_failed", e.message, null) }
            }
            "keepAlive" -> {
                try {
                    val i = Intent(app, DownloadKeepAliveService::class.java).apply {
                        putExtra(DownloadKeepAliveService.EXTRA_ID, m?.get("id") as? String)
                        putExtra(DownloadKeepAliveService.EXTRA_TITLE, m?.get("title") as? String)
                        putExtra(DownloadKeepAliveService.EXTRA_TEXT, m?.get("text") as? String)
                        putExtra(DownloadKeepAliveService.EXTRA_PROGRESS, (m?.get("progress") as? Number)?.toInt() ?: 0)
                        putExtra(DownloadKeepAliveService.EXTRA_PAUSED, m?.get("paused") == true)
                    }
                    if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
                } catch (e: Exception) { android.util.Log.w(TAG, "keepAlive refused: $e") }
                result.success(true)
            }
            "stopKeepAlive" -> {
                try { app.startService(Intent(app, DownloadKeepAliveService::class.java).apply { action = DownloadKeepAliveService.ACTION_STOP }) } catch (_: Exception) {}
                result.success(true)
            }
            "nearbyLock", "wifiLock" -> result.success(false)
            else -> result.notImplemented()
        }
    }

    private fun save(app: Context, sourcePath: String, name: String, mime: String, gallery: Boolean): String {
        val source = File(sourcePath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues()
            val collection = if (gallery) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Downloads.EXTERNAL_CONTENT_URI
            if (gallery) {
                values.put(MediaStore.Video.Media.DISPLAY_NAME, name)
                values.put(MediaStore.Video.Media.MIME_TYPE, mime)
                values.put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/SocialSave")
                values.put(MediaStore.Video.Media.IS_PENDING, 1)
            } else {
                values.put(MediaStore.Downloads.DISPLAY_NAME, name)
                values.put(MediaStore.Downloads.MIME_TYPE, mime)
                values.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/SocialSave")
                values.put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val r = app.contentResolver
            val uri = r.insert(collection, values) ?: throw IllegalStateException("Could not create media entry")
            r.openOutputStream(uri)?.use { out -> FileInputStream(source).use { it.copyTo(out) } }
                ?: throw IllegalStateException("Could not write file")
            values.clear()
            values.put(if (gallery) MediaStore.Video.Media.IS_PENDING else MediaStore.Downloads.IS_PENDING, 0)
            r.update(uri, values, null, null)
            r.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                if (it.moveToFirst()) { val s = it.getString(0); if (!s.isNullOrBlank()) return s }
            }
            return uri.toString()
        }
        val dir = File(Environment.getExternalStoragePublicDirectory(if (gallery) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_DOWNLOADS), "SocialSave")
        dir.mkdirs()
        val target = File(dir, name)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(app, arrayOf(target.absolutePath), arrayOf(mime), null)
        return target.absolutePath
    }
}
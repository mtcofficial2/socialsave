package com.socialsave.social_save

import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Rational
import android.util.Size
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "socialsave/media"
    private var channel: MethodChannel? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var wifiLockPerf: android.net.wifi.WifiManager.WifiLock? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null
    private var pendingShare: String? = null
    private var openedVideo: Map<String, String>? = null
    private var pendingQuickAction: String? = null
    private var pipAllowed = false
    private var pipWidth = 16
    private var pipHeight = 9
    private val io = Executors.newFixedThreadPool(3)
    private var backupResult: MethodChannel.Result? = null
    private var folderResult: MethodChannel.Result? = null
    private var phoneBody: PhoneBody? = null
    private val openBackup = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val pending = backupResult
        backupResult = null
        if (pending == null) return@registerForActivityResult
        if (uri == null) {
            pending.success(null)
            return@registerForActivityResult
        }
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            pending.success(bytes)
        } catch (error: Exception) {
            pending.error("read_failed", error.message, null)
        }
    }
    private var deleteResult: MethodChannel.Result? = null
    private var deleteDone = 0
    private var deleteAsked = 0
    private val deleteLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        val pending = deleteResult
        deleteResult = null
        pending?.success(if (r.resultCode == RESULT_OK) deleteDone + deleteAsked else deleteDone)
    }

    /// MediaStore entry for a file: its content uri, video id, or a lookup by path.
    private fun mediaUriFor(path: String?, id: String?, uriString: String?): Uri? {
        if (!uriString.isNullOrBlank() && uriString.startsWith("content://")) return Uri.parse(uriString)
        id?.toLongOrNull()?.let { return ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, it) }
        if (path.isNullOrBlank()) return null
        val files = MediaStore.Files.getContentUri("external")
        contentResolver.query(files, arrayOf(MediaStore.Files.FileColumns._ID), MediaStore.Files.FileColumns.DATA + "=?", arrayOf(path), null)?.use {
            if (it.moveToFirst()) return ContentUris.withAppendedId(files, it.getLong(0))
        }
        return null
    }

    private fun deleteMedia(items: List<Map<String, Any?>>, result: MethodChannel.Result) {
        io.execute {
            var done = 0
            val ask = ArrayList<Uri>()
            for (m in items) {
                val path = m["path"] as String?
                val id = m["id"]?.toString()
                val uriS = m["uri"] as String?
                if (!path.isNullOrBlank()) {
                    val f = File(path)
                    try {
                        if (f.exists() && f.delete()) {
                            MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                            done++
                            continue
                        }
                    } catch (_: Exception) {}
                }
                val uri = try { mediaUriFor(path, id, uriS) } catch (_: Exception) { null }
                if (uri == null) continue
                try {
                    if (contentResolver.delete(uri, null, null) > 0) { done++; continue }
                } catch (_: SecurityException) {
                } catch (_: Exception) { continue }
                ask.add(uri)
            }
            runOnUiThread {
                if (ask.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.R || deleteResult != null) {
                    result.success(done)
                } else {
                    try {
                        // The system shows its own "Allow SocialSave to delete…" prompt.
                        val pi = MediaStore.createDeleteRequest(contentResolver, ask)
                        deleteResult = result
                        deleteDone = done
                        deleteAsked = ask.size
                        deleteLauncher.launch(androidx.activity.result.IntentSenderRequest.Builder(pi.intentSender).build())
                    } catch (_: Exception) {
                        deleteResult = null
                        result.success(done)
                    }
                }
            }
        }
    }

    /**
     * One video or audio file for Send / Watch. 1.0.36 used file_selector,
     * which reads the whole file into memory on Android: a 500 MB video
     * crashed the app (OutOfMemoryError). This returns a readable path: the
     * file itself when MediaStore knows it, otherwise a streamed copy.
     */
    private var pickVideoResult: MethodChannel.Result? = null
    private val openVideo = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val pending = pickVideoResult
        pickVideoResult = null
        if (pending == null) return@registerForActivityResult
        if (uri == null) {
            pending.success(null)
            return@registerForActivityResult
        }
        io.execute {
            try {
                val direct = readablePathFor(uri)
                val path = direct ?: run {
                    val name = safeName(displayName(uri) ?: "video.mp4")
                    val out = File(freshSendDir(), name)
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(out).use { input.copyTo(it, 1 shl 20) }
                    }
                    out.absolutePath
                }
                runOnUiThread { pending.success(mapOf("path" to path, "name" to (displayName(uri) ?: File(path).name))) }
            } catch (error: Exception) {
                runOnUiThread { pending.error("pick_failed", error.message, null) }
            }
        }
    }

    /** The real file behind a picked MediaStore document, when this app can read it. */
    private fun readablePathFor(uri: Uri): String? {
        return try {
            var mediaUri: Uri? = null
            if (android.provider.DocumentsContract.isDocumentUri(this, uri) &&
                uri.authority == "com.android.providers.media.documents") {
                val parts = android.provider.DocumentsContract.getDocumentId(uri).split(":")
                val id = parts.getOrNull(1)?.toLongOrNull()
                val base = when (parts.getOrNull(0)) {
                    "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    else -> null
                }
                if (id != null && base != null) mediaUri = ContentUris.withAppendedId(base, id)
            } else if (uri.authority == MediaStore.AUTHORITY) {
                mediaUri = uri
            }
            val target = mediaUri ?: return null
            contentResolver.query(target, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                if (it.moveToFirst()) {
                    val path = it.getString(0)
                    if (!path.isNullOrBlank() && File(path).canRead()) return path
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private var sendFilesResult: MethodChannel.Result? = null
    private var sendFolderResult: MethodChannel.Result? = null
    private val openSendFiles = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val pending = sendFilesResult
        sendFilesResult = null
        if (pending == null) return@registerForActivityResult
        if (uris.isNullOrEmpty()) {
            pending.success(null)
            return@registerForActivityResult
        }
        io.execute {
            try {
                val root = freshSendDir()
                val used = HashSet<String>()
                val paths = ArrayList<String>()
                for (uri in uris) {
                    var name = safeName(displayName(uri) ?: "file")
                    var i = 1
                    val base = name.substringBeforeLast('.', name)
                    val ext = if (name.contains('.')) "." + name.substringAfterLast('.') else ""
                    while (!used.add(name.lowercase())) { name = "$base ($i)$ext"; i++ }
                    val out = File(root, name)
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(out).use { input.copyTo(it, 1 shl 20) }
                    }
                    paths.add(out.absolutePath)
                }
                runOnUiThread { pending.success(paths) }
            } catch (error: Exception) {
                runOnUiThread { pending.error("pick_failed", error.message, null) }
            }
        }
    }
    private val openSendFolder = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val pending = sendFolderResult
        sendFolderResult = null
        if (pending == null) return@registerForActivityResult
        if (uri == null) {
            pending.success(null)
            return@registerForActivityResult
        }
        io.execute {
            try {
                val docId = android.provider.DocumentsContract.getTreeDocumentId(uri)
                val rootName = safeName(docId.substringAfterLast(':').substringAfterLast('/').ifBlank { "Folder" })
                val out = File(freshSendDir(), rootName)
                out.mkdirs()
                copyTree(uri, docId, out, 0)
                runOnUiThread { pending.success(out.absolutePath) }
            } catch (error: Exception) {
                runOnUiThread { pending.error("pick_failed", error.message, null) }
            }
        }
    }

    /// Copies of picked items live in cache/send and are replaced on each pick.
    private fun freshSendDir(): File {
        val dir = File(cacheDir, "send")
        dir.deleteRecursively()
        val run = File(dir, System.currentTimeMillis().toString())
        run.mkdirs()
        return run
    }

    private fun safeName(raw: String): String {
        val s = raw.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").trim().trimEnd('.', ' ')
        return if (s.isEmpty() || s == "." || s == "..") "_" else s.take(120)
    }

    private fun displayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return uri.lastPathSegment
    }

    private fun copyTree(tree: Uri, parentId: String, dest: File, depth: Int) {
        if (depth > 32) return
        val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val cols = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = safeName(c.getString(1) ?: "file")
                val mime = c.getString(2) ?: ""
                if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                    val sub = File(dest, name)
                    sub.mkdirs()
                    copyTree(tree, id, sub, depth + 1)
                } else {
                    val doc = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id)
                    contentResolver.openInputStream(doc)?.use { input ->
                        FileOutputStream(File(dest, name)).use { input.copyTo(it, 1 shl 20) }
                    }
                }
            }
        }
    }

    private fun openWithApp(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val ext = file.extension.lowercase()
            val mime = if (file.isDirectory) "resource/folder"
                else android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(view, file.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    private val openFolder = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val pending = folderResult
        folderResult = null
        if (pending == null) return@registerForActivityResult
        if (uri == null) {
            pending.success(null)
            return@registerForActivityResult
        }
        try {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            contentResolver.takePersistableUriPermission(uri, flags)
            pending.success(uri.toString())
        } catch (error: Exception) {
            pending.error("folder_failed", error.message, null)
        }
    }

    private var hotspotShare: HotspotShare? = null

    companion object {
        /** Library "On this phone" list; was 400, which hid older videos and every Downloads-folder video. */
        private const val MAX_DEVICE_VIDEOS = 5000
        private var looperGuardInstalled = false

        /**
         * 1.0.37 crash fix. After the engine is destroyed (app closed while a
         * video surface is still producing frames), Flutter's ImageReader
         * callback calls scheduleFrame on the dead engine and throws
         * "FlutterJNI is not attached to native" on the main thread, which
         * killed the app in the background. Only that exception is swallowed;
         * anything else still crashes as before.
         */
        fun installLooperGuard() {
            if (looperGuardInstalled) return
            looperGuardInstalled = true
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                while (true) {
                    try {
                        android.os.Looper.loop()
                    } catch (e: RuntimeException) {
                        if (e.message?.contains("FlutterJNI is not attached to native") == true) {
                            android.util.Log.w("SocialSave", "Ignored a frame for a destroyed engine")
                            continue
                        }
                        throw e
                    }
                }
            }
        }

        const val EXTRA_QUICK_ACTION = "socialsave_quick_action"
        private const val ENGINE_ID = "socialsave_main"

        /** Ends the engine that outlived its activity (session over, app closed). */
        fun destroyDetachedEngine() {
            if (SessionBridge.activityAlive || SessionBridge.active) return
            val engine = FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            DownloadEvents.channel = null
            HotspotShare.disposeAll()
            SessionBridge.detach()
            try {
                engine.destroy()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * The app's Flutter engine is owned here (not by the activity's fragment)
     * so a connected share session keeps running after the activity is
     * closed (Back on the home screen, swiped from Recents). Without a
     * session it is destroyed with the activity exactly as before.
     */
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /**
     * 1.0.37 crash fix. The fragment FlutterFragmentActivity builds is made
     * "with a new engine", so it insisted on owning (and destroying) the
     * engine. The engine really comes from provideFlutterEngine (cached and
     * owned here), and when a second activity attached to it the first one
     * threw "The internal FlutterEngine ... has been attached to by another
     * activity". This activity destroys the engine itself (onDestroy ->
     * destroyDetachedEngine), so the fragment must not.
     */
    override fun createFlutterFragment(): io.flutter.embedding.android.FlutterFragment {
        val fragment = super.createFlutterFragment()
        val args = fragment.arguments ?: android.os.Bundle()
        args.putBoolean("destroy_engine_with_fragment", false)
        fragment.arguments = args
        return fragment
    }

    /** Back on the first screen while connected: go to the background instead of closing. */
    override fun finish() {
        if (SessionBridge.active && isTaskRoot && moveTaskToBack(true)) return
        super.finish()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        HeadlessEngine.yieldToApp()
        phoneBody?.stop()
        hotspotShare = HotspotShare.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        SessionBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        PhoneEngine.register(this, flutterEngine.dartExecutor.binaryMessenger)
        SessionBridge.onIdleWithoutActivity = { destroyDetachedEngine() }
        val body = PhoneBody(this)
        phoneBody = body
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "socialsave/phone").setStreamHandler(body)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        DownloadEvents.channel = channel
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "nearbyLock" -> {
                    // Lets UDP broadcast beacons from other SocialSave apps through.
                    try {
                        val wifi = applicationContext.getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                        if (call.argument<Boolean>("on") == true) {
                            if (multicastLock == null) {
                                multicastLock = wifi.createMulticastLock("socialsave-nearby").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                        } else {
                            multicastLock?.release()
                            multicastLock = null
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "wifiLock" -> {
                    // Full-speed Wi-Fi during transfers (no power-save throttling).
                    try {
                        val wifi = applicationContext.getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                        if (call.argument<Boolean>("on") == true) {
                            if (wifiLock == null) {
                                @Suppress("DEPRECATION")
                                val mode = if (Build.VERSION.SDK_INT >= 29) android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY else android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
                                wifiLock = wifi.createWifiLock(mode, "socialsave-transfer").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                                @Suppress("DEPRECATION")
                                wifiLockPerf = wifi.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "socialsave-transfer-perf").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                        } else {
                            wifiLock?.release(); wifiLock = null
                            wifiLockPerf?.release(); wifiLockPerf = null
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "deviceName" -> {
                    val name = try {
                        android.provider.Settings.Global.getString(contentResolver, "device_name")
                    } catch (e: Exception) { null }
                    result.success(if (name.isNullOrBlank()) "${Build.MANUFACTURER} ${Build.MODEL}" else name)
                }
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                        result.success(path)
                    }
                }
                "saveToDownloads" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "video.mp4"
                    val mime = call.argument<String>("mime") ?: "video/mp4"
                    if (path.isNullOrBlank()) {
                        result.error("missing", "No file path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveToDownloads(path, name, mime))
                    } catch (error: Exception) {
                        result.error("save_failed", error.message, null)
                    }
                }
                "saveToGallery" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "video.mp4"
                    val mime = call.argument<String>("mime") ?: "video/mp4"
                    if (path.isNullOrBlank()) {
                        result.error("missing", "No file path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveToGallery(path, name, mime))
                    } catch (error: Exception) {
                        result.error("save_failed", error.message, null)
                    }
                }
                "setPipAllowed" -> {
                    pipAllowed = call.argument<Boolean>("allowed") == true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setPictureInPictureParams(pipParams())
                    }
                    result.success(pipAllowed)
                }
                "setPipAspect" -> {
                    pipWidth = (call.argument<Int>("width") ?: 16).coerceAtLeast(1)
                    pipHeight = (call.argument<Int>("height") ?: 9).coerceAtLeast(1)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        setPictureInPictureParams(pipParams())
                    }
                    result.success(true)
                }
                "enterPip" -> {
                    result.success(enterPip())
                }
                "renamePublicVideo" -> {
                    val name = call.argument<String>("name")
                    if (name.isNullOrBlank()) {
                        result.error("missing", "No name", null)
                        return@setMethodCallHandler
                    }
                    result.success(
                        renamePublicVideo(
                            call.argument<String>("id"),
                            call.argument<String>("path"),
                            call.argument<String>("uri"),
                            name,
                        ),
                    )
                }
                "queryMedia" -> {
                    // Paged MediaStore listing for the session media picker.
                    val kind = call.argument<String>("kind") ?: "video"
                    val offset = call.argument<Int>("offset") ?: 0
                    val limit = call.argument<Int>("limit") ?: 300
                    io.execute {
                        val out = try {
                            queryMedia(kind, offset, limit)
                        } catch (e: Exception) {
                            mapOf("total" to 0, "items" to emptyList<Any>(), "error" to (e.message ?: "query failed"))
                        }
                        runOnUiThread { result.success(out) }
                    }
                }
                "listVideos" -> {
                    try {
                        result.success(listVideos())
                    } catch (error: Exception) {
                        result.error("list_failed", error.message, null)
                    }
                }
                "copyVideo" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    if (id.isNullOrBlank() && path.isNullOrBlank() && uri.isNullOrBlank()) {
                        result.error("missing", "No video id", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(copyVideo(id, path, uri))
                    } catch (error: Exception) {
                        result.error("copy_failed", error.message, null)
                    }
                }
                "deletePublicVideo" -> {
                    val path = call.argument<String>("path")
                    val id = call.argument<String>("id")
                    val uri = call.argument<String>("uri")
                    result.success(deletePublicVideo(id, path, uri))
                }
                "videoThumbnail" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    io.execute {
                        try {
                            result.success(videoThumbnail(id, path, uri))
                        } catch (_: Exception) {
                            result.success(null)
                        }
                    }
                }
                "overlayMeta" -> {
                    val a = call.arguments as? Map<*, *>
                    if (a != null) {
                        LinkPrompt.meta(
                            (a["url"] as? String) ?: "",
                            (a["title"] as? String) ?: "",
                            (a["heights"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList(),
                            (a["audio"] as? Boolean) ?: false,
                        )
                    }
                    result.success(true)
                }
                "overlayProgress" -> {
                    val a = call.arguments as? Map<*, *>
                    if (a != null) {
                        ProgressCard.update(
                            (a["id"] as? String) ?: "",
                            a["title"] as? String,
                            (a["percent"] as? Number)?.toDouble() ?: -1.0,
                            a["speed"] as? String,
                            (a["state"] as? String) ?: "running",
                        )
                    }
                    result.success(true)
                }
                "moveToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "bgStatus" -> {
                    val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
                    val me = ComponentName(this, LinkWatcherService::class.java).flattenToString()
                    val short = ComponentName(this, LinkWatcherService::class.java).flattenToShortString()
                    result.success(mapOf(
                        "accessibility" to (enabled.contains(me) || enabled.contains(short)),
                        "overlay" to Settings.canDrawOverlays(this),
                        "bubble" to (BubbleService.instance != null),
                        "sdk" to Build.VERSION.SDK_INT,
                    ))
                }
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openOverlaySettings" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openAppInfo" -> {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "bubbleStart" -> {
                    if (BubbleService.canDraw(this)) { BubbleService.start(this); result.success(true) } else result.success(false)
                }
                "bubbleStop" -> {
                    BubbleService.stop(this)
                    result.success(true)
                }
                "consumeSharedText" -> {
                    val text = pendingShare
                    pendingShare = null
                    result.success(text)
                }
                "consumeQuickAction" -> {
                    val action = pendingQuickAction
                    pendingQuickAction = null
                    result.success(action)
                }
                "consumeOpenedVideo" -> {
                    val video = openedVideo
                    openedVideo = null
                    result.success(video)
                }
                "setSecure" -> {
                    val secure = call.argument<Boolean>("secure") == true
                    runOnUiThread {
                        if (secure) {
                            window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE,
                            )
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(secure)
                }
                "apkPath" -> result.success(applicationInfo.sourceDir)
                "log" -> {
                    android.util.Log.i("SocialSaveSession", call.argument<String>("m") ?: "")
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing", "No APK path", null)
                        return@setMethodCallHandler
                    }
                    result.success(installApk(path))
                }
                "keepAlive" -> {
                    val intent = Intent(this, DownloadKeepAliveService::class.java).apply {
                        putExtra(DownloadKeepAliveService.EXTRA_ID, call.argument<String>("id"))
                        putExtra(DownloadKeepAliveService.EXTRA_TITLE, call.argument<String>("title"))
                        putExtra(DownloadKeepAliveService.EXTRA_TEXT, call.argument<String>("text"))
                        putExtra(DownloadKeepAliveService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: 0)
                        putExtra(DownloadKeepAliveService.EXTRA_PAUSED, call.argument<Boolean>("paused") == true)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    val intent = Intent(this, DownloadKeepAliveService::class.java).apply {
                        action = DownloadKeepAliveService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                "pickBackup" -> {
                    if (backupResult != null) {
                        result.error("busy", "A file picker is already open", null)
                        return@setMethodCallHandler
                    }
                    backupResult = result
                    openBackup.launch(arrayOf("application/octet-stream", "application/*", "*/*"))
                }
                "setPlaybackSession" -> {
                    phoneBody?.setPlayback(
                        call.argument<Boolean>("active") == true,
                        call.argument<Boolean>("playing") == true,
                        call.argument<String>("title"),
                        call.argument<Boolean>("headset") != false,
                        call.argument<Boolean>("volumeSeek") != false,
                        call.argument<Boolean>("background") == true,
                        (call.argument<Number>("positionMs") ?: -1).toLong(),
                        (call.argument<Number>("durationMs") ?: 0).toLong(),
                    )
                    result.success(true)
                }
                "vibrate" -> {
                    phoneBody?.vibrate(call.argument<String>("pattern"))
                    result.success(true)
                }
                "deleteMedia" -> {
                    @Suppress("UNCHECKED_CAST")
                    val items = (call.argument<List<Any?>>("items") ?: emptyList()).mapNotNull { it as? Map<String, Any?> }
                    deleteMedia(items, result)
                }
                "pickSendFiles" -> {
                    if (sendFilesResult != null) {
                        result.error("busy", "A file picker is already open", null)
                        return@setMethodCallHandler
                    }
                    sendFilesResult = result
                    openSendFiles.launch(arrayOf("*/*"))
                }
                "pickVideo" -> {
                    if (pickVideoResult != null) {
                        result.error("busy", "A file picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pickVideoResult = result
                    openVideo.launch(arrayOf("video/*", "audio/*"))
                }
                "storageStats" -> {
                    try {
                        val stat = android.os.StatFs(Environment.getExternalStorageDirectory().path)
                        result.success(mapOf("free" to stat.availableBytes, "total" to stat.totalBytes))
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "cameraFacings" -> {
                    // Which lenses apps can open. Some phones (this SHARP) expose
                    // only a front camera; the QR scanner asked for the back one
                    // and failed with "No cameras available".
                    val facings = mutableListOf<String>()
                    try {
                        val cm = getSystemService(android.content.Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
                        for (id in cm.cameraIdList) {
                            when (cm.getCameraCharacteristics(id).get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)) {
                                android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK -> facings.add("back")
                                android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT -> facings.add("front")
                                android.hardware.camera2.CameraCharacteristics.LENS_FACING_EXTERNAL -> facings.add("external")
                            }
                        }
                    } catch (_: Exception) {
                    }
                    result.success(facings.distinct())
                }
                "pickSendFolder" -> {
                    if (sendFolderResult != null) {
                        result.error("busy", "A folder picker is already open", null)
                        return@setMethodCallHandler
                    }
                    sendFolderResult = result
                    openSendFolder.launch(null)
                }
                "openFile" -> {
                    val path = call.argument<String>("path")
                    result.success(if (path.isNullOrBlank()) false else openWithApp(path))
                }
                "pickSaveFolder" -> {
                    if (folderResult != null) {
                        result.error("busy", "A folder picker is already open", null)
                        return@setMethodCallHandler
                    }
                    folderResult = result
                    openFolder.launch(null)
                }
                "copyIntoFolder" -> {
                    val tree = call.argument<String>("treeUri")
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "video.mp4"
                    if (tree.isNullOrBlank() || path.isNullOrBlank()) {
                        result.error("missing", "No folder", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        try {
                            val saved = phoneBody?.copyIntoTree(tree, path, name)
                            runOnUiThread { result.success(saved) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("copy_failed", error.message, null) }
                        }
                    }
                }
                "playOnTv" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing", "No video", null)
                        return@setMethodCallHandler
                    }
                    result.success(playOnTv(path, call.argument<String>("title")))
                }
                "clipSound" -> {
                    val path = call.argument<String>("path")
                    val kind = call.argument<String>("kind") ?: "ringtone"
                    if (path.isNullOrBlank()) {
                        result.error("missing", "No video", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        val outcome = try {
                            phoneBody?.clipSound(path, kind) ?: mapOf(
                                "ok" to false,
                                "needsSettings" to false,
                                "message" to "Could not make that sound.",
                            )
                        } catch (error: Exception) {
                            mapOf(
                                "ok" to false,
                                "needsSettings" to false,
                                "message" to (error.message ?: "Could not make that sound."),
                            )
                        }
                        runOnUiThread {
                            if (outcome["needsSettings"] == true) {
                                try {
                                    startActivity(
                                        Intent(
                                            Settings.ACTION_MANAGE_WRITE_SETTINGS,
                                            Uri.parse("package:$packageName"),
                                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                    )
                                } catch (_: Exception) {
                                }
                            }
                            result.success(outcome)
                        }
                    }
                }
                "setBrightness" -> {
                    val value = call.argument<Double>("value") ?: -1.0
                    phoneBody?.setBrightness(value)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        installLooperGuard()
        SessionBridge.activities++
        super.onCreate(savedInstanceState)
        BubbleService.autostart(this)
        captureShare(intent)
        captureOpenedVideo(intent)
        captureOpenSession(intent)
        captureQuickAction(intent)
    }

    /** The Quick Settings tile: open Hotspot share. */
    private fun captureQuickAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_QUICK_ACTION) ?: return
        intent.removeExtra(EXTRA_QUICK_ACTION)
        pendingQuickAction = action
        channel?.invokeMethod("quickAction", action)
    }

    override fun onDestroy() {
        SessionBridge.activities = maxOf(0, SessionBridge.activities - 1)
        hotspotShare = null
        phoneBody?.stop()
        phoneBody = null
        super.onDestroy()
        if (!SessionBridge.active) {
            // No session: tear everything down like before.
            destroyDetachedEngine()
        }
    }

    /** Tapped the "Connected to …" notification: show the session screen. */
    private fun captureOpenSession(intent: Intent?) {
        if (intent?.getBooleanExtra(SessionKeepAliveService.EXTRA_OPEN_SESSION, false) != true) return
        intent.removeExtra(SessionKeepAliveService.EXTRA_OPEN_SESSION)
        SessionBridge.pendingOpen = true
        SessionBridge.sendToDart("open")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureOpenSession(intent)
        captureShare(intent)
        channel?.invokeMethod("sharedText", pendingShare)
        captureOpenedVideo(intent)
        captureQuickAction(intent)
    }

    private fun captureShare(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            pendingShare = intent.getStringExtra(Intent.EXTRA_TEXT)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipAllowed) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            enterPictureInPictureMode(pipParams())
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(pipRatio(pipWidth, pipHeight))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipAllowed)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun pipRatio(width: Int, height: Int): Rational {
        val w = width.coerceAtLeast(1).toDouble()
        val h = height.coerceAtLeast(1).toDouble()
        val clamped = (w / h).coerceIn(0.41841, 2.39)
        return Rational((clamped * 1000).toInt().coerceAtLeast(1), 1000)
    }

    private fun saveToDownloads(sourcePath: String, name: String, mime: String): String {
        val source = File(sourcePath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/SocialSave"
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create Downloads entry")
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not write Downloads file")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            val cursor = resolver.query(uri, arrayOf(MediaStore.Downloads.DATA), null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val stored = it.getString(0)
                    if (!stored.isNullOrBlank()) return stored
                }
            }
            return uri.toString()
        }

        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val folder = File(downloads, "SocialSave")
        if (!folder.exists()) folder.mkdirs()
        val target = File(folder, name)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(mime), null)
        return target.absolutePath
    }

    private fun saveToGallery(sourcePath: String, name: String, mime: String): String {
        val source = File(sourcePath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
                put(MediaStore.Video.Media.MIME_TYPE, mime)
                put(
                    MediaStore.Video.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_MOVIES + "/SocialSave"
                )
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create Gallery entry")
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not write Gallery file")
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            val cursor = resolver.query(uri, arrayOf(MediaStore.Video.Media.DATA), null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val stored = it.getString(0)
                    if (!stored.isNullOrBlank()) return stored
                }
            }
            return uri.toString()
        }

        val movies = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
        val folder = File(movies, "SocialSave")
        if (!folder.exists()) folder.mkdirs()
        val target = File(folder, name)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(mime), null)
        return target.absolutePath
    }

    private fun queryMedia(kind: String, offset: Int, limit: Int): Map<String, Any?> {
        val collection: Uri
        val durationCol: String?
        when (kind) {
            "image" -> {
                collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                durationCol = null
            }
            "audio" -> {
                collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                durationCol = MediaStore.Audio.Media.DURATION
            }
            else -> {
                collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                durationCol = MediaStore.Video.Media.DURATION
            }
        }
        val cols = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        if (durationCol != null) cols.add(durationCol)
        if (kind == "audio") {
            cols.add(MediaStore.Audio.Media.TITLE)
            cols.add(MediaStore.Audio.Media.ARTIST)
            cols.add(MediaStore.Audio.Media.ALBUM)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            cols.add(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            cols.add(MediaStore.MediaColumns.RELATIVE_PATH)
        } else if (kind != "audio") {
            cols.add("bucket_display_name")
        }
        val items = mutableListOf<Map<String, Any?>>()
        var total = 0
        contentResolver.query(
            collection,
            cols.toTypedArray(),
            null,
            null,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        )?.use { c ->
            total = c.count
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = c.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = c.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val dateCol = c.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val dataCol = c.getColumnIndex(MediaStore.MediaColumns.DATA)
            val mimeCol = c.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
            val durCol = if (durationCol == null) -1 else c.getColumnIndex(durationCol)
            val bucketCol = c.getColumnIndex("bucket_display_name")
            val titleCol = if (kind == "audio") c.getColumnIndex("title") else -1
            val artistCol = if (kind == "audio") c.getColumnIndex("artist") else -1
            val albumCol = if (kind == "audio") c.getColumnIndex("album") else -1
            val relCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) c.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH) else -1
            if (offset < total && c.moveToPosition(offset)) {
                do {
                    val id = c.getLong(idCol)
                    val path = if (dataCol >= 0) c.getString(dataCol) else null
                    items.add(
                        mapOf(
                            "id" to id.toString(),
                            "uri" to ContentUris.withAppendedId(collection, id).toString(),
                            "path" to path,
                            "name" to (if (nameCol >= 0) c.getString(nameCol) else null),
                            "size" to (if (sizeCol >= 0) c.getLong(sizeCol) else 0L),
                            "addedAt" to (if (dateCol >= 0) c.getLong(dateCol) else 0L),
                            "durationMs" to (if (durCol >= 0) c.getLong(durCol) else 0L),
                            "mime" to (if (mimeCol >= 0) c.getString(mimeCol) else null),
                            "bucket" to (if (bucketCol >= 0) c.getString(bucketCol) else null),
                            "relativePath" to (if (relCol >= 0) c.getString(relCol) else null),
                            "title" to (if (titleCol >= 0) c.getString(titleCol) else null),
                            "artist" to (if (artistCol >= 0) c.getString(artistCol) else null),
                            "album" to (if (albumCol >= 0) c.getString(albumCol) else null),
                        ),
                    )
                } while (items.size < limit && c.moveToNext())
            }
        }
        return mapOf("total" to total, "items" to items)
    }

    private fun listVideos(): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        collectVideos(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.DATE_ADDED,
                MediaStore.Video.Media.DATA,
            ),
            null,
            null,
            MediaStore.Video.Media.DURATION,
            items,
            seen,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            collectVideos(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(
                    MediaStore.Downloads._ID,
                    MediaStore.Downloads.DISPLAY_NAME,
                    MediaStore.Downloads.SIZE,
                    MediaStore.Downloads.DATE_ADDED,
                    MediaStore.Downloads.DATA,
                    MediaStore.Downloads.MIME_TYPE,
                ),
                "${MediaStore.Downloads.MIME_TYPE} LIKE ?",
                arrayOf("video/%"),
                null,
                items,
                seen,
            )
        }
        return items
    }

    private fun collectVideos(
        collection: Uri,
        projection: Array<String>,
        selection: String?,
        args: Array<String>?,
        durationColumn: String?,
        items: MutableList<Map<String, Any?>>,
        seen: MutableSet<String>,
    ) {
        val cursor = contentResolver.query(
            collection,
            projection,
            selection,
            args,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        ) ?: return
        cursor.use {
            val idCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = it.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = it.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val dateCol = it.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val dataCol = it.getColumnIndex(MediaStore.MediaColumns.DATA)
            val durCol = if (durationColumn == null) -1 else it.getColumnIndex(durationColumn)
            while (it.moveToNext() && items.size < MAX_DEVICE_VIDEOS) {
                val id = it.getLong(idCol)
                val uri = ContentUris.withAppendedId(collection, id).toString()
                val path = if (dataCol >= 0) it.getString(dataCol) else null
                val key = path?.takeIf { value -> value.isNotBlank() } ?: uri
                if (!seen.add(key)) continue
                items.add(
                    mapOf(
                        "id" to id.toString(),
                        "title" to ((if (nameCol >= 0) it.getString(nameCol) else null) ?: "Video"),
                        "durationMs" to if (durCol >= 0) it.getLong(durCol) else 0L,
                        "size" to if (sizeCol >= 0) it.getLong(sizeCol) else 0L,
                        "addedAt" to if (dateCol >= 0) it.getLong(dateCol) * 1000 else 0L,
                        "path" to path,
                        "uri" to uri,
                    ),
                )
            }
        }
    }

    private fun videoThumbnail(id: String?, path: String?, uriString: String?): String? {
        val key = when {
            !id.isNullOrBlank() -> id
            !path.isNullOrBlank() -> path.hashCode().toString()
            !uriString.isNullOrBlank() -> uriString.hashCode().toString()
            else -> return null
        }
        val dest = File(File(cacheDir, "thumbs"), "$key.jpg")
        if (dest.exists() && dest.length() > 200) return dest.absolutePath
        dest.parentFile?.mkdirs()
        val bitmap = decodeThumbnail(id, path, uriString) ?: return null
        try {
            FileOutputStream(dest).use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 78, output)
            }
        } finally {
            bitmap.recycle()
        }
        return if (dest.exists() && dest.length() > 200) dest.absolutePath else null
    }

    private fun decodeThumbnail(id: String?, path: String?, uriString: String?): Bitmap? {
        return try {
            if (!uriString.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentResolver.loadThumbnail(
                    Uri.parse(uriString),
                    Size(360, 360),
                    CancellationSignal(),
                )
            } else if (!path.isNullOrBlank()) {
                val file = File(path)
                if (!file.exists()) return null
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ThumbnailUtils.createVideoThumbnail(file, Size(360, 360), CancellationSignal())
                } else {
                    @Suppress("DEPRECATION")
                    ThumbnailUtils.createVideoThumbnail(
                        path,
                        MediaStore.Images.Thumbnails.MINI_KIND,
                    )
                }
            } else if (!id.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val uri = ContentUris.withAppendedId(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    id.toLong(),
                )
                contentResolver.loadThumbnail(uri, Size(360, 360), CancellationSignal())
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun captureOpenedVideo(intent: Intent?) {
        val uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                val type = intent.type ?: ""
                if (!type.startsWith("video/")) {
                    null
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            }
            else -> null
        } ?: return
        io.execute {
            try {
                val path = playableFromUri(uri)
                val title = videoDisplayName(uri) ?: File(path).name
                val payload = mapOf("path" to path, "title" to title)
                runOnUiThread {
                    openedVideo = payload
                    channel?.invokeMethod("openedVideo", payload)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun playableFromUri(uri: Uri): String {
        if (uri.scheme == "file") {
            val path = uri.path
            if (!path.isNullOrBlank() && File(path).canRead()) return path
        }
        return copyVideo(null, null, uri.toString())
    }

    private fun videoDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return uri.lastPathSegment
    }

    private fun copyVideo(id: String?, path: String?, uriString: String?): String {
        if (!path.isNullOrBlank()) {
            val source = File(path)
            if (source.exists() && source.canRead()) return source.absolutePath
        }
        val uri = when {
            !uriString.isNullOrBlank() -> Uri.parse(uriString)
            else -> {
                val videoId = id?.toLongOrNull() ?: throw IllegalStateException("Missing video")
                ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, videoId)
            }
        }
        val dest = File(cacheDir, "play_${uri.hashCode()}.mp4")
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(dest).use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("Could not open video")
        return dest.absolutePath
    }

    private fun deletePublicVideo(id: String?, path: String?, uriString: String?): Boolean {
        if (!path.isNullOrBlank()) {
            val file = File(path)
            if (file.exists() && file.delete()) return true
        }
        val uri = when {
            !uriString.isNullOrBlank() -> Uri.parse(uriString)
            else -> {
                val videoId = id?.toLongOrNull() ?: return false
                ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, videoId)
            }
        }
        return try {
            contentResolver.delete(uri, null, null) > 0
        } catch (_: Exception) {
            false
        }
    }

    private fun renamePublicVideo(
        id: String?,
        path: String?,
        uriString: String?,
        newName: String,
    ): Boolean {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return false
        val ext = path?.let { File(it).extension }.orEmpty()
        val display = if (trimmed.contains('.')) trimmed else {
            if (ext.isNotEmpty()) "$trimmed.$ext" else "$trimmed.mp4"
        }
        val uri = when {
            !uriString.isNullOrBlank() -> Uri.parse(uriString)
            else -> {
                val videoId = id?.toLongOrNull()
                if (videoId != null) {
                    ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, videoId)
                } else {
                    null
                }
            }
        }
        if (uri != null) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, display)
            }
            try {
                if (contentResolver.update(uri, values, null, null) > 0) return true
            } catch (_: Exception) {
            }
        }
        if (path.isNullOrBlank()) return false
        val file = File(path)
        if (!file.exists()) return false
        val dest = File(file.parentFile, display)
        if (!file.renameTo(dest)) return false
        MediaScannerConnection.scanFile(
            this,
            arrayOf(dest.absolutePath, file.absolutePath),
            null,
            null,
        )
        return true
    }

    private fun playOnTv(path: String, title: String?): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val mime = if (path.endsWith(".webm", ignoreCase = true)) "video/webm" else "video/*"
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra(Intent.EXTRA_TITLE, title ?: file.name)
            }
            val chooser = Intent.createChooser(view, "Play on TV").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun installApk(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settings)
            return false
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            clipData = ClipData.newRawUri("SocialSave", uri)
        }
        // Hand the installer permission to read the file so it can see this is SocialSave.
        val targets = packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        for (target in targets) {
            grantUriPermission(
                target.activityInfo.packageName,
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        startActivity(intent)
        return true
    }
}

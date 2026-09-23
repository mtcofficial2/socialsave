package com.socialsave.social_save

import android.app.PictureInPictureParams
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.provider.MediaStore
import android.util.Rational
import android.util.Size
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "socialsave/media"
    private var channel: MethodChannel? = null
    private var pendingShare: String? = null
    private var pipAllowed = false
    private var pipWidth = 16
    private var pipHeight = 9
    private val io = Executors.newFixedThreadPool(3)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
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
                "consumeSharedText" -> {
                    val text = pendingShare
                    pendingShare = null
                    result.success(text)
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
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShare(intent)
        channel?.invokeMethod("sharedText", pendingShare)
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
            while (it.moveToNext() && items.size < 400) {
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
}

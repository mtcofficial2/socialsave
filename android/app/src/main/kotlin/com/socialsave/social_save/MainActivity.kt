package com.socialsave.social_save

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "socialsave/media"
    private var channel: MethodChannel? = null
    private var pipAllowed = false

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
                "setPipAllowed" -> {
                    pipAllowed = call.argument<Boolean>("allowed") == true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setPictureInPictureParams(pipParams())
                    }
                    result.success(pipAllowed)
                }
                "enterPip" -> {
                    result.success(enterPip())
                }
                else -> result.notImplemented()
            }
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
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipAllowed)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
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
}

package com.socialsave.social_save

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.core.content.FileProvider
import com.yausername.ffmpeg.FFmpeg
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/**
 * Prepares a photo or video for a WhatsApp status the way a status app does:
 * one clean H.264 file per 30 seconds, correct color range, no fade and no
 * upscale. WhatsApp still recompresses, but it is handed a file it does not
 * have to crush from 4K. A photo becomes a short still video, which is how a
 * status photo stays sharper than a JPEG upload.
 */
object StatusPrep {
    @Volatile
    var progress: String = ""

    private val busy = Any()
    private var running = false

    fun prepare(ctx: Context, path: String?, uri: String?, photo: Boolean): Map<String, Any?> {
        synchronized(busy) {
            if (running) throw IllegalStateException("A status is already being prepared.")
            running = true
        }
        try {
            progress = "Opening the file"
            val source = sourceFile(ctx, path, uri, photo)
            val (bin, libPath) = ffmpegBin(ctx)
            val outDir = File(ctx.cacheDir, "status_hd")
            outDir.deleteRecursively()
            outDir.mkdirs()
            val durationMs = if (photo) 0L else durationMs(source)
            val seconds = if (photo) 5 else ((durationMs + 999) / 1000).toInt().coerceAtLeast(1)
            val total = if (photo) 1 else (seconds + PART_SEC - 1) / PART_SEC
            val clipped = total > MAX_PARTS
            val parts = total.coerceAtMost(MAX_PARTS)
            val made = ArrayList<Map<String, Any?>>()
            for (i in 0 until parts) {
                progress = if (photo) "Preparing the photo" else "Preparing part ${i + 1} of $parts"
                val out = File(outDir, "status-${i + 1}.mp4")
                val start = i * PART_SEC
                encode(ctx, bin, libPath, source, out, photo, start)
                if (!out.exists() || out.length() < 1024) {
                    throw IllegalStateException("The prepared file was empty.")
                }
                made.add(
                    mapOf(
                        "path" to out.absolutePath,
                        "part" to (i + 1),
                        "total" to parts,
                        "bytes" to out.length(),
                    ),
                )
            }
            progress = "Ready"
            return mapOf(
                "parts" to made,
                "clipped" to clipped,
                "photo" to photo,
            )
        } finally {
            synchronized(busy) { running = false }
        }
    }

    fun share(activity: Activity, path: String?, business: Boolean): String {
        val file = File(path ?: return "missing")
        if (!file.exists()) return "missing"
        val pkg = if (business) "com.whatsapp.w4b" else "com.whatsapp"
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("status", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            setPackage(pkg)
        }
        return try {
            activity.grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            activity.startActivity(intent)
            "ok"
        } catch (_: ActivityNotFoundException) {
            "missing_app"
        }
    }

    private fun sourceFile(ctx: Context, path: String?, uri: String?, photo: Boolean): File {
        if (!path.isNullOrBlank()) {
            val file = File(path)
            if (file.exists() && file.canRead()) return file
        }
        if (uri.isNullOrBlank()) throw IllegalStateException("Could not open that file.")
        val ext = if (photo) ".jpg" else ".mp4"
        val dest = File(ctx.cacheDir, "status_hd_source$ext")
        ctx.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("Could not read that file.")
        return dest
    }

    private fun durationMs(file: File): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(file.absolutePath)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
    }

    /** libffmpeg.so plus the library path its process has to use. */
    fun ffmpegCommand(ctx: Context): Pair<File, String> = ffmpegBin(ctx)

    private fun ffmpegBin(ctx: Context): Pair<File, String> {
        try {
            FFmpeg.init(ctx.applicationContext)
        } catch (e: Exception) {
            throw IllegalStateException("This phone can't prepare a status video.")
        }
        val nativeDir = ctx.applicationInfo.nativeLibraryDir
        val bin = File(nativeDir, "libffmpeg.so")
        val libs = File(ctx.noBackupFilesDir, "youtubedl-android/packages/ffmpeg/usr/lib")
        if (!bin.exists() || !libs.isDirectory) {
            throw IllegalStateException("This phone can't prepare a status video.")
        }
        // librubberband and libx265 need libc++_shared.so. That file, plus
        // libcrypto, libexpat, and the Termux Android shims, ship in the
        // Python zip, not in the ffmpeg zip. The linker only searches usr/lib.
        copyEncoderSupport(ctx, libs)
        bin.setExecutable(true)
        val pythonLibs = File(ctx.noBackupFilesDir, "youtubedl-android/packages/python/usr/lib")
        val libPath = buildString {
            append(libs.absolutePath)
            if (pythonLibs.isDirectory) {
                append(':')
                append(pythonLibs.absolutePath)
            }
            append(':')
            append(nativeDir)
        }
        return bin to libPath
    }

    private fun copyEncoderSupport(ctx: Context, libs: File) {
        val zipFile = File(ctx.applicationInfo.nativeLibraryDir, "libpython.zip.so")
        if (!zipFile.isFile) throw IllegalStateException("This phone can't prepare a status video.")
        val copies = listOf(
            "usr/lib/libc++_shared.so" to "libc++_shared.so",
            "usr/lib/libandroid-posix-semaphore.so" to "libandroid-posix-semaphore.so",
            "usr/lib/libandroid-support.so" to "libandroid-support.so",
            "usr/lib/libcrypto.so.3" to "libcrypto.so.3",
            // SONAME is libexpat.so.1. The zip stores the real file under the versioned name.
            "usr/lib/libexpat.so.1.11.1" to "libexpat.so.1",
        )
        ZipFile(zipFile).use { zip ->
            for ((entryName, fileName) in copies) {
                val entry = zip.getEntry(entryName)
                    ?: throw IllegalStateException("This phone can't prepare a status video.")
                val dest = File(libs, fileName)
                if (dest.isFile && dest.length() == entry.size) continue
                val part = File(libs, "$fileName.part")
                zip.getInputStream(entry).use { input ->
                    part.outputStream().use { output -> input.copyTo(output) }
                }
                if (dest.exists() && !dest.delete()) {
                    part.delete()
                    throw IllegalStateException("This phone can't prepare a status video.")
                }
                if (!part.renameTo(dest)) {
                    part.copyTo(dest, overwrite = true)
                    part.delete()
                }
                dest.setReadable(true, false)
            }
        }
    }

    private fun encode(ctx: Context, bin: File, libPath: String, source: File, out: File, photo: Boolean, startSec: Int) {
        // Fits inside 1920 and never upscales. No crop, no fade.
        val scale = "scale=1920:1920:force_original_aspect_ratio=decrease:flags=lanczos"
        val cmd = ArrayList<String>()
        cmd.add(bin.absolutePath)
        cmd.add("-y")
        cmd.add("-hide_banner")
        cmd.add("-loglevel")
        cmd.add("error")
        if (photo) {
            cmd.add("-loop")
            cmd.add("1")
            cmd.add("-i")
            cmd.add(source.absolutePath)
            cmd.add("-t")
            cmd.add(PHOTO_SEC.toString())
            cmd.add("-vf")
            cmd.add("$scale,fps=30,format=yuv420p")
            cmd.add("-an")
        } else {
            cmd.add("-ss")
            cmd.add(startSec.toString())
            cmd.add("-t")
            cmd.add(PART_SEC.toString())
            cmd.add("-i")
            cmd.add(source.absolutePath)
            cmd.add("-vf")
            cmd.add("$scale,format=yuv420p")
            cmd.add("-map")
            cmd.add("0:v:0")
            cmd.add("-map")
            cmd.add("0:a:0?")
            cmd.add("-c:a")
            cmd.add("aac")
            cmd.add("-b:a")
            cmd.add("160k")
            cmd.add("-ac")
            cmd.add("2")
            cmd.add("-ar")
            cmd.add("48000")
        }
        cmd.add("-c:v")
        cmd.add("libx264")
        cmd.add("-profile:v")
        cmd.add("high")
        cmd.add("-level:v")
        cmd.add("4.1")
        cmd.add("-pix_fmt")
        cmd.add("yuv420p")
        cmd.add("-crf")
        cmd.add(if (photo) "16" else "18")
        cmd.add("-maxrate")
        cmd.add("4500k")
        cmd.add("-bufsize")
        cmd.add("9000k")
        cmd.add("-preset")
        cmd.add("veryfast")
        cmd.add("-color_range")
        cmd.add("tv")
        cmd.add("-colorspace")
        cmd.add("bt709")
        cmd.add("-color_primaries")
        cmd.add("bt709")
        cmd.add("-color_trc")
        cmd.add("bt709")
        cmd.add("-movflags")
        cmd.add("+faststart")
        cmd.add(out.absolutePath)
        val process = ProcessBuilder(cmd).redirectErrorStream(true).apply {
            environment()["LD_LIBRARY_PATH"] = libPath
            environment()["TMPDIR"] = ctx.cacheDir.absolutePath
        }.start()
        val log = process.inputStream.bufferedReader().use { it.readText() }
        if (!process.waitFor(8, TimeUnit.MINUTES)) {
            process.destroyForcibly()
            throw IllegalStateException("Preparing the status took too long.")
        }
        if (process.exitValue() != 0) {
            val tail = log.lineSequence().map { it.trim() }.lastOrNull { it.isNotEmpty() }
            throw IllegalStateException(tail ?: "Could not prepare that file.")
        }
    }

    private const val PART_SEC = 30
    private const val PHOTO_SEC = 5
    private const val MAX_PARTS = 20
}

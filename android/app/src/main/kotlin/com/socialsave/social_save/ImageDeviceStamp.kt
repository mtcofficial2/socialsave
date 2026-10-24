package com.socialsave.social_save

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Rewrites a still photo so its camera details name this phone.
 * A JPEG is updated in place. Other still photos are saved as a new JPEG.
 * The original pixels of a JPEG are not recompressed.
 */
internal object ImageDeviceStamp {
    fun stamp(context: Context, path: String?): Map<String, Any?> {
        if (path.isNullOrBlank()) throw IllegalArgumentException("Choose a picture first.")
        val source = File(path)
        if (!source.isFile || source.length() < 32) {
            throw IllegalArgumentException("That picture is not on this device.")
        }
        val ext = source.extension.lowercase(Locale.US)
        if (ext == "gif") {
            throw IllegalArgumentException("An animated picture stays as it is. Choose a still photo.")
        }
        if (ext == "jpg" || ext == "jpeg") {
            if (source.canWrite() && apply(source)) {
                scan(context, source)
                return done(source, copied = false)
            }
        } else if (ext !in stillExt && !decodes(source)) {
            throw IllegalArgumentException("Choose a photo. This file is not a picture.")
        }
        val jpeg = renderJpeg(context, source)
        try {
            if (!apply(jpeg)) {
                throw IllegalStateException("This picture could not keep the camera details.")
            }
            val name = cameraName(source.name)
            val dest = if (source.parentFile?.canWrite() == true) {
                val file = uniqueFile(source.parentFile!!, name)
                jpeg.copyTo(file, overwrite = false)
                file
            } else {
                publish(context, jpeg, name)
            }
            scan(context, dest)
            return done(dest, copied = true)
        } finally {
            jpeg.delete()
        }
    }

    private fun done(file: File, copied: Boolean): Map<String, Any?> {
        return mapOf(
            "path" to file.absolutePath,
            "copied" to copied,
            "model" to model(),
        )
    }

    /** Writes this phone's make and model, and drops tags that name somewhere else. */
    private fun apply(file: File): Boolean {
        return try {
            val exif = ExifInterface(file.absolutePath)
            val now = Date()
            val stamp = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).apply {
                timeZone = TimeZone.getDefault()
            }.format(now)
            val offset = zoneOffset(now)
            exif.setAttribute(ExifInterface.TAG_MAKE, make())
            exif.setAttribute(ExifInterface.TAG_MODEL, model())
            exif.setAttribute(ExifInterface.TAG_DATETIME, stamp)
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, stamp)
            exif.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, stamp)
            exif.setAttribute(ExifInterface.TAG_OFFSET_TIME, offset)
            exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, offset)
            exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_DIGITIZED, offset)
            exif.setAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, "000")
            for (tag in foreign) exif.setAttribute(tag, null)
            exif.saveAttributes()
            stripForeignSegments(file)
            val read = ExifInterface(file.absolutePath)
            read.getAttribute(ExifInterface.TAG_MAKE) == make() &&
                read.getAttribute(ExifInterface.TAG_MODEL) == model()
        } catch (_: Exception) {
            false
        }
    }

    private fun renderJpeg(context: Context, source: File): File {
        val dest = File(context.cacheDir, "ss-camera-${System.currentTimeMillis()}.jpg")
        val ext = source.extension.lowercase(Locale.US)
        if (ext == "jpg" || ext == "jpeg") {
            source.copyTo(dest, overwrite = true)
            return dest
        }
        val bitmap = decodeUpright(source)
        try {
            FileOutputStream(dest).use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output)) {
                    throw IllegalStateException("This picture could not be saved.")
                }
            }
        } finally {
            bitmap.recycle()
        }
        return dest
    }

    private fun decodeUpright(file: File): Bitmap {
        val raw = BitmapFactory.decodeFile(file.absolutePath)
            ?: throw IllegalArgumentException("This picture could not be read.")
        val orientation = try {
            ExifInterface(file.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.preScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.preScale(-1f, 1f)
            }
            else -> return raw
        }
        val turned = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
        if (turned != raw) raw.recycle()
        return turned
    }

    private fun decodes(file: File): Boolean {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, opts)
        return opts.outWidth > 0 && opts.outHeight > 0
    }

    private fun publish(context: Context, jpeg: File, name: String): File {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_DCIM}/Camera")
                put(MediaStore.Images.Media.DATE_TAKEN, System.currentTimeMillis())
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not save the picture.")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    jpeg.inputStream().use { it.copyTo(output) }
                } ?: throw IllegalStateException("Could not save the picture.")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            val stored = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            if (!stored.isNullOrBlank()) return File(stored)
            throw IllegalStateException("Could not save the picture.")
        }
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Camera")
        if (!dir.isDirectory) dir.mkdirs()
        val dest = uniqueFile(dir, name)
        jpeg.copyTo(dest, overwrite = false)
        return dest
    }

    private fun scan(context: Context, file: File) {
        try {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
        } catch (_: Exception) {
        }
    }

    /** Drops XMP and IPTC blocks that still name the original site or camera. */
    private fun stripForeignSegments(file: File) {
        val bytes = file.readBytes()
        if (bytes.size < 4 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return
        val out = ByteArrayOutputStream(bytes.size)
        out.write(bytes, 0, 2)
        var index = 2
        var changed = false
        while (index + 4 < bytes.size) {
            if (bytes[index] != 0xFF.toByte()) {
                out.write(bytes, index, bytes.size - index)
                break
            }
            val marker = bytes[index + 1].toInt() and 0xFF
            if (marker == 0xDA) {
                out.write(bytes, index, bytes.size - index)
                break
            }
            if (marker == 0x01 || marker == 0xD9 || marker in 0xD0..0xD8) {
                out.write(bytes, index, 2)
                index += 2
                continue
            }
            val length = ((bytes[index + 2].toInt() and 0xFF) shl 8) or (bytes[index + 3].toInt() and 0xFF)
            val span = 2 + length
            if (length < 2 || index + span > bytes.size) {
                out.write(bytes, index, bytes.size - index)
                break
            }
            val drop = marker == 0xED || (marker == 0xE1 && isXmp(bytes, index + 4, length - 2))
            if (drop) changed = true else out.write(bytes, index, span)
            index += span
        }
        if (changed) file.writeBytes(out.toByteArray())
    }

    private fun isXmp(bytes: ByteArray, start: Int, count: Int): Boolean {
        val sig = "http://ns.adobe.com/xap/1.0/".toByteArray(Charsets.US_ASCII)
        if (count < sig.size || start < 0 || start + sig.size > bytes.size) return false
        for (i in sig.indices) if (bytes[start + i] != sig[i]) return false
        return true
    }

    private fun cameraName(raw: String): String {
        val dot = raw.lastIndexOf('.')
        val base = if (dot > 0) raw.substring(0, dot) else raw
        val clean = base.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").trim().ifBlank { "photo" }
        return "${clean.take(80)} camera.jpg"
    }

    private fun uniqueFile(dir: File, name: String): File {
        var file = File(dir, name)
        var n = 2
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        while (file.exists() && n < 1000) {
            file = File(dir, "$base $n$ext")
            n++
        }
        return file
    }

    private fun make(): String = Build.MANUFACTURER.ifBlank { "Android" }

    private fun model(): String = Build.MODEL.ifBlank { "phone" }

    private fun zoneOffset(date: Date): String {
        val minutes = TimeZone.getDefault().getOffset(date.time) / 60000
        val sign = if (minutes >= 0) "+" else "-"
        val abs = kotlin.math.abs(minutes)
        return String.format(Locale.US, "%s%02d:%02d", sign, abs / 60, abs % 60)
    }

    private val stillExt = setOf("png", "webp", "heic", "heif", "bmp")

    private val foreign = arrayOf(
        ExifInterface.TAG_SOFTWARE,
        ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_COPYRIGHT,
        ExifInterface.TAG_IMAGE_DESCRIPTION,
        ExifInterface.TAG_USER_COMMENT,
        ExifInterface.TAG_IMAGE_UNIQUE_ID,
        ExifInterface.TAG_MAKER_NOTE,
        ExifInterface.TAG_CAMERA_OWNER_NAME,
        ExifInterface.TAG_BODY_SERIAL_NUMBER,
        ExifInterface.TAG_LENS_MAKE,
        ExifInterface.TAG_LENS_MODEL,
        ExifInterface.TAG_LENS_SERIAL_NUMBER,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD,
    )
}

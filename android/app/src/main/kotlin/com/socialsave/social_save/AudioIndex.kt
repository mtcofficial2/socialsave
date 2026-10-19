package com.socialsave.social_save

import android.content.ContentUris
import android.content.Context
import android.database.ContentObserver
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.io.File

/**
 * The whole-device music index: every MediaStore audio volume (internal
 * storage and SD cards), a bounded walk of the usual music folders for files
 * the scanner has not indexed yet, and one debounced observer so new songs
 * show up without polling.
 */
object AudioIndex {
    private val audioExt = setOf("mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "wma", "amr", "mka")

    /** Audio collections for every mounted external volume. */
    private fun collections(ctx: Context): List<Uri> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val vols = try { MediaStore.getExternalVolumeNames(ctx) } catch (_: Exception) { emptySet<String>() }
            val l = vols.filter { it != MediaStore.VOLUME_EXTERNAL }.map { MediaStore.Audio.Media.getContentUri(it) }
            if (l.isNotEmpty()) return l
        }
        return listOf(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)
    }

    fun query(ctx: Context): Map<String, Any?> {
        val items = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        val cols = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.IS_RINGTONE,
            MediaStore.Audio.Media.IS_NOTIFICATION,
            MediaStore.Audio.Media.IS_ALARM,
            MediaStore.Audio.Media.IS_MUSIC,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) cols.add(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
        var volumes = 0
        for (coll in collections(ctx)) {
            volumes++
            try {
                ctx.contentResolver.query(coll, cols.toTypedArray(), null, null, "${MediaStore.Audio.Media.DATE_ADDED} DESC")?.use { c ->
                    fun idx(n: String) = c.getColumnIndex(n)
                    val iId = idx(MediaStore.Audio.Media._ID); val iName = idx(MediaStore.Audio.Media.DISPLAY_NAME)
                    val iSize = idx(MediaStore.Audio.Media.SIZE); val iDate = idx(MediaStore.Audio.Media.DATE_ADDED)
                    val iData = idx(MediaStore.Audio.Media.DATA); val iMime = idx(MediaStore.Audio.Media.MIME_TYPE)
                    val iDur = idx(MediaStore.Audio.Media.DURATION); val iTitle = idx(MediaStore.Audio.Media.TITLE)
                    val iArtist = idx(MediaStore.Audio.Media.ARTIST); val iAlbum = idx(MediaStore.Audio.Media.ALBUM)
                    val iRing = idx(MediaStore.Audio.Media.IS_RINGTONE); val iNoti = idx(MediaStore.Audio.Media.IS_NOTIFICATION)
                    val iAlarm = idx(MediaStore.Audio.Media.IS_ALARM); val iBucket = idx("bucket_display_name")
                    while (c.moveToNext()) {
                        val id = c.getLong(iId)
                        val path = if (iData >= 0) c.getString(iData) else null
                        if (path != null && !seen.add(path)) continue
                        fun s(i: Int) = if (i >= 0) c.getString(i) else null
                        fun b(i: Int) = i >= 0 && c.getInt(i) != 0
                        items.add(mapOf(
                            "id" to id.toString(),
                            "uri" to ContentUris.withAppendedId(coll, id).toString(),
                            "path" to path,
                            "name" to s(iName),
                            "size" to (if (iSize >= 0) c.getLong(iSize) else 0L),
                            "addedAt" to (if (iDate >= 0) c.getLong(iDate) else 0L),
                            "durationMs" to (if (iDur >= 0) c.getLong(iDur) else 0L),
                            "mime" to s(iMime),
                            "title" to s(iTitle),
                            "artist" to s(iArtist),
                            "album" to s(iAlbum),
                            "bucket" to s(iBucket),
                            "system" to (b(iRing) || b(iNoti) || b(iAlarm)),
                        ))
                    }
                }
            } catch (_: Exception) {}
        }
        return mapOf("items" to items, "volumes" to volumes)
    }

    /** Storage roots: internal plus any SD card. */
    private fun roots(ctx: Context): List<File> {
        val out = linkedSetOf<File>()
        out.add(Environment.getExternalStorageDirectory())
        for (d in ctx.getExternalFilesDirs(null)) {
            val p = d?.absolutePath ?: continue
            val i = p.indexOf("/Android/")
            if (i > 0) out.add(File(p.substring(0, i)))
        }
        return out.toList()
    }

    private val folders = listOf(
        "Download", "Downloads", "Music", "Audio", "Podcasts", "Audiobooks", "SocialSave",
        "Download/SocialSave", "Music/SocialSave", "Telegram/Telegram Audio", "Telegram/Telegram Documents",
        "Android/media/org.telegram.messenger/Telegram/Telegram Audio",
        "Android/media/org.telegram.messenger/Telegram/Telegram Documents",
        "WhatsApp/Media/WhatsApp Audio", "WhatsApp/Media/WhatsApp Documents",
        "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio",
        "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents",
        "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Audio",
        "Bluetooth", "Documents", "snaptube/download", "VidMate/download", "Xender/audio", "SHAREit/audios",
    )

    /**
     * Files in the usual folders that MediaStore does not know yet. Bounded
     * depth and count; each one found is handed to the media scanner.
     */
    fun walk(ctx: Context, known: Set<String>): List<String> {
        val found = ArrayList<String>()
        val visited = HashSet<String>()
        fun go(d: File, depth: Int) {
            if (depth > 4 || found.size > 2000) return
            val canon = try { d.canonicalPath } catch (_: Exception) { return }
            if (!visited.add(canon)) return
            val list = try { d.listFiles() } catch (_: Exception) { null } ?: return
            if (list.any { it.name == ".nomedia" }) return
            for (f in list) {
                if (f.name.startsWith(".")) continue
                if (f.isDirectory) go(f, depth + 1)
                else if (f.extension.lowercase() in audioExt && f.length() > 0 && f.absolutePath !in known) found.add(f.absolutePath)
            }
        }
        for (r in roots(ctx)) for (sub in folders) {
            val d = File(r, sub)
            if (d.isDirectory) go(d, 0)
        }
        if (found.isNotEmpty()) {
            try { MediaScannerConnection.scanFile(ctx.applicationContext, found.toTypedArray(), null, null) } catch (_: Exception) {}
        }
        return found
    }

    private var observer: ContentObserver? = null
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    /** One observer on every audio collection; fires [onChange] at most every 1.5 s. */
    fun watch(ctx: Context, onChange: () -> Unit) {
        unwatch(ctx)
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                pending?.let { main.removeCallbacks(it) }
                val r = Runnable { onChange() }
                pending = r
                main.postDelayed(r, 1500)
            }
        }
        observer = o
        val cr = ctx.contentResolver
        try { cr.registerContentObserver(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, true, o) } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            for (u in collections(ctx)) try { cr.registerContentObserver(u, true, o) } catch (_: Exception) {}
        }
    }

    fun unwatch(ctx: Context) {
        pending?.let { main.removeCallbacks(it) }
        pending = null
        observer?.let { try { ctx.contentResolver.unregisterContentObserver(it) } catch (_: Exception) {} }
        observer = null
    }
}

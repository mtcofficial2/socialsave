package com.socialsave.social_save

import android.content.Context
import android.provider.MediaStore

/** MediaStore id for a video path, used as the library collection key. */
object MediaIds {
    fun videoId(ctx: Context, path: String?): String? {
        if (path.isNullOrBlank()) return null
        val uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        return try {
            ctx.contentResolver.query(
                uri,
                arrayOf(MediaStore.Video.Media._ID),
                "${MediaStore.Video.Media.DATA}=?",
                arrayOf(path),
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                cursor.getLong(0).toString()
            }
        } catch (_: Exception) {
            null
        }
    }
}

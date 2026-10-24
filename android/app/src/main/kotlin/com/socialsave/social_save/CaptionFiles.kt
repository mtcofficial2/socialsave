package com.socialsave.social_save

import android.content.Context
import java.io.File

/**
 * Burns a saved caption file into a new copy of the video.
 * The original file is left as it is. Failure throws and changes nothing.
 */
object CaptionFiles {
    fun burn(ctx: Context, videoPath: String?): String {
        val video = File(videoPath ?: throw IllegalStateException("That video is not on this phone."))
        if (!video.isFile) throw IllegalStateException("That video is not on this phone.")
        val sub = listOf("srt", "vtt", "ass")
            .map { File(video.parentFile, video.nameWithoutExtension + "." + it) }
            .firstOrNull { it.isFile && it.length() > 8 }
            ?: throw IllegalStateException("No caption file is saved beside this video.")
        val (bin, libPath) = try {
            StatusPrep.ffmpegCommand(ctx.applicationContext)
        } catch (_: Exception) {
            throw IllegalStateException("This phone can't burn captions in.")
        }
        val out = File(video.parentFile, video.nameWithoutExtension + ".captions.mp4")
        if (out.exists()) out.delete()
        val escaped = sub.absolutePath.replace("\\", "/").replace(":", "\\:").replace("'", "\\'")
        val cmd = listOf(
            bin.absolutePath,
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", video.absolutePath,
            "-vf", "subtitles='$escaped'",
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-movflags", "+faststart",
            out.absolutePath,
        )
        val proc = ProcessBuilder(cmd)
            .redirectErrorStream(true)
            .apply { environment()["LD_LIBRARY_PATH"] = libPath }
            .start()
        val err = proc.inputStream.bufferedReader().readText()
        val code = proc.waitFor()
        if (code != 0 || !out.isFile || out.length() < 1024) {
            out.delete()
            val why = err.trim().lineSequence().lastOrNull()?.take(180).orEmpty()
            throw IllegalStateException(
                if (why.isEmpty()) "Could not burn the captions in. The original video is unchanged."
                else "Could not burn the captions in. The original video is unchanged. $why",
            )
        }
        return out.absolutePath
    }
}

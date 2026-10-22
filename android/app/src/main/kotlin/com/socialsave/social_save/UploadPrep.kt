package com.socialsave.social_save

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max

/**
 * Makes a downloaded video something TikTok can open: H.264, 8-bit 4:2:0,
 * AAC-LC when there is sound, moov at the front, constant 30 fps.
 * Landscape and square are fitted into 1920×1080. Portrait stays portrait and
 * is fitted into 1080×1920. The picture is never stretched or cropped. A file
 * that already matches is left alone. A file that only needs a new container
 * is remuxed. The phone's video chip does the picture when it can.
 */
object UploadPrep {
    private const val TAG = "UploadPrep"
    private val cancel = AtomicBoolean(false)
    private val trace = StringBuilder()
    private val done = java.util.concurrent.atomic.AtomicInteger(-1)
    @Volatile private var startedAt = 0L
    @Volatile private var stage = ""

    /** Fraction done (0..1, or -1 when unknown), time left and the current step, for the progress dialog. */
    fun progress(): Map<String, Any> {
        val permille = done.get()
        val elapsed = android.os.SystemClock.elapsedRealtime() - startedAt
        val eta = if (permille in 20..999 && startedAt > 0) elapsed * (1000 - permille) / permille else -1L
        return mapOf("fraction" to (if (permille < 0) -1.0 else permille / 1000.0), "etaMs" to eta, "stage" to stage)
    }

    internal fun setProgress(fraction: Double, step: String? = null) {
        val value = (fraction.coerceIn(0.0, 1.0) * 1000).toInt()
        // Only forward, so the bar never jumps back.
        done.updateAndGet { old -> if (value > old) value else old }
        if (step != null) stage = step
    }

    /** Last prepare notes, for a debug test. One line each. */
    fun notes(): String = synchronized(trace) { trace.toString() }

    internal fun notePublic(message: String) = note(message)

    private fun note(message: String) {
        Log.i(TAG, message)
        synchronized(trace) {
            if (trace.isNotEmpty()) trace.append('\n')
            trace.append(message)
        }
    }

    fun cancel() {
        cancel.set(true)
    }

    internal fun stopped(): Boolean = cancel.get()

    /** True when this video is not already the TikTok target. */
    fun needsWork(ctx: Context, path: String?): Boolean {
        val job = look(ctx, path) ?: return false
        return !job.clip.ready(moovIsNearStart(job.source))
    }

    fun prepare(ctx: Context, path: String?): String? {
        cancel.set(false)
        trace.setLength(0)
        done.set(-1)
        stage = "Checking the video"
        startedAt = android.os.SystemClock.elapsedRealtime()
        val job = look(ctx, path) ?: return path
        val source = job.source
        val clip = job.clip
        note(
            "target ${clip.outW}x${clip.outH} from ${clip.dispW}x${clip.dispH} " +
                "fps ${clip.fps} ${clip.video} picture ${clip.pictureOk}",
        )
        if (clip.ready(moovIsNearStart(source))) {
            note("already ready")
            return path
        }
        if (stopped()) return path
        val ext = source.extension.lowercase()
        val out = File(source.parentFile, source.nameWithoutExtension + ".ready.mp4")
        if (out.exists()) out.delete()
        val hwFile = File(ctx.cacheDir, "tiktok-" + System.nanoTime() + ".mp4")
        var wrote = false
        if (!clip.pictureOk) {
            // Cache, not the download folder. MediaMuxer fails on some shared
            // storage paths and that used to drop through to a full software encode.
            setProgress(0.0, "Rewriting the picture")
            val hw = HardwareTranscode.transcode(source, hwFile, bitrateBits(clip.outW, clip.outH), clip.outW, clip.outH)
            note("hardware result $hw ${clip.video} ${clip.outW}x${clip.outH}")
            if (!stopped() && (hw == 1 || hw == 2)) {
                setProgress(0.96, "Finishing")
                val audioFrom = if (hw == 2 && clip.hasAudio) source else null
                wrote = remux(ctx, job, hwFile, audioFrom, out)
            }
            hwFile.delete()
            if (wrote && !acceptable(ctx, job, out)) {
                Log.w(TAG, "chip file failed the check")
                out.delete()
                wrote = false
            }
        } else {
            val audioFrom = if (!clip.audioOk && clip.hasAudio) source else null
            setProgress(0.5, "Repacking")
            wrote = remux(ctx, job, source, audioFrom, out)
            if (wrote && !acceptable(ctx, job, out)) {
                Log.w(TAG, "remux failed the check")
                out.delete()
                wrote = false
            }
        }
        if (!wrote && !stopped()) {
            if (out.exists()) out.delete()
            wrote = write(ctx, job.libPath, command(job, out), out)
            if (wrote && !acceptable(ctx, job, out)) {
                Log.w(TAG, "software file failed the check")
                out.delete()
                wrote = false
            }
        }
        if (stopped()) {
            out.delete()
            hwFile.delete()
            return path
        }
        if (!wrote) {
            Log.w(TAG, "ffmpeg failed, keeping the original file")
            return path
        }
        val dest = if (ext == "mp4") source else File(source.parentFile, source.nameWithoutExtension + ".mp4")
        try {
        if (dest.absolutePath == source.absolutePath) {
            val bak = File(source.parentFile, source.name + ".bak")
            if (bak.exists()) bak.delete()
            if (!source.renameTo(bak)) {
                out.delete()
                return path
            }
            val moved = out.renameTo(source) || run {
                out.copyTo(source, overwrite = true)
                out.delete()
                source.isFile
            }
            if (!moved || source.length() < 1024) {
                source.delete()
                bak.renameTo(source)
                out.delete()
                return path
            }
            bak.delete()
        } else {
            if (dest.exists()) dest.delete()
            if (!out.renameTo(dest)) {
                out.copyTo(dest, overwrite = true)
                out.delete()
            }
            if (!dest.isFile || dest.length() < 1024) {
                dest.delete()
                return path
            }
            source.delete()
        }
        } catch (_: Exception) {
            val bak = File(source.parentFile, source.name + ".bak")
            if (bak.isFile && !source.isFile) bak.renameTo(source)
            out.delete()
            return if (source.isFile) source.absolutePath else path
        }
        dest.setReadable(true, false)
        return dest.absolutePath
    }

    private class Look(
        val source: File,
        val ffmpeg: File,
        val libPath: String,
        val clip: Clip,
    )

    private class Clip(
        val video: String,
        val pix: String,
        val hasAudio: Boolean,
        val audio: String,
        val dispW: Int,
        val dispH: Int,
        val outW: Int,
        val outH: Int,
        val fps: Double,
        val durationUs: Long,
        val rotation: Int,
    ) {
        val codecOk = video == "h264" && (pix == "yuv420p" || pix == "yuvj420p")
        val sizeOk = dispW == outW && dispH == outH
        val fpsOk = fps in 29.5..30.5
        val rotOk = ((rotation % 360) + 360) % 360 == 0
        // 1.0.50: TikTok takes H.264 8-bit 4:2:0 from 720p to 1080p at up to
        // 60 fps, so such a file only needs a new container (near instant)
        // instead of a full re-encode to exactly 1080p30.
        val longSide = max(dispW, dispH)
        val shortSide = minOf(dispW, dispH)
        // 1.0.51: up to 1080p and up to 30 fps only; 50/60 fps is re-encoded
        // to 30 by the video chip (TikTok-ready is a 30 fps target).
        val fastOk = codecOk && fps in 23.0..30.5 && longSide <= 1920 && shortSide <= 1080
        val pictureOk = (codecOk && sizeOk && fpsOk && rotOk) || fastOk
        val audioOk = !hasAudio || audio == "aac"
        fun ready(moov: Boolean) = pictureOk && audioOk && moov
    }

    private fun look(ctx: Context, path: String?): Look? {
        if (path.isNullOrBlank()) return null
        val source = File(path)
        if (!source.isFile || source.length() < 1024) return null
        val ext = source.extension.lowercase()
        if (ext !in setOf("mp4", "m4v", "mov", "mkv", "webm")) return null
        val ffmpeg: File
        val libPath: String
        try {
            val command = StatusPrep.ffmpegCommand(ctx.applicationContext)
            ffmpeg = command.first
            libPath = command.second
        } catch (_: Exception) {
            return null
        }
        val probe = File(ctx.applicationInfo.nativeLibraryDir, "libffprobe.so")
        if (!probe.isFile) return null
        // JSON keys. This ffprobe lists codec_name before codec_type.
        val info = run(ctx, probe, libPath, listOf(
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,r_frame_rate,duration:format=duration",
            "-of", "json",
            source.absolutePath,
        ), 2) ?: return null
        var video = ""
        var pix = ""
        var audio = ""
        var hasAudio = false
        var codedW = 0
        var codedH = 0
        var fps = 0.0
        var durationUs = 0L
        try {
            val root = JSONObject(info)
            val formatDur = root.optJSONObject("format")?.optString("duration") ?: ""
            durationUs = (seconds(formatDur) * 1_000_000.0).toLong()
            val streams = root.optJSONArray("streams") ?: return null
            for (i in 0 until streams.length()) {
                val stream = streams.optJSONObject(i) ?: continue
                when (stream.optString("codec_type")) {
                    "video" -> if (video.isEmpty()) {
                        video = stream.optString("codec_name")
                        pix = stream.optString("pix_fmt")
                        codedW = stream.optInt("width")
                        codedH = stream.optInt("height")
                        fps = constantFps(stream.optString("avg_frame_rate"), stream.optString("r_frame_rate"))
                        if (durationUs <= 0) durationUs = (seconds(stream.optString("duration")) * 1_000_000.0).toLong()
                    }
                    "audio" -> {
                        hasAudio = true
                        if (audio.isEmpty()) audio = stream.optString("codec_name")
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "ffprobe json, keeping the original file", e)
            return null
        }
        if (video.isEmpty()) return null
        val geo = geometry(source)
        val rot = geo?.third ?: 0
        val dw0 = if (rot == 90 || rot == 270) codedH else codedW
        val dh0 = if (rot == 90 || rot == 270) codedW else codedH
        val dispW = if (dw0 > 0) dw0 else geo?.first ?: 0
        val dispH = if (dh0 > 0) dh0 else geo?.second ?: 0
        if (durationUs <= 0) durationUs = geo?.fourth ?: 0L
        val (outW, outH) = targetSize(dispW, dispH)
        return Look(
            source, ffmpeg, libPath,
            Clip(video, pix, hasAudio, audio, dispW, dispH, outW, outH, fps, durationUs, rot),
        )
    }

    /**
     * Landscape and square fit inside 1920×1080. Portrait fits inside 1080×1920.
     * Both are 1080p. The picture is scaled to fit and padded, never stretched
     * or cropped, and a portrait clip is not placed on a landscape canvas.
     */
    internal fun targetSize(dispW: Int, dispH: Int): Pair<Int, Int> {
        if (dispW < 2 || dispH < 2) return 1920 to 1080
        return if (dispH > dispW) 1080 to 1920 else 1920 to 1080
    }

    private fun seconds(text: String): Double {
        return text.toDoubleOrNull() ?: 0.0
    }

    /** Average rate when it is a real frame rate. Ignores a bogus time-base. */
    private fun constantFps(avg: String, raw: String): Double {
        val average = rate(avg) ?: return 0.0
        val declared = rate(raw)
        if (declared != null && declared in 1.0..120.0 && abs(declared - average) > 1.0) {
            return declared
        }
        return average
    }

    private fun rate(text: String): Double? {
        if (text.isBlank() || text == "0/0" || text == "N/A") return null
        val parts = text.split("/")
        if (parts.size == 2) {
            val a = parts[0].toDoubleOrNull() ?: return null
            val b = parts[1].toDoubleOrNull() ?: return null
            if (b == 0.0) return null
            return a / b
        }
        return text.toDoubleOrNull()
    }

    /** Coded width, height, rotation, duration. Rotation decides which edge is long. */
    private fun geometry(file: File): Quad? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.absolutePath)
            var found: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    found = format
                    break
                }
            }
            val format = found ?: return null
            val w = if (format.containsKey(MediaFormat.KEY_WIDTH)) format.getInteger(MediaFormat.KEY_WIDTH) else 0
            val h = if (format.containsKey(MediaFormat.KEY_HEIGHT)) format.getInteger(MediaFormat.KEY_HEIGHT) else 0
            val rot = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                try { format.getInteger(MediaFormat.KEY_ROTATION) } catch (_: Exception) { 0 }
            } else {
                0
            }
            val dur = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            Quad(w, h, rot, dur)
        } catch (_: Exception) {
            null
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private class Quad(val first: Int, val second: Int, val third: Int, val fourth: Long)

    private fun bitrateBits(outW: Int, outH: Int): Int {
        val pixels = outW.toDouble() * outH.toDouble()
        val bits = 8_000_000.0 * pixels / (1920.0 * 1080.0)
        return bits.toInt().coerceIn(1_500_000, 12_000_000)
    }

    private fun addAac(cmd: ArrayList<String>) {
        cmd.add("-c:a")
        cmd.add("aac")
        cmd.add("-profile:a")
        cmd.add("aac_low")
        cmd.add("-b:a")
        cmd.add("160k")
        cmd.add("-ac")
        cmd.add("2")
        cmd.add("-ar")
        cmd.add("48000")
    }

    /** Puts the chip's picture and the sound into one file with moov at the front. */
    private fun remux(ctx: Context, job: Look, video: File, audioFrom: File?, dest: File): Boolean {
        if (dest.exists()) dest.delete()
        val cmd = ArrayList<String>()
        cmd.add(job.ffmpeg.absolutePath)
        cmd.add("-y")
        cmd.add("-hide_banner")
        cmd.add("-loglevel")
        cmd.add("error")
        cmd.add("-i")
        cmd.add(video.absolutePath)
        if (audioFrom != null) {
            cmd.add("-i")
            cmd.add(audioFrom.absolutePath)
            cmd.add("-map")
            cmd.add("0:v:0")
            cmd.add("-map")
            cmd.add("1:a:0")
            cmd.add("-c:v")
            cmd.add("copy")
            if (job.clip.audio == "aac") {
                cmd.add("-c:a")
                cmd.add("copy")
            } else {
                addAac(cmd)
            }
        } else {
            cmd.add("-c")
            cmd.add("copy")
        }
        // Color tags are left off a stream copy. Some builds reject them and
        // that used to throw away a finished chip picture.
        cmd.add("-movflags")
        cmd.add("+faststart")
        cmd.add(dest.absolutePath)
        val ok = run(ctx, null, job.libPath, cmd, 5) != null && dest.isFile && dest.length() >= 1024
        if (!ok) dest.delete()
        return ok
    }

    private fun command(job: Look, out: File): ArrayList<String> {
        val clip = job.clip
        val cmd = ArrayList<String>()
        cmd.add(job.ffmpeg.absolutePath)
        cmd.add("-y")
        cmd.add("-hide_banner")
        cmd.add("-loglevel")
        cmd.add("error")
        cmd.add("-i")
        cmd.add(job.source.absolutePath)
        cmd.add("-map")
        cmd.add("0:v:0")
        if (clip.hasAudio) {
            cmd.add("-map")
            cmd.add("0:a:0?")
        }
        // Used only when the phone's video chip cannot do this file.
        // Fit, pad, and lock 30 fps. No stretch and no crop.
        val w = clip.outW
        val h = clip.outH
        cmd.add("-vf")
        cmd.add(
            "scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos," +
                "pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,format=yuv420p",
        )
        cmd.add("-c:v")
        cmd.add("libx264")
        cmd.add("-preset")
        cmd.add("ultrafast")
        cmd.add("-threads")
        cmd.add("0")
        cmd.add("-crf")
        cmd.add("18")
        cmd.add("-profile:v")
        cmd.add("high")
        cmd.add("-level")
        cmd.add("4.2")
        cmd.add("-tag:v")
        cmd.add("avc1")
        cmd.add("-color_range")
        cmd.add("tv")
        cmd.add("-colorspace")
        cmd.add("bt709")
        cmd.add("-color_primaries")
        cmd.add("bt709")
        cmd.add("-color_trc")
        cmd.add("bt709")
        if (clip.hasAudio) {
            if (clip.audio == "aac") {
                cmd.add("-c:a")
                cmd.add("copy")
            } else {
                addAac(cmd)
            }
        } else {
            cmd.add("-an")
        }
        cmd.add("-max_muxing_queue_size")
        cmd.add("1024")
        cmd.add("-movflags")
        cmd.add("+faststart")
        cmd.add(out.absolutePath)
        return cmd
    }

    private fun write(ctx: Context, libPath: String, cmd: List<String>, out: File): Boolean {
        if (out.exists()) out.delete()
        if (run(ctx, null, libPath, cmd, 20) == null || !out.isFile || out.length() < 1024) {
            out.delete()
            return false
        }
        return true
    }

    /**
     * The file is finished only when a player can read a picture, the size and
     * frame rate match the target, sound is AAC when the source had sound, and
     * the length still lines up with the original.
     */
    private fun acceptable(ctx: Context, job: Look, file: File): Boolean {
        if (!file.isFile || file.length() < 1024) return false
        if (!moovIsNearStart(file)) return false
        val checked = look(ctx, file.absolutePath) ?: return false
        val clip = checked.clip
        val want = job.clip
        if (clip.video != "h264" || (clip.pix != "yuv420p" && clip.pix != "yuvj420p")) {
            Log.w(TAG, "check codec ${clip.video} ${clip.pix}")
            return false
        }
        // A kept picture (remux) keeps its own size and rate.
        val wantW = if (want.pictureOk) want.dispW else want.outW
        val wantH = if (want.pictureOk) want.dispH else want.outH
        if (clip.dispW != wantW || clip.dispH != wantH) {
            Log.w(TAG, "check size ${clip.dispW}x${clip.dispH} want ${wantW}x${wantH}")
            return false
        }
        val fpsRange = if (want.pictureOk) (want.fps - 1.0)..(want.fps + 1.0) else 29.5..30.5
        if (clip.fps !in fpsRange) {
            Log.w(TAG, "check fps ${clip.fps}")
            return false
        }
        if (want.hasAudio && clip.audio != "aac") {
            Log.w(TAG, "check audio ${clip.audio}")
            return false
        }
        if (want.durationUs > 0 && clip.durationUs > 0) {
            val slack = max(500_000L, want.durationUs / 20)
            if (abs(want.durationUs - clip.durationUs) > slack) {
                Log.w(TAG, "check duration ${clip.durationUs} want ${want.durationUs}")
                return false
            }
        }
        if (!decodes(file)) return false
        note("validated ${clip.dispW}x${clip.dispH} fps ${clip.fps} ${clip.durationUs}us ${clip.video} ${clip.pix} ${clip.audio}")
        return true
    }

    private fun decodes(file: File): Boolean {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        return try {
            extractor.setDataSource(file.absolutePath)
            var index = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(i)
                val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    index = i
                    format = candidate
                    break
                }
            }
            val video = format ?: return false
            if (index < 0) return false
            extractor.selectTrack(index)
            val mime = video.getString(MediaFormat.KEY_MIME) ?: return false
            val codec = MediaCodec.createDecoderByType(mime)
            decoder = codec
            codec.configure(video, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            val deadline = android.os.SystemClock.elapsedRealtime() + 2_000L
            var fed = 0
            while (android.os.SystemClock.elapsedRealtime() < deadline && fed < 90) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val buf = codec.getInputBuffer(inIndex) ?: return false
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime.coerceAtLeast(0), 0)
                        extractor.advance()
                        fed++
                    }
                }
                val out = codec.dequeueOutputBuffer(info, 10_000)
                if (out >= 0) {
                    var picture = false
                    try {
                        picture = info.size > 0
                        if (picture) {
                            var varied = 0
                            val raw = codec.getOutputBuffer(out)
                            if (raw != null && info.offset >= 0 && info.offset < raw.capacity()) {
                                val dup = raw.duplicate()
                                dup.position(info.offset)
                                val n = minOf(info.size, 2048)
                                var base = -1
                                for (i in 0 until n) {
                                    if (!dup.hasRemaining()) break
                                    val b = dup.get().toInt() and 0xFF
                                    if (base < 0) base = b else if (b != base) varied++
                                }
                            }
                            Log.i(TAG, "decode check size ${info.size} varied $varied")
                        }
                    } finally {
                        codec.releaseOutputBuffer(out, false)
                    }
                    if (picture) return true
                }
            }
            false
        } catch (e: Exception) {
            Log.w(TAG, "decode check failed", e)
            false
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun moovIsNearStart(file: File): Boolean {
        return try {
            file.inputStream().use { input ->
                val buf = ByteArray(256 * 1024)
                val n = input.read(buf)
                if (n <= 8) return false
                val text = String(buf, 0, n, Charsets.ISO_8859_1)
                text.contains("moov")
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun run(ctx: Context, bin: File?, libPath: String, cmd: List<String>, minutes: Long): String? {
        val command = if (bin == null) cmd else listOf(bin.absolutePath) + cmd
        val logFile = File(ctx.cacheDir, "upload-prep-" + System.nanoTime() + ".log")
        return try {
            // Write the log to a file. Reading the pipe first never reaches
            // the timeout, and waiting first can fill the pipe and stall.
            val process = ProcessBuilder(command).redirectErrorStream(true).redirectOutput(logFile).apply {
                environment()["LD_LIBRARY_PATH"] = libPath
                environment()["TMPDIR"] = ctx.cacheDir.absolutePath
            }.start()
            val deadline = System.nanoTime() + TimeUnit.MINUTES.toNanos(minutes)
            while (!process.waitFor(500, TimeUnit.MILLISECONDS)) {
                if (cancel.get() || System.nanoTime() > deadline) {
                    process.destroyForcibly()
                    return null
                }
            }
            if (process.exitValue() != 0) {
                val text = if (logFile.isFile) logFile.readText() else ""
                Log.w(TAG, "tool exit ${process.exitValue()} ${text.take(300)}")
                return null
            }
            if (logFile.isFile) logFile.readText() else ""
        } catch (_: Exception) {
            null
        } finally {
            logFile.delete()
        }
    }
}

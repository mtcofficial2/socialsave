package com.socialsave.social_save

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer

/**
 * Rewrites the picture with the phone's H.264 encoder at [outW]×[outH],
 * constant 30 fps, fitted without stretching. A software encode of a whole
 * video is what made TikTok preparation slow.
 * Returns 0 on failure, 1 when the file already includes AAC audio, or 2
 * when the file is picture-only and the caller still has to add the sound.
 */
object HardwareTranscode {
    private const val TAG = "UploadPrep"
    private const val TIMEOUT_US = 10_000L

    fun transcode(src: File, dest: File, bitrate: Int, outW: Int, outH: Int): Int {
        if (dest.exists()) dest.delete()
        val started = SystemClock.elapsedRealtime()
        val code = try {
            encode(src, dest, bitrate, outW, outH)
        } catch (e: Exception) {
            Log.w(TAG, "hardware transcode failed", e)
            0
        }
        if (code == 0 || !dest.isFile || dest.length() < 1024) {
            dest.delete()
            return 0
        }
        val line = "hardware transcode ${SystemClock.elapsedRealtime() - started} ms -> $code"
        Log.i(TAG, line)
        UploadPrep.notePublic(line)
        return code
    }

    private fun encode(src: File, dest: File, bitrate: Int, outW: Int, outH: Int): Int {
        if (outW < 2 || outH < 2) return 0
        var encoder: MediaCodec? = null
        var surface: Surface? = null
        var decoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var fit: FitSurface? = null
        val videoExtractor = MediaExtractor()
        val audioExtractor = MediaExtractor()
        try {
            videoExtractor.setDataSource(src.absolutePath)
            val videoIndex = track(videoExtractor, "video/")
            if (videoIndex < 0) return 0
            videoExtractor.selectTrack(videoIndex)
            val inFormat = videoExtractor.getTrackFormat(videoIndex)
            val coded = visibleSize(inFormat)
            val width = coded.first
            val height = coded.second
            if (width < 2 || height < 2) return 0
            val mime = inFormat.getString(MediaFormat.KEY_MIME) ?: return 0
            // Some files store frame-rate as a float. getInteger throws, and
            // that used to abandon the chip and fall through to libx264.
            val frameRate = if (inFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                intOrFloat(inFormat, MediaFormat.KEY_FRAME_RATE, 30).coerceIn(1, 240)
            } else {
                30
            }
            val durationUs = if (inFormat.containsKey(MediaFormat.KEY_DURATION)) inFormat.getLong(MediaFormat.KEY_DURATION) else 0L
            val rotation = if (inFormat.containsKey(MediaFormat.KEY_ROTATION)) {
                intOrFloat(inFormat, MediaFormat.KEY_ROTATION, 0)
            } else {
                0
            }
            val swap = rotation == 90 || rotation == 270
            val dispW = if (swap) height else width
            val dispH = if (swap) width else height

            // The output is 30 fps at the target size. The chip is asked to
            // run faster than playback. createDecoderByType prefers software
            // on some phones, which is what made a short video take longer
            // than its own length.
            val opened = openEncoder(outW, outH, bitrate, 30) ?: return giveUp("no encoder")
            encoder = opened
            val enc = opened
            val input = enc.createInputSurface()
            surface = input
            enc.start()
            UploadPrep.notePublic("encoder ${enc.name} ${outW}x$outH from ${dispW}x$dispH")

            val fitter = FitSurface()
            fit = fitter
            if (!fitter.start(input, width, height, dispW, dispH, rotation, outW, outH)) {
                return giveUp("no surface")
            }
            val decoderSurface = fitter.decoderInput() ?: return giveUp("no surface")
            decoder = openDecoder(mime, inFormat, decoderSurface) ?: return giveUp("no decoder")
            val dec = decoder ?: return giveUp("no decoder")
            UploadPrep.notePublic("decoder ${dec.name} $mime")

            val box = MediaMuxer(dest.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = box
            val state = Mux(box)
            state.audioFormat = aacFormat(src, audioExtractor)
            val drainNow = { drain(enc, state, untilEnd = false) }

            val deadline = SystemClock.elapsedRealtime() + deadlineMs(durationUs)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var signaled = false
            var lastPts = -1L
            var ptsBase = -1L
            var frames = 0
            val frameDur = 1_000_000L / frameRate.coerceAtLeast(1)
            while (!signaled && SystemClock.elapsedRealtime() < deadline) {
                if (UploadPrep.stopped()) return giveUp("cancelled")
                if (!inputDone) {
                    while (!inputDone) {
                        val inIndex = dec.dequeueInputBuffer(0)
                        if (inIndex < 0) break
                        val buf = dec.getInputBuffer(inIndex) ?: return giveUp("decoder buffer")
                        val size = videoExtractor.readSampleData(buf, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            // Editors stamp frames in order. A backwards timestamp
                            // makes the muxer throw, and that used to abandon the
                            // chip and re-encode the whole picture in software.
                            var pts = videoExtractor.sampleTime
                            if (pts < 0 || pts <= lastPts) pts = lastPts + frameDur
                            lastPts = pts
                            dec.queueInputBuffer(inIndex, 0, size, pts, 0)
                            videoExtractor.advance()
                        }
                    }
                }
                val wait = if (inputDone) TIMEOUT_US else 2_000L
                when (val outIndex = dec.dequeueOutputBuffer(info, wait)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> if (inputDone && !drainNow()) return giveUp("encoder stalled")
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                    else -> if (outIndex >= 0) {
                        val end = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        val render = info.size > 0
                        if (render) {
                            if (!drainNow()) return giveUp("encoder stalled")
                            dec.releaseOutputBuffer(outIndex, true)
                            val pts = if (info.presentationTimeUs >= 0) info.presentationTimeUs else lastPts
                            if (ptsBase < 0) ptsBase = pts
                            val rel = (pts - ptsBase).coerceAtLeast(0L)
                            if (!fitter.accept(rel, drainNow)) return giveUp("frame drop")
                            frames++
                            if (frames == 1 || frames % 60 == 0) Log.i(TAG, "chip frame $frames")
                        } else {
                            dec.releaseOutputBuffer(outIndex, false)
                        }
                        if (end) {
                            if (!fitter.finish(durationUs, drainNow)) return giveUp("frame drop")
                            enc.signalEndOfInputStream()
                            signaled = true
                        }
                    }
                }
            }
            if (!signaled || !drain(enc, state, untilEnd = true)) return giveUp("chip did not finish")
            if (!state.started || state.videoTrack < 0) return 0
            val withAudio = copyAac(audioExtractor, state, ptsBase.coerceAtLeast(0L))
            box.stop()
            box.release()
            muxer = null
            UploadPrep.notePublic("chip frames in $frames out ${outW}x$outH")
            return if (withAudio) 1 else 2
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            try { fit?.release() } catch (_: Exception) {}
            try { encoder?.stop() } catch (_: Exception) {}
            try { encoder?.release() } catch (_: Exception) {}
            try { surface?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            try { videoExtractor.release() } catch (_: Exception) {}
            try { audioExtractor.release() } catch (_: Exception) {}
        }
    }

    private fun visibleSize(format: MediaFormat): Pair<Int, Int> {
        val fullW = if (format.containsKey(MediaFormat.KEY_WIDTH)) format.getInteger(MediaFormat.KEY_WIDTH) else 0
        val fullH = if (format.containsKey(MediaFormat.KEY_HEIGHT)) format.getInteger(MediaFormat.KEY_HEIGHT) else 0
        val w = if (format.containsKey("crop-right") && format.containsKey("crop-left")) {
            format.getInteger("crop-right") - format.getInteger("crop-left") + 1
        } else {
            fullW
        }
        val h = if (format.containsKey("crop-bottom") && format.containsKey("crop-top")) {
            format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
        } else {
            fullH
        }
        return (w / 2 * 2) to (h / 2 * 2)
    }

    /** 0 when the chip cannot do this file. The caller then uses software. */
    private fun giveUp(reason: String): Int {
        UploadPrep.notePublic("hardware gave up: $reason")
        return 0
    }

    private fun intOrFloat(format: MediaFormat, key: String, fallback: Int): Int {
        return try {
            format.getInteger(key)
        } catch (_: Exception) {
            try {
                format.getFloat(key).toInt()
            } catch (_: Exception) {
                fallback
            }
        }
    }

    /**
     * Chip codecs only. Skips software, secure, and wireless-display encoders.
     * Vendor codecs are listed first. createDecoderByType is the wrong call
     * here because the software decoder outranks the chip.
     */
    private fun hardwareNames(mime: String, encoder: Boolean): List<String> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val names = ArrayList<String>()
        for (info in list.codecInfos) {
            if (info.isEncoder != encoder) continue
            if (info.supportedTypes.none { it.equals(mime, true) }) continue
            val lower = info.name.lowercase()
            if (lower.contains("secure") || lower.contains(".wfd") || lower.contains("wifi")) continue
            if (lower.contains("google") || lower.contains(".sw.") || lower.startsWith("c2.android")) continue
            names.add(info.name)
        }
        names.sortBy { name ->
            val lower = name.lowercase()
            if (lower.contains("exynos") || lower.contains("qcom") || lower.contains("qti") ||
                lower.contains("mtk") || lower.contains("mediatek") || lower.contains("hisi")
            ) 0 else 1
        }
        return names
    }

    private fun openEncoder(width: Int, height: Int, bitrate: Int, frameRate: Int): MediaCodec? {
        val names = hardwareNames(MediaFormat.MIMETYPE_VIDEO_AVC, encoder = true)
        for (name in names) {
            val formats = ArrayList<MediaFormat>()
            formats.add(encoderFormat(width, height, bitrate, frameRate, fast = true, profile = false))
            formats.add(encoderFormat(width, height, bitrate, frameRate, fast = true, profile = true))
            // Speed keys without the extras some chips reject. Still faster
            // than a plain configure, which locks the chip to playback speed.
            formats.add(encoderFormat(width, height, bitrate, frameRate, fast = false, profile = false, rateOnly = true))
            formats.add(encoderFormat(width, height, bitrate, frameRate, fast = false, profile = false))
            for (format in formats) {
                val codec = try {
                    MediaCodec.createByCodecName(name)
                } catch (_: Exception) {
                    null
                } ?: continue
                try {
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    return codec
                } catch (e: Exception) {
                    Log.w(TAG, "encoder $name rejected", e)
                    try { codec.release() } catch (_: Exception) {}
                }
            }
        }
        return null
    }

    private fun encoderFormat(
        width: Int,
        height: Int,
        bitrate: Int,
        frameRate: Int,
        fast: Boolean,
        profile: Boolean,
        rateOnly: Boolean = false,
    ): MediaFormat {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        if (profile) {
            format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            // Level 5.2 covers a 4K portrait frame. The constant is inlined.
            format.setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel52)
        }
        if (fast || rateOnly) {
            // Same request a video editor sends: run the chip as fast as it
            // can, instead of locking it to playback speed. A maxed operating
            // rate makes some encoders stall, so the rate stays finite.
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, 240)
        }
        if (fast) {
            // No B-frames: their timestamps arrive out of order and the muxer
            // then throws, which used to abandon the chip.
            format.setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
            )
            if (Build.VERSION.SDK_INT >= 29) {
                format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }
        return format
    }

    private fun openDecoder(mime: String, source: MediaFormat, surface: Surface): MediaCodec? {
        val names = ArrayList(hardwareNames(mime, encoder = false))
        try {
            val fallback = MediaCodec.createDecoderByType(mime)
            val soft = fallback.name
            fallback.release()
            if (!names.contains(soft)) names.add(soft)
        } catch (_: Exception) {
        }
        for (name in names) {
            for (format in decoderFormats(source)) {
                val codec = try {
                    MediaCodec.createByCodecName(name)
                } catch (_: Exception) {
                    null
                } ?: continue
                try {
                    codec.configure(format, surface, null, 0)
                    codec.start()
                    return codec
                } catch (e: Exception) {
                    Log.w(TAG, "decoder $name rejected", e)
                    try { codec.release() } catch (_: Exception) {}
                }
            }
        }
        return null
    }

    private fun decoderFormats(source: MediaFormat): List<MediaFormat> {
        fun fresh(): MediaFormat {
            val copy = if (Build.VERSION.SDK_INT >= 29) MediaFormat(source) else source
            if (Build.VERSION.SDK_INT >= 29 && copy.containsKey(MediaFormat.KEY_ROTATION)) {
                copy.removeKey(MediaFormat.KEY_ROTATION)
            }
            return copy
        }
        val fast = fresh()
        fast.setInteger(MediaFormat.KEY_PRIORITY, 0)
        fast.setInteger(MediaFormat.KEY_OPERATING_RATE, 240)
        if (Build.VERSION.SDK_INT >= 31) {
            fast.setInteger(
                MediaFormat.KEY_COLOR_TRANSFER_REQUEST,
                MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
            )
        }
        if (Build.VERSION.SDK_INT < 29) return listOf(fast)
        return listOf(fast, fresh())
    }

    private fun aacFormat(src: File, extractor: MediaExtractor): MediaFormat? {
        return try {
            extractor.setDataSource(src.absolutePath)
            val index = track(extractor, "audio/")
            if (index < 0) return null
            extractor.selectTrack(index)
            val format = extractor.getTrackFormat(index)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            if (mime.equals("audio/mp4a-latm", true)) format else null
        } catch (_: Exception) {
            null
        }
    }

    private fun track(extractor: MediaExtractor, prefix: String): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(prefix)) return i
        }
        return -1
    }

    private fun deadlineMs(durationUs: Long): Long {
        val videoMs = if (durationUs > 0) durationUs / 1000 else 60_000
        // A stuck chip attempt must not sit for a minute and a half before
        // the software backup starts. A working chip finishes well inside this.
        return (videoMs * 3).coerceIn(20_000L, 20 * 60_000L)
    }

    private class Mux(val muxer: MediaMuxer) {
        var started = false
        var videoTrack = -1
        var audioTrack = -1
        var audioFormat: MediaFormat? = null
    }

    private fun drain(encoder: MediaCodec, state: Mux, untilEnd: Boolean): Boolean {
        val info = MediaCodec.BufferInfo()
        val deadline = SystemClock.elapsedRealtime() + if (untilEnd) 20_000 else 0
        while (true) {
            if (untilEnd && SystemClock.elapsedRealtime() > deadline) return false
            val index = encoder.dequeueOutputBuffer(info, if (untilEnd) TIMEOUT_US else 0)
            when {
                // A final drain must wait for the end marker. Returning on the
                // first timeout used to throw away a finished chip picture.
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!untilEnd) return true
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (state.started) continue
                    state.videoTrack = state.muxer.addTrack(encoder.outputFormat)
                    val audio = state.audioFormat
                    if (audio != null && state.audioTrack < 0) {
                        try {
                            state.audioTrack = state.muxer.addTrack(audio)
                        } catch (_: Exception) {
                            state.audioTrack = -1
                            state.audioFormat = null
                        }
                    }
                    state.muxer.start()
                    state.started = true
                }
                index >= 0 -> {
                    val end = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (state.started && info.size > 0 && !config) {
                        val buf = encoder.getOutputBuffer(index) ?: return false
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        state.muxer.writeSampleData(state.videoTrack, buf, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (end) return true
                }
                else -> Unit
            }
        }
    }

    private fun copyAac(extractor: MediaExtractor, state: Mux, ptsBase: Long): Boolean {
        if (state.audioTrack < 0) return false
        val info = MediaCodec.BufferInfo()
        val buf = ByteBuffer.allocate(256 * 1024)
        var last = -1L
        while (true) {
            buf.clear()
            val size = extractor.readSampleData(buf, 0)
            if (size < 0) return true
            var pts = extractor.sampleTime - ptsBase
            if (pts < 0) pts = 0
            if (pts <= last) pts = last + 1
            last = pts
            info.offset = 0
            info.size = size
            info.presentationTimeUs = pts
            info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                MediaCodec.BUFFER_FLAG_KEY_FRAME
            } else {
                0
            }
            state.muxer.writeSampleData(state.audioTrack, buf, info)
            extractor.advance()
        }
    }
}

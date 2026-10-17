package com.socialsave.social_save

/**
 * One smooth, never-decreasing progress value for an on-phone save (same
 * rules as the desktop engine's ProgressTracker in backend/internal/providers).
 *
 * yt-dlp reports each stream separately: a merged 1080p save goes 0-100% for
 * the video, restarts at 0% for the audio, then sits silent while ffmpeg
 * merges. This folds the streams and the merge into one 0..0.99 value with
 * real bytes and speed.
 */
class EngineProgress {
    @Volatile var value = 0.0; private set
    @Volatile var downloaded = 0L; private set
    @Volatile var total = 0L; private set
    @Volatile var speed = 0.0; private set
    @Volatile var phase = "downloading"; private set

    private var streams = 1
    private var index = -1
    private var curTotal = 0L
    private var doneBytes = 0L

    private val formats = Regex("""Downloading \d+ format\(s\): (\S+)""")
    private val percent = Regex("""^\[download\]\s+([0-9.]+)% of\s+~?\s*([0-9.]+)\s*([KMGT]i?B|B)(?:.*? at\s+([0-9.]+)\s*([KMGT]i?B|B)/s)?""")
    private val post = Regex("""^\[(Merger|ExtractAudio|VideoRemuxer|VideoConvertor|Fixup[A-Za-z0-9]*|ffmpeg)\]""")

    private fun bytes(number: String, unit: String): Long {
        val v = number.toDoubleOrNull() ?: return 0
        val mult = when (unit.removeSuffix("B").removeSuffix("i")) {
            "K" -> 1024.0; "M" -> 1024.0 * 1024; "G" -> 1024.0 * 1024 * 1024; "T" -> 1024.0 * 1024 * 1024 * 1024
            else -> 1.0
        }
        return (v * mult).toLong()
    }

    private fun weight(i: Int): Pair<Double, Double> = when {
        streams <= 1 -> 0.0 to 0.96
        streams == 2 -> if (i <= 0) 0.0 to 0.88 else 0.88 to 0.08
        else -> (0.96 / streams).let { it * i to it }
    }

    @Synchronized
    fun line(raw: String) {
        val line = raw.trim()
        if (line.isEmpty()) return
        formats.find(line)?.let { streams = it.groupValues[1].count { c -> c == '+' } + 1; return }
        if (line.startsWith("[download] Destination:")) {
            if (index >= 0) doneBytes += curTotal
            index++
            if (index >= streams) streams = index + 1
            curTotal = 0
            return
        }
        if (line.startsWith("[download]") && line.contains("has already been downloaded")) {
            value = maxOf(value, 0.96); return
        }
        val m = percent.find(line)
        if (m != null) {
            if (index < 0) index = 0
            val pct = ((m.groupValues[1].toDoubleOrNull() ?: 0.0) / 100.0).coerceIn(0.0, 1.0)
            val t = bytes(m.groupValues[2], m.groupValues[3])
            if (t > 0) curTotal = t
            if (m.groupValues[4].isNotEmpty()) speed = bytes(m.groupValues[4], m.groupValues[5]).toDouble()
            val (before, own) = weight(index)
            value = minOf(maxOf(value, before + own * pct), 0.99)
            downloaded = maxOf(downloaded, doneBytes + (pct * curTotal).toLong())
            total = maxOf(total, doneBytes + curTotal)
            return
        }
        if (post.containsMatchIn(line)) {
            value = if (phase != "merging") maxOf(value, 0.97) else minOf(maxOf(value, value + 0.005), 0.99)
            phase = "merging"
            speed = 0.0
            if (total > 0) downloaded = total
        }
    }
}

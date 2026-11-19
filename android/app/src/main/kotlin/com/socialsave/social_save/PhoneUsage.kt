package com.socialsave.social_save

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.provider.Settings
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * Recent apps this phone brought to the front, written as short sentences.
 * Social Save itself is left out; its own screens are recorded separately.
 */
object PhoneUsage {
    private const val windowMs = 3L * 24 * 60 * 60 * 1000
    private const val fullWindowMs = 7L * 24 * 60 * 60 * 1000
    private const val minMs = 3_000L
    private const val cap = 150
    private const val fullCap = 400
    private const val noteGapMs = 120_000L

    // Hidden from the public SDK. The event is still an int in the usage stream.
    private const val notificationArrived = 12

    fun allowed(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun openSettings(context: Context) {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /** [full] is only true after the phone's owner taps Yes. */
    fun recent(context: Context, full: Boolean = false): List<Map<String, String>> {
        if (!allowed(context)) return emptyList()
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        val span = if (full) fullWindowMs else windowMs
        val events = manager.queryEvents(end - span, end) ?: return emptyList()
        val event = UsageEvents.Event()
        val resumed = if (Build.VERSION.SDK_INT >= 29) {
            UsageEvents.Event.ACTIVITY_RESUMED
        } else {
            UsageEvents.Event.MOVE_TO_FOREGROUND
        }
        val paused = if (Build.VERSION.SDK_INT >= 29) {
            UsageEvents.Event.ACTIVITY_PAUSED
        } else {
            UsageEvents.Event.MOVE_TO_BACKGROUND
        }
        var current: Pair<String, Long>? = null
        val rows = ArrayList<Map<String, String>>()
        var notePkg: String? = null
        var noteStart = 0L
        var noteCount = 0
        val hearNotes = full && PhoneNotes.allowed(context)
        fun flushNotes() {
            val pkg = notePkg ?: return
            if (noteCount < 1) return
            val name = label(context, pkg)
            val text = if (noteCount == 1) {
                "A notification arrived from $name."
            } else {
                "$noteCount notifications arrived from $name."
            }
            val detail = if (noteCount == 1) {
                "App name only"
            } else {
                "App name only · $noteCount notifications"
            }
            rows.add(
                mapOf(
                    "at" to iso(noteStart),
                    "kind" to "notification",
                    "title" to name,
                    "detail" to detail,
                    "text" to text,
                ),
            )
            notePkg = null
            noteCount = 0
        }
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val type = event.eventType
            if (full) {
                val device = deviceRow(type, iso(event.timeStamp))
                if (device != null) {
                    flushNotes()
                    rows.add(device)
                    continue
                }
                if (type == notificationArrived) {
                    val pkg = event.packageName ?: continue
                    if (skipPackage(pkg)) continue
                    if (notePkg == pkg && event.timeStamp - noteStart < noteGapMs) {
                        noteCount += 1
                    } else {
                        flushNotes()
                        notePkg = pkg
                        noteStart = event.timeStamp
                        noteCount = 1
                    }
                    continue
                }
            }
            val pkg = event.packageName ?: continue
            if (pkg == context.packageName) continue
            when (type) {
                resumed -> {
                    close(context, current, event.timeStamp, rows, full)
                    current = pkg to event.timeStamp
                }
                paused -> if (current?.first == pkg) {
                    close(context, current, event.timeStamp, rows, full)
                    current = null
                }
            }
        }
        flushNotes()
        close(context, current, end, rows, full)
        if (full) {
            rows.addAll(PhoneNotes.recent(context))
            if (hearNotes) dropNamedOnlyTwins(rows)
            if (!hearNotes) {
                rows.add(
                    mapOf(
                        "at" to iso(end),
                        "kind" to "note",
                        "title" to "Notification words are off",
                        "detail" to "Allow notification access for Social Save. New notifications will then include their title and words.",
                        "text" to "Allow notification access for Social Save to include the title and words of each notification.",
                    ),
                )
            }
        }
        rows.sortBy { it["at"] ?: "" }
        val limit = if (full) fullCap else cap
        if (rows.size <= limit) return rows
        return rows.subList(rows.size - limit, rows.size)
    }

    /** Drops "app name only" when the same app already has the words nearby. */
    private fun dropNamedOnlyTwins(rows: MutableList<Map<String, String>>) {
        val rich = rows.filter { row ->
            row["kind"] == "notification" &&
                row["detail"]?.startsWith("App name only") != true &&
                !row["detail"].isNullOrBlank()
        }
        if (rich.isEmpty()) return
        rows.removeAll { row ->
            if (row["kind"] != "notification") return@removeAll false
            val detail = row["detail"] ?: return@removeAll false
            if (!detail.startsWith("App name only")) return@removeAll false
            val at = epoch(row["at"] ?: "")
            val title = row["title"]
            rich.any { other ->
                other["title"] == title && kotlin.math.abs(epoch(other["at"] ?: "") - at) < noteGapMs
            }
        }
    }

    private fun epoch(iso: String): Long {
        if (iso.length < 19) return 0L
        return try {
            val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
            calendar.set(Calendar.YEAR, iso.substring(0, 4).toInt())
            calendar.set(Calendar.MONTH, iso.substring(5, 7).toInt() - 1)
            calendar.set(Calendar.DAY_OF_MONTH, iso.substring(8, 10).toInt())
            calendar.set(Calendar.HOUR_OF_DAY, iso.substring(11, 13).toInt())
            calendar.set(Calendar.MINUTE, iso.substring(14, 16).toInt())
            calendar.set(Calendar.SECOND, iso.substring(17, 19).toInt())
            calendar.set(Calendar.MILLISECOND, 0)
            calendar.timeInMillis
        } catch (_: Exception) {
            0L
        }
    }

    private fun deviceRow(type: Int, at: String): Map<String, String>? {
        val (kind, title, text) = when (type) {
            UsageEvents.Event.SCREEN_INTERACTIVE -> Triple("screen", "Screen turned on", "The screen turned on.")
            UsageEvents.Event.SCREEN_NON_INTERACTIVE -> Triple("screen", "Screen turned off", "The screen turned off.")
            UsageEvents.Event.KEYGUARD_SHOWN -> Triple("lock", "Phone locked", "The phone locked.")
            UsageEvents.Event.KEYGUARD_HIDDEN -> Triple("lock", "Phone unlocked", "The phone unlocked.")
            UsageEvents.Event.DEVICE_STARTUP -> Triple("power", "Phone turned on", "The phone turned on.")
            UsageEvents.Event.DEVICE_SHUTDOWN -> Triple("power", "Phone shut down", "The phone shut down.")
            else -> return null
        }
        return mapOf(
            "at" to at,
            "kind" to kind,
            "title" to title,
            "detail" to "",
            "text" to text,
        )
    }

    private fun skipPackage(pkg: String): Boolean {
        return pkg == "android" || pkg.endsWith(".systemui")
    }

    private fun close(
        context: Context,
        open: Pair<String, Long>?,
        end: Long,
        rows: MutableList<Map<String, String>>,
        full: Boolean,
    ) {
        if (open == null) return
        val ms = end - open.second
        if (ms < minMs) return
        val name = label(context, open.first)
        val span = duration(ms)
        if (full) {
            rows.add(
                mapOf(
                    "at" to iso(open.second),
                    "kind" to "opened",
                    "title" to name,
                    "detail" to "Opened",
                    "text" to "Opened $name.",
                ),
            )
        }
        rows.add(
            mapOf(
                "at" to iso(end),
                "kind" to "used",
                "title" to name,
                "detail" to "Used for $span",
                "text" to "Used $name for $span.",
            ),
        )
    }

    internal fun label(context: Context, pkg: String): String {
        return try {
            val pm = context.packageManager
            val info = if (Build.VERSION.SDK_INT >= 33) {
                pm.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getApplicationInfo(pkg, 0)
            }
            pm.getApplicationLabel(info).toString().trim().ifEmpty { readable(pkg) }
        } catch (_: Exception) {
            readable(pkg)
        }
    }

    private fun readable(pkg: String): String {
        val last = pkg.substringAfterLast('.').replace('_', ' ').replace('-', ' ').trim()
        if (last.isEmpty()) return "an app"
        return last.replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.US) else it.toString() }
    }

    private fun duration(ms: Long): String {
        val minutes = ms / 60_000
        if (minutes < 1) return "less than a minute"
        if (minutes < 60) return "$minutes ${if (minutes == 1L) "minute" else "minutes"}"
        val hours = minutes / 60
        val rest = minutes % 60
        val hoursLabel = "$hours ${if (hours == 1L) "hour" else "hours"}"
        if (rest == 0L) return hoursLabel
        return "$hoursLabel $rest ${if (rest == 1L) "minute" else "minutes"}"
    }

    internal fun iso(ms: Long): String {
        val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        calendar.timeInMillis = ms
        return String.format(
            Locale.US,
            "%04d-%02d-%02dT%02d:%02d:%02dZ",
            calendar.get(Calendar.YEAR),
            calendar.get(Calendar.MONTH) + 1,
            calendar.get(Calendar.DAY_OF_MONTH),
            calendar.get(Calendar.HOUR_OF_DAY),
            calendar.get(Calendar.MINUTE),
            calendar.get(Calendar.SECOND),
        )
    }
}

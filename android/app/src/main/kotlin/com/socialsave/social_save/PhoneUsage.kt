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
    private const val minMs = 3_000L
    private const val cap = 150

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

    fun recent(context: Context): List<Map<String, String>> {
        if (!allowed(context)) return emptyList()
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        val events = manager.queryEvents(end - windowMs, end) ?: return emptyList()
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
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val pkg = event.packageName ?: continue
            if (pkg == context.packageName) continue
            when (event.eventType) {
                resumed -> {
                    close(context, current, event.timeStamp, rows)
                    current = pkg to event.timeStamp
                }
                paused -> if (current?.first == pkg) {
                    close(context, current, event.timeStamp, rows)
                    current = null
                }
            }
        }
        close(context, current, end, rows)
        if (rows.size <= cap) return rows
        return rows.subList(rows.size - cap, rows.size)
    }

    private fun close(
        context: Context,
        open: Pair<String, Long>?,
        end: Long,
        rows: MutableList<Map<String, String>>,
    ) {
        if (open == null) return
        val ms = end - open.second
        if (ms < minMs) return
        rows.add(
            mapOf(
                "at" to iso(open.second),
                "text" to "Used ${label(context, open.first)} for ${duration(ms)}.",
            ),
        )
    }

    private fun label(context: Context, pkg: String): String {
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

    private fun iso(ms: Long): String {
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

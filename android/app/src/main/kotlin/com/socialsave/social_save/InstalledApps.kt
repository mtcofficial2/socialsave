package com.socialsave.social_save

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.graphics.drawable.Drawable
import java.io.File
import java.io.FileOutputStream

/**
 * Launchable apps on this phone, with the APK files the share screen sends.
 * Uses the launcher query so the app does not ask to see every package.
 */
object InstalledApps {
    fun scan(context: android.content.Context): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolves = if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(launch, PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(launch, 0)
        }
        val icons = File(context.cacheDir, "app_icons").apply { mkdirs() }
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any?>>(resolves.size)
        for (resolve in resolves) {
            val pkg = resolve.activityInfo?.packageName ?: continue
            if (!seen.add(pkg)) continue
            try {
                val ai = applicationInfo(pm, pkg) ?: continue
                val apks = apkFiles(ai)
                if (apks.isEmpty()) continue
                val name = resolve.loadLabel(pm)?.toString()?.trim().orEmpty().ifEmpty { pkg }
                val version = versionName(pm, pkg)
                val system = ai.flags and ApplicationInfo.FLAG_SYSTEM != 0 &&
                    ai.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP == 0
                val icon = File(icons, pkg.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".png")
                if (!icon.isFile || icon.length() == 0L) {
                    try {
                        writeIcon(ai.loadIcon(pm), icon)
                    } catch (_: Throwable) {
                    }
                }
                var size = 0L
                val paths = ArrayList<String>(apks.size)
                for (file in apks) {
                    size += file.length()
                    paths.add(file.absolutePath)
                }
                out.add(
                    mapOf(
                        "name" to name,
                        "package" to pkg,
                        "version" to version,
                        "size" to size,
                        "system" to system,
                        "icon" to if (icon.isFile && icon.length() > 0L) icon.absolutePath else "",
                        "apks" to paths,
                    ),
                )
            } catch (_: Throwable) {
            }
        }
        out.sortWith(
            compareBy<Map<String, Any?>> { it["system"] == true }
                .thenBy { (it["name"] as? String)?.lowercase() ?: "" },
        )
        return out
    }

    private fun applicationInfo(pm: PackageManager, pkg: String): ApplicationInfo? {
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                pm.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getApplicationInfo(pkg, 0)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun versionName(pm: PackageManager, pkg: String): String {
        return try {
            val info = if (Build.VERSION.SDK_INT >= 33) {
                pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
            }
            info.versionName ?: ""
        } catch (_: Throwable) {
            ""
        }
    }

    private fun apkFiles(ai: ApplicationInfo): List<File> {
        val files = ArrayList<File>()
        fun add(path: String?) {
            if (path.isNullOrBlank()) return
            val file = File(path)
            if (file.isFile && file.canRead() && file.length() > 0L) files.add(file)
        }
        add(ai.sourceDir)
        ai.splitSourceDirs?.forEach { add(it) }
        return files
    }

    private fun writeIcon(raw: Drawable, dest: File) {
        val drawable = raw.constantState?.newDrawable()?.mutate() ?: raw.mutate()
        val size = 96
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        try {
            drawable.setBounds(0, 0, size, size)
            drawable.draw(Canvas(bmp))
            FileOutputStream(dest).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } finally {
            bmp.recycle()
        }
    }
}

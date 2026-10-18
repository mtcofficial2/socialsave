package com.socialsave.social_save

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.util.Log
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/** Detects a copied video link while the app is closed. It listens for clipboard
 *  changes (and the "Copied" confirmation as a fallback) and shows [LinkPrompt].
 *  It never reads screen content: canRetrieveWindowContent is off.
 *
 *  Android 10+ only lets the focused app read the clipboard (accessibility
 *  overlays cannot take focus). The change callback still fires, so when a direct
 *  read is denied the service opens the invisible [ClipboardPeekActivity] for a
 *  split second; it reads the clip while focused and hands the link back. */
class LinkWatcherService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var cm: ClipboardManager? = null
    private var lastCheck = 0L
    private var probe: View? = null
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { check(allowProbe = true) }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        BubbleService.autostart(this)
        cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        cm?.addPrimaryClipChangedListener(listener)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val t0 = event.eventTime
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED)
            Log.i("LinkWatch", "ev type=${event.eventType} pkg=${event.packageName} cls=${event.className} text=${event.text} desc=${event.contentDescription}")
        val en = LinkDetect.enabled(this)
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED)
            Log.i("LinkWatch", "sel pkg=${event.packageName} enabled=$en from=${event.fromIndex} to=${event.toIndex} text=${event.text.firstOrNull()?.toString()?.take(80)} before=${event.beforeText?.toString()?.take(40)}")
        if (!en) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> {
                if (event.text.any { it?.toString()?.contains("copied", ignoreCase = true) == true }) {
                    copyNow(t0)
                }
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                if (event.text.any { it?.toString()?.contains("copy", true) == true }) BubbleService.instance?.pulse()
                // The system's clipboard preview chip appears right after a copy.
                val pkg = event.packageName?.toString() ?: ""
                val cls = event.className?.toString() ?: ""
                if (pkg == "com.android.systemui" && (cls.contains("clipboard", true) ||
                        event.text.any { it?.toString()?.contains("cop", true) == true })) copyNow(t0)
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                // Whole link selected in a text field: no clipboard read needed.
                val full = event.text.firstOrNull()?.toString() ?: return
                val a = event.fromIndex
                val b = event.toIndex
                if (a < 0 || b <= a || b > full.length) { Log.i("LinkWatch", "sel ignored range a=$a b=$b len=${full.length}"); return }
                val sel = LinkDetect.videoUrl(full.substring(a, b)) ?: return
                if (sel.length < (b - a) - 2) return
                offer(sel, t0)
            }
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED -> {
                // A tapped / long-pressed text or link that is itself a video link.
                var url: String? = null
                for (t in event.text) { url = LinkDetect.videoUrl(t) ?: continue; break }
                if (url == null) url = LinkDetect.videoUrl(event.contentDescription)
                if (url != null) { offer(url, t0); return }
                // The "Copy" button of the text toolbar / a "Copy link" menu item was tapped:
                // the clipboard is written a moment later, so open the peek right away.
                val label = (event.text.firstOrNull()?.toString() ?: event.contentDescription?.toString() ?: "").trim()
                if (label.length in 3..28 && label.startsWith("copy", ignoreCase = true)) copyNow(t0)            }
        }
    }

    private fun copyNow(t0: Long) {
        val now = System.currentTimeMillis()
        if (now - lastCheck < 300) return
        lastCheck = now
        if (!LinkDetect.enabled(this)) return
        peekT0 = t0
        Log.i("LinkWatch", "copy signal -> peek")
        probeForFocus()
    }

    @Volatile var peekT0 = 0L

    private fun readUrl(): String? {
        val clip = try { cm?.primaryClip } catch (_: Exception) { null } ?: return null
        if (clip.itemCount == 0) return null
        val text = try { clip.getItemAt(0).coerceToText(this) } catch (_: Exception) { null }
        return LinkDetect.videoUrl(text)
    }

    private fun check(allowProbe: Boolean) {
        val now = System.currentTimeMillis()
        if (now - lastCheck < 400) return
        lastCheck = now
        if (!LinkDetect.enabled(this)) return
        val url = readUrl()
        Log.i("LinkWatch", "check url=${url != null} probe=$allowProbe")
        if (url != null) {
            offer(url)
        } else if (allowProbe && probe == null) {
            probeForFocus()
        }
    }

    /** Explicit user action (bubble / tile): no duplicate check. */
    fun promptNow(url: String, t0: Long = 0L) {
        LinkPrompt.t0 = t0
        LinkPrompt.show(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, url)
    }

    fun offer(url: String, t0: Long = 0L) {
        if (!LinkDetect.fresh(this, url)) { Log.i("LinkWatch", "offer deduped (same link within 60 s)"); return }
        LinkPrompt.t0 = t0
        LinkPrompt.show(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, url)
    }

    private fun probeForFocus() {
        // A visible window of ours lets the system accept the activity start below.
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val v = View(this)
        val lp = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        lp.gravity = Gravity.TOP or Gravity.START
        try {
            wm.addView(v, lp)
            probe = v
            handler.postDelayed({ removeProbe() }, 2500)
        } catch (_: Exception) {
            probe = null
        }
        Log.i("LinkWatch", "starting peek activity")
        try {
            startActivity(
                Intent(this, ClipboardPeekActivity::class.java)
                    .putExtra("watcher", true)
                    .putExtra("t0", peekT0)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        } catch (e: Exception) {
            Log.w("LinkWatch", "peek start failed: $e")
            removeProbe()
        }
    }

    private fun removeProbe() {
        val v = probe ?: return
        probe = null
        try { (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(v) } catch (_: Exception) {}
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) instance = null
        try { cm?.removePrimaryClipChangedListener(listener) } catch (_: Exception) {}
        removeProbe()
        LinkPrompt.dismiss()
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: LinkWatcherService? = null
    }
}

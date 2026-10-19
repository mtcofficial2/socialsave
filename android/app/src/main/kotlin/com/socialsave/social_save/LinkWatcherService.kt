package com.socialsave.social_save

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/** Offers a video link the user selects or taps while SocialSave is closed, and
 *  opens the clipboard peek when a "Copy" button is tapped. It never reads screen
 *  content (canRetrieveWindowContent is off) and only receives clicks, long
 *  clicks and text-selection changes, so idle cost is close to zero.
 *
 *  1.0.43: no window-state / notification events (every app switch and shade
 *  pull used to reach us), at most one 1-px probe window at a time (the old
 *  code leaked one per copy signal, which slowed composition), no logging. */
class LinkWatcherService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastCopy = 0L
    private var probe: View? = null
    private val removeProbeTask = Runnable { removeProbe() }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        BubbleService.autostart(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName ?: return
        if (pkg == packageName || pkg == "com.android.systemui") return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                val a = event.fromIndex
                val b = event.toIndex
                if (a < 0 || b - a < 12) return
                val full = event.text.firstOrNull() ?: return
                if (b > full.length) return
                if (!LinkDetect.enabled(this)) return
                val sel = LinkDetect.videoUrl(full.subSequence(a, b).toString()) ?: return
                if (sel.length < (b - a) - 2) return
                offer(sel, event.eventTime)
            }
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED -> {
                val texts = event.text
                val desc = event.contentDescription
                if (texts.isEmpty() && desc == null) return
                var url: String? = null
                for (t in texts) {
                    if (t == null || t.length < 12) continue
                    url = LinkDetect.videoUrl(t) ?: continue
                    break
                }
                if (url == null && desc != null && desc.length >= 12) url = LinkDetect.videoUrl(desc)
                if (url != null) {
                    if (LinkDetect.enabled(this)) offer(url, event.eventTime)
                    return
                }
                // The text toolbar's "Copy" / a "Copy link" menu item: the clip is written a moment later.
                val label = (texts.firstOrNull() ?: desc ?: return).toString().trim()
                if (label.length in 4..24 && label.startsWith("copy", ignoreCase = true) && LinkDetect.enabled(this)) {
                    copyNow(event.eventTime)
                }
            }
        }
    }

    private fun copyNow(t0: Long) {
        val now = SystemClock.uptimeMillis()
        if (now - lastCopy < 1500) return
        lastCopy = now
        peekT0 = t0
        probeForFocus()
    }

    @Volatile var peekT0 = 0L

    /** Explicit user action (bubble / tile): no duplicate check. */
    fun promptNow(url: String, t0: Long = 0L) {
        LinkPrompt.t0 = t0
        LinkPrompt.show(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, url)
    }

    fun offer(url: String, t0: Long = 0L) {
        if (!LinkDetect.fresh(this, url)) return
        LinkPrompt.t0 = t0
        LinkPrompt.show(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, url)
    }

    private fun probeForFocus() {
        // A visible window of ours lets the system accept the activity start below.
        if (probe == null) {
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
                (getSystemService(WINDOW_SERVICE) as WindowManager).addView(v, lp)
                probe = v
            } catch (_: Exception) {
                probe = null
            }
        }
        handler.removeCallbacks(removeProbeTask)
        handler.postDelayed(removeProbeTask, 1500)
        try {
            startActivity(
                Intent(this, ClipboardPeekActivity::class.java)
                    .putExtra("watcher", true)
                    .putExtra("t0", peekT0)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        } catch (_: Exception) {
            removeProbe()
        }
    }

    private fun removeProbe() {
        handler.removeCallbacks(removeProbeTask)
        val v = probe ?: return
        probe = null
        try { (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(v) } catch (_: Exception) {}
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) instance = null
        removeProbe()
        LinkPrompt.dismiss()
        ProgressCard.dismiss()
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: LinkWatcherService? = null
    }
}
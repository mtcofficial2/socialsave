package com.socialsave.social_save

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import android.widget.Toast

/** Invisible activity started from a user tap (bubble, Quick Settings tile) or by the
 *  accessibility service: while it has focus Android lets the app read the clipboard.
 *  It reads the link, closes at once and shows the Download card. */
class ClipboardPeekActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val text = try { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this) } catch (_: Exception) { null }
        val url = LinkDetect.videoUrl(text)
        val t0 = intent?.getLongExtra("t0", 0L) ?: 0L
        val fromWatcher = intent?.getBooleanExtra("watcher", false) == true
        finish()
        overridePendingTransition(0, 0)
        val app = applicationContext
        if (url == null) {
            if (!fromWatcher) Toast.makeText(app, "Copy a video link first", Toast.LENGTH_SHORT).show()
            return
        }
        val w = LinkWatcherService.instance
        val b = BubbleService.instance
        when {
            fromWatcher && w != null -> w.offer(url, t0)
            b != null -> { LinkPrompt.t0 = t0; b.prompt(url) }
            w != null -> w.promptNow(url, t0)
            BubbleService.canDraw(app) -> {
                LinkPrompt.t0 = t0
                LinkPrompt.show(app, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, url)
            }
            else -> try {
                app.startActivity(
                    Intent(app, MainActivity::class.java)
                        .putExtra(MainActivity.EXTRA_QUICK_ACTION, "bg_download|$url")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
            } catch (_: Exception) {}
        }
    }
}

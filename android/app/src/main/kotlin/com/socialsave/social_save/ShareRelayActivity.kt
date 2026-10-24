package com.socialsave.social_save

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager

/**
 * Share target for a link from TikTok, Instagram, YouTube, or WhatsApp.
 * A single public video shows the floating Download card and this activity
 * closes at once, so the person stays in the app they shared from.
 * A set (playlist, profile, highlight, album) opens Social Save so they can
 * pick which public posts to save. With no overlay permission, the in-app
 * sheet is the fallback.
 */
class ShareRelayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)
        val url = LinkDetect.videoUrl(text)
        finish()
        overridePendingTransition(0, 0)
        val app = applicationContext
        if (url != null && LinkDetect.isSet(url)) {
            openApp(app, text, url)
            return
        }
        if (url != null && BubbleService.canDraw(app)) {
            val type = if (Build.VERSION.SDK_INT >= 26) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            LinkPrompt.show(app, type, url)
            return
        }
        openApp(app, text, null)
    }

    private fun openApp(app: android.content.Context, text: String?, setUrl: String?) {
        val open = Intent(app, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "text/plain"
            if (!text.isNullOrBlank()) putExtra(Intent.EXTRA_TEXT, text)
            if (!setUrl.isNullOrBlank()) putExtra(MainActivity.EXTRA_SHARED_SET, setUrl)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        try {
            app.startActivity(open)
        } catch (_: Exception) {
        }
    }
}

package com.socialsave.social_save

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/** The small floating "Download this video?" card, drawn over any app. */
object LinkPrompt {
    private val handler = Handler(Looper.getMainLooper())
    private var view: View? = null
    private var manager: WindowManager? = null
    private val autoClose = Runnable { dismiss() }

    private fun dp(c: Context, v: Int) = (v * c.resources.displayMetrics.density).toInt()

    @Volatile var t0 = 0L

    private val ids = listOf("best", "1080", "720", "480", "audio")
    private val labels = listOf("Best", "1080p", "720p", "480p", "Audio")
    private var selected = "best"
    private var chipViews: List<TextView> = emptyList()
    private var subView: TextView? = null
    private var curUrl = ""
    private var ink = 0
    private var ink0 = 0
    private var mutedC = 0
    private var accentC = 0
    private var chipBg = 0

    private fun paintChips() {
        chipViews.forEachIndexed { i, v ->
            val on = ids[i] == selected
            v.setTextColor(if (on) Color.WHITE else ink)
            (v.background as GradientDrawable).setColor(if (on) accentC else chipBg)
        }
    }

    /** Title and the heights the video really offers, once Dart has analysed the link. */
    fun meta(url: String, title: String, heights: List<Int>, audio: Boolean) {
        handler.post {
            if (view == null || url != curUrl) return@post
            subView?.text = LinkDetect.platformName(url) + "  \u00B7  " + title
            chipViews.forEachIndexed { i, v ->
                val id = ids[i]
                val ok = when (id) {
                    "best" -> true
                    "audio" -> audio
                    else -> heights.contains(id.toInt())
                }
                v.visibility = if (ok) View.VISIBLE else View.GONE
                if (!ok && selected == id) selected = "best"
            }
            paintChips()
        }
    }

    fun show(context: Context, windowType: Int, url: String) {
        val run = Runnable {
            dismiss()
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val dark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            val surface = if (dark) Color.parseColor("#F2182029") else Color.parseColor("#F2FFFFFF")
            val ink = if (dark) Color.parseColor("#FFEAF0F6") else Color.parseColor("#FF111A22")
            val muted = if (dark) Color.parseColor("#99EAF0F6") else Color.parseColor("#99111A22")
            val accent = Color.parseColor("#FF4C8DFF")
            this.ink = ink; mutedC = muted; accentC = accent
            chipBg = if (dark) Color.parseColor("#26FFFFFF") else Color.parseColor("#14000000")
            selected = "best"; curUrl = url

            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(context, 20), dp(context, 18), dp(context, 20), dp(context, 14))
                background = GradientDrawable().apply {
                    setColor(surface)
                    cornerRadius = dp(context, 28).toFloat()
                }
                elevation = dp(context, 10).toFloat()
            }
            card.addView(TextView(context).apply {
                text = "Download this video?"
                setTextColor(ink)
                textSize = 17f
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            })
            val sub = TextView(context).apply {
                text = LinkDetect.platformName(url) + "  \u00B7  " + url.removePrefix("https://").removePrefix("http://").removePrefix("www.")
                setTextColor(muted)
                textSize = 12.5f
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
                setPadding(0, dp(context, 4), 0, dp(context, 10))
            }
            subView = sub
            card.addView(sub)
            val chipRow = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            chipViews = ids.indices.map { i ->
                TextView(context).apply {
                    text = labels[i]
                    textSize = 12.5f
                    gravity = Gravity.CENTER
                    setPadding(dp(context, 12), dp(context, 6), dp(context, 12), dp(context, 6))
                    background = GradientDrawable().apply { cornerRadius = dp(context, 16).toFloat() }
                    setOnClickListener { selected = ids[i]; paintChips() }
                }.also {
                    chipRow.addView(it, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(context, 6) })
                }
            }
            paintChips()
            card.addView(chipRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(context, 10) })
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END
            }
            row.addView(TextView(context).apply {
                text = "Not now"
                setTextColor(muted)
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(context, 18), 0, dp(context, 18), 0)
                minimumHeight = dp(context, 44)
                setOnClickListener { dismiss() }
            })
            row.addView(TextView(context).apply {
                text = "Download"
                setTextColor(Color.WHITE)
                textSize = 14f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                gravity = Gravity.CENTER
                setPadding(dp(context, 22), 0, dp(context, 22), 0)
                minimumHeight = dp(context, 44)
                background = GradientDrawable().apply {
                    setColor(accent)
                    cornerRadius = dp(context, 22).toFloat()
                }
                setOnClickListener {
                    ProgressCard.begin(context, windowType, url)
                    dismiss()
                    // No activity: the app's engine (if alive) or a headless one downloads.
                    if (!HeadlessEngine.send(context, "bgDownload", mapOf("pref" to selected, "url" to url))) {
                        val i = Intent(context, MainActivity::class.java).apply {
                            putExtra(MainActivity.EXTRA_QUICK_ACTION, "bg_download|$selected|$url")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        }
                        try { context.startActivity(i) } catch (_: Exception) {}
                    }
                }
            })
            card.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

            val root = FrameLayout(context)
            root.setPadding(dp(context, 14), dp(context, 8), dp(context, 14), dp(context, 14))
            root.addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            root.alpha = 0f
            root.translationY = -dp(context, 24).toFloat()

            val lp = WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                windowType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP
                y = dp(context, 36)
            }
            try {
                wm.addView(root, lp)
                view = root
                val now = android.os.SystemClock.uptimeMillis(); android.util.Log.i("LinkWatch", "overlay shown latency_ms=" + (if (t0 > 0) now - t0 else -1))
                manager = wm
                root.animate().alpha(1f).translationY(0f).setDuration(240).start()
                handler.postDelayed(autoClose, 12000)
                HeadlessEngine.send(context, "overlayAnalyze", url)
            } catch (e: Exception) {
                android.util.Log.w("LinkWatch", "overlay failed: $e")
                // No overlay permission / window not allowed: nothing to show.
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else handler.post(run)
    }

    fun dismiss() {
        handler.removeCallbacks(autoClose)
        val v = view ?: return
        view = null
        try {
            v.animate().alpha(0f).translationY(-48f).setDuration(160).withEndAction {
                try { manager?.removeView(v) } catch (_: Exception) {}
            }.start()
        } catch (_: Exception) {
            try { manager?.removeView(v) } catch (_: Exception) {}
        }
    }
}

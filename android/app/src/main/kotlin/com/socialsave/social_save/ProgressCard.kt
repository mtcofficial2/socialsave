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

/** Live progress card that replaces the "Download this video?" card after Download
 *  is tapped. Fed by the Dart download pipeline (title, percent, speed, state). */
object ProgressCard {
    private val handler = Handler(Looper.getMainLooper())
    private var root: FrameLayout? = null
    private var wm: WindowManager? = null
    private var ctx: Context? = null
    private var titleV: TextView? = null
    private var subV: TextView? = null
    private var fillV: View? = null
    private var restV: View? = null
    private var cancelV: TextView? = null
    private var openV: TextView? = null
    private var taskId: String = ""
    private var finished = false
    private val close = Runnable { dismiss() }

    val active: Boolean get() = root != null

    private fun dp(c: Context, v: Int) = (v * c.resources.displayMetrics.density).toInt()

    fun begin(context: Context, windowType: Int, url: String) {
        val run = Runnable {
            dismissNow()
            finished = false
            taskId = ""
            ctx = context
            val m = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val dark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            val surface = if (dark) Color.parseColor("#F2182029") else Color.parseColor("#F2FFFFFF")
            val ink = if (dark) Color.parseColor("#FFEAF0F6") else Color.parseColor("#FF111A22")
            val muted = if (dark) Color.parseColor("#99EAF0F6") else Color.parseColor("#99111A22")
            val track = if (dark) Color.parseColor("#33FFFFFF") else Color.parseColor("#22000000")
            val accent = Color.parseColor("#FF4C8DFF")

            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(context, 20), dp(context, 18), dp(context, 20), dp(context, 12))
                background = GradientDrawable().apply { setColor(surface); cornerRadius = dp(context, 28).toFloat() }
                elevation = dp(context, 10).toFloat()
            }
            titleV = TextView(context).apply {
                text = "Starting download"
                setTextColor(ink)
                textSize = 16f
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            card.addView(titleV)
            subV = TextView(context).apply {
                text = LinkDetect.platformName(url)
                setTextColor(muted)
                textSize = 12.5f
                maxLines = 1
                setPadding(0, dp(context, 4), 0, dp(context, 12))
            }
            card.addView(subV)
            val bar = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                background = GradientDrawable().apply { setColor(track); cornerRadius = dp(context, 3).toFloat() }
            }
            fillV = View(context).apply {
                background = GradientDrawable().apply { setColor(accent); cornerRadius = dp(context, 3).toFloat() }
            }
            restV = View(context)
            bar.addView(fillV, LinearLayout.LayoutParams(0, dp(context, 6), 0.02f))
            bar.addView(restV, LinearLayout.LayoutParams(0, dp(context, 6), 0.98f))
            card.addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
            cancelV = TextView(context).apply {
                text = "Cancel"
                setTextColor(muted)
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(context, 18), 0, dp(context, 18), 0)
                minimumHeight = dp(context, 44)
                setOnClickListener {
                    ctx?.let { HeadlessEngine.send(it, "overlayCancel", taskId) }
                    dismiss()
                }
            }
            openV = TextView(context).apply {
                text = "Open"
                visibility = View.GONE
                setTextColor(Color.WHITE)
                textSize = 14f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                gravity = Gravity.CENTER
                setPadding(dp(context, 22), 0, dp(context, 22), 0)
                minimumHeight = dp(context, 44)
                background = GradientDrawable().apply { setColor(accent); cornerRadius = dp(context, 22).toFloat() }
                setOnClickListener {
                    dismiss()
                    val i = Intent(context, MainActivity::class.java).apply {
                        putExtra(MainActivity.EXTRA_QUICK_ACTION, "library")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    }
                    try { context.startActivity(i) } catch (_: Exception) {}
                }
            }
            row.addView(cancelV)
            row.addView(openV)
            card.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

            val r = FrameLayout(context)
            r.setPadding(dp(context, 14), dp(context, 8), dp(context, 14), dp(context, 14))
            r.addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            val lp = WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, windowType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.TOP; y = dp(context, 36) }
            try {
                m.addView(r, lp)
                root = r
                wm = m
            } catch (e: Exception) {
                android.util.Log.w("LinkWatch", "progress card failed: $e")
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else handler.post(run)
    }

    /** state: running | done | failed | cancelled. percent < 0 keeps the bar small. */
    fun update(id: String, title: String?, percent: Double, speed: String?, state: String) {
        handler.post {
            val c = ctx ?: return@post
            if (root == null || finished) return@post
            taskId = id
            if (!title.isNullOrBlank()) titleV?.text = title
            val p = percent.coerceIn(0.0, 1.0).toFloat().coerceAtLeast(0.02f)
            (fillV?.layoutParams as? LinearLayout.LayoutParams)?.weight = p
            (restV?.layoutParams as? LinearLayout.LayoutParams)?.weight = 1f - p
            fillV?.requestLayout()
            when (state) {
                "done" -> {
                    finished = true
                    (fillV?.layoutParams as? LinearLayout.LayoutParams)?.weight = 1f
                    (restV?.layoutParams as? LinearLayout.LayoutParams)?.weight = 0f
                    subV?.text = "Done \u00B7 saved to your library"
                    cancelV?.visibility = View.GONE
                    openV?.text = "Done \u00B7 Open"
                    openV?.visibility = View.VISIBLE
                    handler.postDelayed(close, 6000)
                }
                "failed", "cancelled" -> {
                    finished = true
                    subV?.text = if (state == "failed") "Could not finish" else "Cancelled"
                    cancelV?.text = "Close"
                    cancelV?.setOnClickListener { dismiss() }
                    handler.postDelayed(close, 4000)
                }
                else -> {
                    subV?.text = if (percent < 0.01 && (speed ?: "").isEmpty()) "Preparing\u2026"
                    else ((speed ?: "").let { if (it.isEmpty()) "" else it + "  \u00B7  " }) + "${(percent * 100).toInt()}%"
                }
            }
        }
    }

    private fun dismissNow() {
        handler.removeCallbacks(close)
        val v = root ?: return
        root = null
        try { wm?.removeView(v) } catch (_: Exception) {}
    }

    fun dismiss() {
        handler.removeCallbacks(close)
        val v = root ?: return
        root = null
        try {
            val m = wm
            v.animate().alpha(0f).translationY(-48f).setDuration(160).start()
            // Always remove the window, even if the animation is cancelled.
            handler.postDelayed({ try { m?.removeViewImmediate(v) } catch (_: Exception) {} }, 180)
        } catch (_: Exception) {
            try { wm?.removeView(v) } catch (_: Exception) {}
        }
    }
}

package com.socialsave.social_save

import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.min

/** Draggable circular progress that the download card shrinks into.
 *  Done only closes the bubble. Open is the only control that brings SocialSave forward. */
object ProgressCard {
    private val handler = Handler(Looper.getMainLooper())
    private var root: FrameLayout? = null
    private var wm: WindowManager? = null
    private var lp: WindowManager.LayoutParams? = null
    private var ctx: Context? = null
    private var ring: RingView? = null
    private var doneV: TextView? = null
    private var openV: TextView? = null
    private var taskId: String = ""
    private var finished = false
    private var accent = Color.parseColor("#FF4C8DFF")
    private var surface = Color.WHITE
    private var ink = Color.BLACK
    private var muted = Color.GRAY
    private var useGlass = true
    private var darkUi = false
    private var asking = false
    private var answer: ((Boolean) -> Unit)? = null
    private var yesV: TextView? = null
    private var noV: TextView? = null
    private val hideFinished = Runnable { dismiss() }

    val active: Boolean get() = root != null

    private fun dp(c: Context, v: Int) = (v * c.resources.displayMetrics.density).toInt()

    fun begin(context: Context, windowType: Int, url: String, anchorX: Int = -1, anchorY: Int = -1) {
        val run = Runnable {
            dismissNow()
            finished = false
            taskId = ""
            ctx = context
            val m = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val dark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            darkUi = dark
            useGlass = glassOn(context)
            surface = if (dark) Color.parseColor("#F2182029") else Color.parseColor("#F2FFFFFF")
            ink = if (dark) Color.parseColor("#FFEAF0F6") else Color.parseColor("#FF111A22")
            muted = if (dark) Color.parseColor("#99EAF0F6") else Color.parseColor("#99111A22")
            val track = if (dark) Color.parseColor("#33FFFFFF") else Color.parseColor("#22000000")
            accent = Color.parseColor("#FF4C8DFF")

            val size = dp(context, 76)
            val bubble = FrameLayout(context)
            val ringView = RingView(context, accent, track, ink).apply {
                contentDescription = "Download progress. Long-press to cancel."
            }
            ring = ringView
            bubble.addView(ringView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            bubble.background = if (useGlass) GlassDisc(dark) else circle(surface, size)
            if (useGlass) {
                bubble.outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(view: View, outline: Outline) {
                        outline.setRoundRect(0, 0, view.width, view.height, view.height / 2f)
                    }
                }
                bubble.clipToOutline = true
            }
            bubble.elevation = dp(context, 8).toFloat()
            bubble.contentDescription = "Downloading ${LinkDetect.platformName(url)}"

            val params = WindowManager.LayoutParams(
                size, size, windowType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                // No blur-behind. That flag frosts the whole screen on this
                // phone and blocks using other apps while a download runs.
            }
            val dm = context.resources.displayMetrics
            if (anchorX > 0 && anchorY > 0) {
                params.x = anchorX - size / 2
                params.y = anchorY - size / 2
            } else {
                params.x = (dm.widthPixels - size) / 2
                params.y = dp(context, 96)
            }
            lp = params
            root = bubble
            wm = m
            clamp()
            installDrag(bubble)
            try {
                m.addView(bubble, params)
                bubble.scaleX = 0.15f
                bubble.scaleY = 0.15f
                bubble.alpha = 0.5f
                bubble.animate().scaleX(1f).scaleY(1f).alpha(1f)
                    .setDuration(320)
                    .setInterpolator(OvershootInterpolator(1.6f))
                    .start()
            } catch (e: Exception) {
                android.util.Log.w("LinkWatch", "progress bubble failed: $e")
                root = null
                ring = null
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else handler.post(run)
    }

    /** state: running | done | failed | cancelled. percent is 0..1. */
    fun update(id: String, title: String?, percent: Double, speed: String?, state: String) {
        handler.post {
            if (asking) return@post
            if (root == null || (finished && state == "running")) return@post
            if (id.isNotEmpty()) taskId = id
            val p = percent.toFloat().coerceIn(0f, 1f)
            when (state) {
                "ask" -> Unit
                "done" -> {
                    ring?.setFraction(1f, spinning = false)
                    showChoice(saved = true, title = title)
                }
                "failed", "cancelled" -> {
                    showChoice(saved = false, title = if (state == "failed") "Could not finish" else "Cancelled")
                }
                else -> {
                    if (finished) return@post
                    val label = (speed ?: "").trim()
                    val spinning = p < 0.02f && label.isEmpty()
                    ring?.setFraction(p, spinning, label)
                }
            }
        }
    }

    private fun showChoice(saved: Boolean, title: String?) {
        val bubble = root ?: return
        val context = ctx ?: return
        val params = lp ?: return
        if (finished) return
        finished = true
        asking = false
        yesV = null
        noV = null
        handler.removeCallbacks(hideFinished)
        val reveal = Runnable {
            bubble.removeAllViews()
            ring = null
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(dp(context, 6), dp(context, 6), dp(context, 6), dp(context, 6))
            }
            val close = TextView(context).apply {
                text = if (saved) "Done" else "Close"
                setTextColor(muted)
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(context, 14), 0, dp(context, 14), 0)
                minimumHeight = dp(context, 40)
            }
            doneV = close
            row.addView(close)
            if (saved) {
                val open = TextView(context).apply {
                    text = "Open"
                    setTextColor(Color.WHITE)
                    textSize = 14f
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    gravity = Gravity.CENTER
                    setPadding(dp(context, 16), 0, dp(context, 16), 0)
                    minimumHeight = dp(context, 40)
                    background = GradientDrawable().apply {
                        setColor(accent)
                        cornerRadius = dp(context, 20).toFloat()
                    }
                }
                openV = open
                row.addView(open, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    leftMargin = dp(context, 4)
                })
            } else {
                openV = null
            }
            row.alpha = 0f
            bubble.addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            row.animate().alpha(1f).setDuration(180).start()
            val label = title?.takeIf { it.isNotBlank() }
            bubble.contentDescription = if (saved) {
                "Saved${if (label != null) ": $label" else ""}. Done stays here. Open opens SocialSave."
            } else {
                title ?: "Could not finish"
            }
        }
        val current = ring
        if (current == null) reveal.run() else current.animate().alpha(0f).setDuration(140).withEndAction(reveal).start()

        val fromW = params.width
        val fromH = params.height
        val toW = dp(context, if (saved) 188 else 112)
        val toH = dp(context, 52)
        val cx = params.x + fromW / 2
        val cy = params.y + fromH / 2
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 280
            addUpdateListener { a ->
                val t = a.animatedValue as Float
                params.width = (fromW + (toW - fromW) * t).toInt()
                params.height = (fromH + (toH - fromH) * t).toInt()
                params.x = cx - params.width / 2
                params.y = cy - params.height / 2
                (bubble.background as? GradientDrawable)?.cornerRadius = params.height / 2f
                bubble.invalidateOutline()
                clamp()
                try { wm?.updateViewLayout(bubble, params) } catch (_: Exception) {}
            }
            start()
        }
        handler.postDelayed(hideFinished, 30000)
    }

    private fun installDrag(bubble: View) {
        val slop = dp(bubble.context, 6)
        var sx = 0f
        var sy = 0f
        var ox = 0
        var oy = 0
        var moved = false
        var downAt = 0L
        bubble.setOnTouchListener { _, e ->
            val params = lp ?: return@setOnTouchListener false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    handler.removeCallbacks(hideFinished)
                    sx = e.rawX
                    sy = e.rawY
                    ox = params.x
                    oy = params.y
                    moved = false
                    downAt = SystemClock.uptimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - sx).toInt()
                    val dy = (e.rawY - sy).toInt()
                    if (abs(dx) > slop || abs(dy) > slop) moved = true
                    if (moved) {
                        params.x = ox + dx
                        params.y = oy + dy
                        clamp()
                        try { wm?.updateViewLayout(bubble, params) } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!moved && e.actionMasked == MotionEvent.ACTION_UP) {
                        onTap(e.x, e.y, SystemClock.uptimeMillis() - downAt)
                    }
                    if (finished) handler.postDelayed(hideFinished, 30000)
                    true
                }
                else -> false
            }
        }
    }

    private fun onTap(x: Float, y: Float, held: Long) {
        if (asking) {
            val yes = yesV
            val no = noV
            if (yes != null && hit(yes, x, y)) {
                restoreRing()
                reply(true)
            } else if (no != null && hit(no, x, y)) {
                restoreRing()
                reply(false)
            }
            return
        }
        if (!finished) {
            if (held > 500) {
                ctx?.let { HeadlessEngine.send(it, "overlayCancel", taskId) }
                dismiss()
            }
            return
        }
        val open = openV
        val done = doneV
        if (open != null && hit(open, x, y)) {
            val context = ctx
            dismiss()
            if (context != null) {
                val i = Intent(context, MainActivity::class.java).apply {
                    putExtra(MainActivity.EXTRA_QUICK_ACTION, "library")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                }
                try { context.startActivity(i) } catch (_: Exception) {}
            }
        } else if (done != null && hit(done, x, y)) {
            dismiss()
        }
    }

    private fun hit(child: View, x: Float, y: Float): Boolean {
        val rect = android.graphics.Rect()
        child.getHitRect(rect)
        val parent = child.parent as? View
        if (parent != null) rect.offset(parent.left, parent.top)
        return rect.contains(x.toInt(), y.toInt())
    }

    private fun clamp() {
        val params = lp ?: return
        val c = ctx ?: return
        val dm = c.resources.displayMetrics
        params.x = params.x.coerceIn(0, (dm.widthPixels - params.width).coerceAtLeast(0))
        params.y = params.y.coerceIn(0, (dm.heightPixels - params.height).coerceAtLeast(0))
    }

    private fun circle(color: Int, size: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor(color)
            cornerRadius = size / 2f
        }
    }

    private fun dismissNow() {
        handler.removeCallbacks(hideFinished)
        reply(false)
        val v = root ?: return
        root = null
        ring = null
        doneV = null
        openV = null
        yesV = null
        noV = null
        try { wm?.removeView(v) } catch (_: Exception) {}
    }

    fun dismiss() {
        handler.removeCallbacks(hideFinished)
        reply(false)
        val v = root ?: return
        root = null
        ring = null
        doneV = null
        openV = null
        yesV = null
        noV = null
        try {
            val m = wm
            v.animate().alpha(0f).scaleX(0.6f).scaleY(0.6f).setDuration(160).start()
            handler.postDelayed({ try { m?.removeViewImmediate(v) } catch (_: Exception) {} }, 180)
        } catch (_: Exception) {
            try { wm?.removeView(v) } catch (_: Exception) {}
        }
    }

    /** True while a TikTok yes/no is waiting on this bubble. */
    fun busyAsking(): Boolean = answer != null

    /**
     * Ask on the bubble. Calls [onAnswer] once. Either answer puts the ring
     * back so the download can show its percent and speed.
     */
    fun ask(title: String, onAnswer: (Boolean) -> Unit) {
        val run = Runnable {
            if (root == null || answer != null) {
                handler.post { onAnswer(false) }
                return@Runnable
            }
            answer = onAnswer
            showQuestion(title)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else handler.post(run)
    }

    private fun showQuestion(title: String) {
        val bubble = root ?: return
        val context = ctx ?: return
        val params = lp ?: return
        asking = true
        finished = false
        handler.removeCallbacks(hideFinished)
        ring?.setFraction(0f, false)
        bubble.removeAllViews()
        ring = null
        yesV = null
        noV = null
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(context, 14), dp(context, 6), dp(context, 8), dp(context, 6))
        }
        val label = TextView(context).apply {
            text = "TikTok-ready?"
            setTextColor(ink)
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
        }
        row.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val no = TextView(context).apply {
            text = "No"
            setTextColor(muted)
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(dp(context, 12), 0, dp(context, 12), 0)
            minimumHeight = dp(context, 40)
        }
        noV = no
        row.addView(no)
        val yes = TextView(context).apply {
            text = "Yes"
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            setPadding(dp(context, 14), 0, dp(context, 14), 0)
            minimumHeight = dp(context, 36)
            background = GradientDrawable().apply {
                setColor(accent)
                cornerRadius = dp(context, 18).toFloat()
            }
        }
        yesV = yes
        row.addView(yes, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(context, 4)
        })
        bubble.addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val name = title.trim().take(80)
        bubble.contentDescription = if (name.isEmpty()) {
            "Make this video work on TikTok? No keeps this file. Yes rewrites it."
        } else {
            "Make $name work on TikTok? No keeps this file. Yes rewrites it."
        }
        resize(bubble, params, dp(context, 248), dp(context, 56))
    }

    private fun restoreRing() {
        val bubble = root ?: return
        val context = ctx ?: return
        val params = lp ?: return
        asking = false
        yesV = null
        noV = null
        finished = false
        bubble.removeAllViews()
        val track = if (darkUi) Color.parseColor("#33FFFFFF") else Color.parseColor("#22000000")
        val ringView = RingView(context, accent, track, ink).apply {
            contentDescription = "Making a file TikTok can open. Long-press to cancel."
            setFraction(0f, spinning = true)
        }
        ring = ringView
        bubble.addView(ringView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        bubble.contentDescription = "Making a file TikTok can open"
        val size = dp(context, 76)
        resize(bubble, params, size, size)
    }

    private fun resize(bubble: View, params: WindowManager.LayoutParams, toW: Int, toH: Int) {
        val fromW = params.width
        val fromH = params.height
        val cx = params.x + fromW / 2
        val cy = params.y + fromH / 2
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 280
            addUpdateListener { a ->
                val t = a.animatedValue as Float
                params.width = (fromW + (toW - fromW) * t).toInt()
                params.height = (fromH + (toH - fromH) * t).toInt()
                params.x = cx - params.width / 2
                params.y = cy - params.height / 2
                (bubble.background as? GradientDrawable)?.cornerRadius = params.height / 2f
                bubble.invalidateOutline()
                clamp()
                try { wm?.updateViewLayout(bubble, params) } catch (_: Exception) {}
            }
            start()
        }
    }

    private fun reply(yes: Boolean) {
        val cb = answer
        answer = null
        asking = false
        if (cb != null) handler.post { cb.invoke(yes) }
    }

    private fun glassOn(context: Context): Boolean = try {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.socialsave_liquidGlass", true)
    } catch (_: Exception) {
        true
    }

    /** Same lens as the Flutter glass: translucent fill, top shine, rim. No looping paint. */
    private class GlassDisc(private val dark: Boolean) : Drawable() {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        private val shine = Paint(Paint.ANTI_ALIAS_FLAG)
        private val reflect = Paint(Paint.ANTI_ALIAS_FLAG)
        private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        private val rect = RectF()
        private val clip = Path()

        private fun white(alpha: Float): Int {
            val a = (alpha * 255f).toInt().coerceIn(0, 255)
            return Color.argb(a, 255, 255, 255)
        }

        override fun draw(canvas: Canvas) {
            val b = bounds
            if (b.width() <= 0 || b.height() <= 0) return
            rect.set(b)
            val radius = min(b.width(), b.height()) / 2f
            fill.shader = LinearGradient(
                b.left.toFloat(), b.top.toFloat(), b.left.toFloat(), b.bottom.toFloat(),
                intArrayOf(
                    // 1.0.49: dark is a smoky neutral, not milky white.
                    if (dark) smoke(0.78f) else white(0.86f),
                    if (dark) smoke(0.70f) else white(0.72f),
                    if (dark) smoke(0.74f) else white(0.80f),
                ),
                floatArrayOf(0f, 0.48f, 1f),
                Shader.TileMode.CLAMP,
            )
            canvas.drawRoundRect(rect, radius, radius, fill)
            shine.shader = LinearGradient(
                b.left + b.width() * 0.2f, b.top.toFloat(),
                b.left + b.width() * 0.7f, b.top + b.height() * 0.575f,
                intArrayOf(
                    white(if (dark) 0.06f else 0.75f),
                    white(if (dark) 0.015f else 0.14f),
                    Color.argb(0, 255, 255, 255),
                ),
                floatArrayOf(0f, 0.28f, 0.62f),
                Shader.TileMode.CLAMP,
            )
            canvas.drawRoundRect(rect, radius, radius, shine)
            canvas.save()
            clip.reset()
            clip.addRoundRect(rect, radius, radius, Path.Direction.CW)
            canvas.clipPath(clip)
            val refTop = b.top + b.height() * 0.68f
            reflect.shader = LinearGradient(
                b.left.toFloat(), b.bottom.toFloat(), b.left.toFloat(), refTop,
                intArrayOf(if (dark) Color.argb(46, 0, 0, 0) else white(0.38f), Color.argb(0, 255, 255, 255)),
                null,
                Shader.TileMode.CLAMP,
            )
            canvas.drawRect(b.left.toFloat(), refTop, b.right.toFloat(), b.bottom.toFloat(), reflect)
            canvas.restore()
            val stroke = (b.height() * 1.25f / 76f).coerceAtLeast(2f)
            rim.strokeWidth = stroke
            rim.shader = LinearGradient(
                b.left.toFloat(), b.top.toFloat(), b.left.toFloat(), b.bottom.toFloat(),
                intArrayOf(
                    white(if (dark) 0.18f else 1f),
                    white(if (dark) 0.06f else 0.38f),
                    white(if (dark) 0.03f else 0.72f),
                ),
                floatArrayOf(0f, 0.5f, 1f),
                Shader.TileMode.CLAMP,
            )
            val inset = stroke / 2f
            val inner = RectF(b.left + inset, b.top + inset, b.right - inset, b.bottom - inset)
            canvas.drawRoundRect(inner, (radius - inset).coerceAtLeast(0f), (radius - inset).coerceAtLeast(0f), rim)
        }

        private fun smoke(a: Float): Int = Color.argb((a * 255).toInt().coerceIn(0, 255), 28, 28, 30)

        override fun setAlpha(alpha: Int) {}
        override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {}
        @Deprecated("Deprecated in Java")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
    }

    private class RingView(
        context: Context,
        private val accent: Int,
        private val track: Int,
        private val ink: Int,
    ) : View(context) {
        private var fraction = 0f
        private var spinning = true
        private var caption = ""
        private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            color = track
        }
        private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            color = accent
        }
        private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        private val oval = RectF()

        fun setFraction(value: Float, spinning: Boolean, caption: String = "") {
            fraction = value.coerceIn(0f, 1f)
            this.spinning = spinning
            val short = caption.substringBefore(" · ").trim()
            this.caption = if (spinning || short.length !in 1..12) "" else short
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val stroke = width * 0.07f
            trackPaint.strokeWidth = stroke
            arcPaint.strokeWidth = stroke
            val pad = stroke / 2f + width * 0.1f
            oval.set(pad, pad, width - pad, height - pad)
            canvas.drawArc(oval, 0f, 360f, false, trackPaint)
            if (spinning) {
                val t = (SystemClock.uptimeMillis() % 1100) / 1100f
                canvas.drawArc(oval, t * 360f - 90f, 96f, false, arcPaint)
                postInvalidateOnAnimation()
            } else {
                canvas.drawArc(oval, -90f, 360f * fraction.coerceAtLeast(0.02f), false, arcPaint)
            }
            val shown = if (spinning) "…" else "${(fraction * 100).toInt()}"
            val showCaption = caption.isNotEmpty()
            textPaint.textSize = width * if (showCaption) 0.18f else 0.2f
            val base = height / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
            val y = if (showCaption) base - textPaint.textSize * 0.35f else base
            canvas.drawText(shown, width / 2f, y, textPaint)
            if (showCaption) {
                val percentSize = textPaint.textSize
                textPaint.textSize = width * 0.11f
                val cy = y + percentSize * 0.95f
                canvas.drawText(caption, width / 2f, cy, textPaint)
            }
        }
    }
}

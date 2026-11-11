package com.socialsave.social_save

import android.app.Activity
import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationManagerCompat

/// A green message card that stays on screen. Reply sends from here and
/// does not open Social Save.
object ChatPop {
    private const val holdMs = 300_000L
    private val green = 0xFF00C853.toInt()
    private val ink = 0xFF04210F.toInt()
    private val handler = Handler(Looper.getMainLooper())
    private val hide = Runnable { dismiss(cancelNotice = true) }
    private var view: View? = null
    private var manager: WindowManager? = null
    private var noticeId = 0

    fun canDraw(context: Context): Boolean = Settings.canDrawOverlays(context)

    fun show(
        context: Context,
        id: Int,
        title: String,
        body: String,
        payload: String,
        api: String,
        token: String,
    ) {
        val app = context.applicationContext
        if (!canDraw(app)) return
        handler.post {
            try {
                dismiss(cancelNotice = false)
                val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val card = card(app, id, title, body, payload, api, token) { dismiss(cancelNotice = true) }
                val type = if (Build.VERSION.SDK_INT >= 26) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }
                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    type,
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    android.graphics.PixelFormat.TRANSLUCENT,
                )
                params.gravity = Gravity.TOP
                params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN
                wm.addView(card, params)
                view = card
                manager = wm
                noticeId = id
                handler.removeCallbacks(hide)
                handler.postDelayed(hide, holdMs)
            } catch (_: Exception) {
                dismiss(cancelNotice = false)
            }
        }
    }

    fun dismiss(cancelNotice: Boolean = false) {
        val drop = {
            handler.removeCallbacks(hide)
            val current = view
            val wm = manager
            view = null
            manager = null
            if (current != null && wm != null) {
                try {
                    wm.removeView(current)
                } catch (_: Exception) {
                }
            }
            if (cancelNotice && noticeId != 0) {
                val id = noticeId
                noticeId = 0
                try {
                    current?.context?.applicationContext?.let {
                        NotificationManagerCompat.from(it).cancel(id)
                    }
                } catch (_: Exception) {
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) drop() else handler.post(drop)
    }

    fun launch(
        context: Context,
        id: Int,
        title: String,
        body: String,
        payload: String,
        api: String,
        token: String,
    ): PendingIntent {
        val intent = Intent(context, ChatPopActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(ChatReply.EXTRA_ID, id)
            .putExtra(EXTRA_TITLE, title)
            .putExtra(EXTRA_BODY, body)
            .putExtra(ChatReply.EXTRA_PAYLOAD, payload)
            .putExtra(ChatReply.EXTRA_API, api)
            .putExtra(ChatReply.EXTRA_TOKEN, token)
        return PendingIntent.getActivity(
            context,
            id xor 0x51515151,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun screen(activity: Activity, intent: Intent, onClose: () -> Unit): View {
        val root = FrameLayout(activity)
        root.setBackgroundColor(0x00000000)
        val id = intent.getIntExtra(ChatReply.EXTRA_ID, 0)
        val card = card(
            activity,
            id,
            intent.getStringExtra(EXTRA_TITLE).orEmpty(),
            intent.getStringExtra(EXTRA_BODY).orEmpty(),
            intent.getStringExtra(ChatReply.EXTRA_PAYLOAD).orEmpty(),
            intent.getStringExtra(ChatReply.EXTRA_API).orEmpty(),
            intent.getStringExtra(ChatReply.EXTRA_TOKEN).orEmpty(),
            onClose,
        )
        root.addView(
            card,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )
        return root
    }

    private fun card(
        context: Context,
        id: Int,
        title: String,
        body: String,
        payload: String,
        api: String,
        token: String,
        onClose: () -> Unit,
    ): View {
        val d = context.resources.displayMetrics.density
        fun dp(v: Int) = (v * d).toInt()
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(12))
            background = GradientDrawable().apply {
                setColor(green)
                cornerRadius = dp(22).toFloat()
            }
            elevation = dp(8).toFloat()
        }
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val logo = ImageView(context).apply {
            val raw = BitmapFactory.decodeResource(context.resources, R.drawable.ic_notification_logo)
            if (raw != null) setImageBitmap(raw)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        header.addView(logo, LinearLayout.LayoutParams(dp(84), dp(84)))
        val words = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        words.addView(TextView(context).apply {
            text = title.ifEmpty { "Social Save" }
            setTextColor(ink)
            textSize = 18f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(12), 0, 0, 0)
        })
        words.addView(TextView(context).apply {
            text = body
            setTextColor(ink)
            textSize = 15f
            setPadding(dp(12), dp(4), 0, 0)
        })
        header.addView(words, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        box.addView(header)
        swipeAway(header, onClose)
        val input = EditText(context).apply {
            hint = "Reply"
            setHintTextColor(0x9904210F.toInt())
            setTextColor(ink)
            textSize = 16f
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = GradientDrawable().apply {
                setColor(0xFFFFFFFF.toInt())
                cornerRadius = dp(14).toFloat()
            }
        }
        val inputPad = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        inputPad.topMargin = dp(12)
        box.addView(input, inputPad)
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        val send = TextView(context).apply {
            text = "Send"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(10), dp(18), dp(10))
            background = GradientDrawable().apply {
                setColor(ink)
                cornerRadius = dp(14).toFloat()
            }
            setOnClickListener {
                val text = input.text?.toString()?.trim().orEmpty()
                if (text.isEmpty()) return@setOnClickListener
                isEnabled = false
                Thread {
                    val sent = try {
                        ChatReply.post(api, token, payload, text)
                    } catch (_: Exception) {
                        false
                    }
                    handler.post {
                        if (id != 0) {
                            try {
                                NotificationManagerCompat.from(context.applicationContext).cancel(id)
                            } catch (_: Exception) {
                            }
                        }
                        if (!sent) ChatReply.failed(context.applicationContext)
                        onClose()
                    }
                }.start()
            }
        }
        val cancel = TextView(context).apply {
            text = "Cancel"
            setTextColor(ink)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(10), dp(18), dp(10))
            setOnClickListener { onClose() }
        }
        val sendPad = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        sendPad.topMargin = dp(10)
        sendPad.marginEnd = dp(8)
        row.addView(send, sendPad)
        val cancelPad = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        cancelPad.topMargin = dp(10)
        row.addView(cancel, cancelPad)
        box.addView(row)
        val wrap = LinearLayout(context)
        val cardPad = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        cardPad.setMargins(dp(10), dp(10), dp(10), 0)
        wrap.addView(box, cardPad)
        return wrap
    }

    private fun swipeAway(target: View, onClose: () -> Unit) {
        var downX = 0f
        var downY = 0f
        target.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (kotlin.math.abs(dx) > 120 || dy < -80) onClose()
                    true
                }
                else -> false
            }
        }
    }

    private const val EXTRA_TITLE = "socialsave.chat.title"
    private const val EXTRA_BODY = "socialsave.chat.body"
}

/// Lock-screen card for a message. On an unlocked phone the sticky banner
/// is enough, so this closes and leaves that banner up.
class ChatPopActivity : Activity() {
    private val hide = Runnable { if (!isFinishing) finish() }
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val locked = if (Build.VERSION.SDK_INT >= 27) {
            (getSystemService(KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        } else {
            false
        }
        if (pm.isInteractive && !locked) {
            finish()
            return
        }
        val id = intent.getIntExtra(ChatReply.EXTRA_ID, 0)
        setContentView(ChatPop.screen(this, intent) {
            if (id != 0) {
                try {
                    NotificationManagerCompat.from(this).cancel(id)
                } catch (_: Exception) {
                }
            }
            finish()
        })
        handler.postDelayed(hide, 300_000L)
    }

    override fun onDestroy() {
        handler.removeCallbacks(hide)
        super.onDestroy()
    }
}

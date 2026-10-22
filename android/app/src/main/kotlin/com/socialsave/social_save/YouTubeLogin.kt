package com.socialsave.social_save

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Toast
import java.io.File

/**
 * Optional "Sign in to YouTube" for the on-phone engine: a WebView login whose
 * youtube.com/google.com cookies are written as a Netscape cookies.txt in app
 * private storage and passed to yt-dlp with --cookies. Nothing leaves the phone.
 */
object YouTubeLogin {
    private const val FILE = "youtube_cookies.txt"

    fun cookieFile(context: Context): File? =
        File(context.filesDir, FILE).takeIf { it.isFile && it.length() > 0 }

    fun signedIn(context: Context): Boolean =
        cookieFile(context)?.readText()?.let { it.contains("\tSAPISID\t") || it.contains("\tLOGIN_INFO\t") || it.contains("\t__Secure-3PSID\t") } == true

    fun start(context: Context) {
        context.startActivity(Intent(context, YouTubeLoginActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun signOut(context: Context) {
        File(context.filesDir, FILE).delete()
        val cm = CookieManager.getInstance()
        cm.removeAllCookies(null)
        cm.flush()
    }

    /** Writes the WebView's cookies; true when the YouTube login cookies are there. */
    fun export(context: Context): Boolean {
        val cm = CookieManager.getInstance()
        cm.flush()
        val expiry = System.currentTimeMillis() / 1000 + 180L * 24 * 3600
        val sb = StringBuilder("# Netscape HTTP Cookie File\n")
        val seen = HashSet<String>()
        for ((url, domain) in listOf(
            "https://www.youtube.com" to ".youtube.com",
            "https://m.youtube.com" to ".youtube.com",
            "https://accounts.google.com" to ".google.com",
            "https://www.google.com" to ".google.com",
        )) {
            val raw = cm.getCookie(url) ?: continue
            for (part in raw.split(";")) {
                val i = part.indexOf('=')
                if (i <= 0) continue
                val name = part.substring(0, i).trim()
                val value = part.substring(i + 1).trim()
                if (!seen.add("$domain|$name")) continue
                val host = if (name.startsWith("__Host-")) domain.trimStart('.') else domain
                val sub = if (host.startsWith(".")) "TRUE" else "FALSE"
                sb.append("$host\t$sub\t/\tTRUE\t$expiry\t$name\t$value\n")
            }
        }
        File(context.filesDir, FILE).writeText(sb.toString())
        return signedIn(context)
    }
}

class YouTubeLoginActivity : Activity() {
    private lateinit var web: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        web = WebView(this)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        // Google refuses sign-in from WebViews that announce themselves ("wv").
        web.settings.userAgentString = web.settings.userAgentString.replace("; wv", "")
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                if (url.contains("youtube.com") && !url.contains("accounts.google") && YouTubeLogin.export(this@YouTubeLoginActivity)) {
                    Toast.makeText(this@YouTubeLoginActivity, "Signed in to YouTube", Toast.LENGTH_SHORT).show()
                    finish()
                }
            }
        }
        val done = Button(this).apply {
            text = "Done"
            setOnClickListener {
                val ok = YouTubeLogin.export(this@YouTubeLoginActivity)
                Toast.makeText(this@YouTubeLoginActivity, if (ok) "Signed in to YouTube" else "Not signed in yet", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(done, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)
        web.loadUrl("https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F")
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else { YouTubeLogin.export(this); super.onBackPressed() }
    }
}

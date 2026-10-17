package com.socialsave.social_save

import android.annotation.SuppressLint
import android.content.Context
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Phone-to-phone "Fast share": the sender opens a local-only hotspot (no
 * internet, just a direct Wi-Fi link) and the receiver joins it, so the
 * file moves at full Wi-Fi speed without a router.
 */
class HotspotShare private constructor(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "SocialSaveHotspot"
        private var instance: HotspotShare? = null

        /**
         * One app-wide instance: the hotspot reservation and the joined
         * network belong to the app (and a connected session), not to an
         * activity, so closing the screen never drops them.
         */
        fun attach(context: Context, messenger: BinaryMessenger): HotspotShare {
            instance?.let {
                it.rebind(messenger)
                return it
            }
            return HotspotShare(context.applicationContext, messenger).also { instance = it }
        }

        fun disposeAll() {
            instance?.dispose()
            instance = null
        }
    }

    private var channel = MethodChannel(messenger, "socialsave/hotspot")

    private fun rebind(messenger: BinaryMessenger) {
        channel.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "socialsave/hotspot")
        channel.setMethodCallHandler(this)
    }
    private val main = Handler(Looper.getMainLooper())
    private val wifi get() = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val cm get() = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var legacyNetId: Int = -1
    private var bound = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "start" -> {
                // Re-opening for a connected session: same name and password,
                // so the other phone can join again by itself.
                reuseSsid = call.argument<String>("ssid")
                reusePassword = call.argument<String>("password")
                start(result, call.argument<String>("band") ?: "auto")
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            "join" -> join(
                call.argument<String>("ssid") ?: "",
                call.argument<String>("password") ?: "",
                result,
            )
            "leave" -> {
                leave()
                result.success(true)
            }
            "apAddress" -> result.success(apAddress())
            else -> result.notImplemented()
        }
    }

    private fun status(): Map<String, Any?> {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val locationOn = if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "wifiOn" to wifi.isWifiEnabled,
            "locationOn" to locationOn,
            "hotspotRunning" to (reservation != null),
            "maker" to Build.MANUFACTURER,
        )
    }

    // ---------------------------------------------------------------- sender

    /** Short password we ask for (Android 13+ only, see [customConfig]). */
    private var wantedPassword: String? = null

    @SuppressLint("MissingPermission")
    /** What the user asked for and what we could do, shown in the dialog. */
    private var bandNote: String = ""
    private var reuseSsid: String? = null
    private var reusePassword: String? = null

    private fun start(result: MethodChannel.Result, band: String) {
        if (Build.VERSION.SDK_INT < 26) {
            result.error("too_old", "Fast share needs Android 8 or newer on the sending phone.", null)
            return
        }
        reservation?.let {
            result.success(describe(it))
            return
        }
        var answered = false
        fun answer(block: () -> Unit) {
            if (answered) return
            answered = true
            block()
        }
        // Some phones never call back when the maker blocks it.
        main.postDelayed({
            answer { result.error("timeout", "The hotspot did not start. Turn off the phone's own hotspot and try again.", null) }
        }, 30000)

        fun callback(onFail: (Int) -> Unit) = object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                if (answered) {
                    // Timed out meanwhile: give it back.
                    try { res.close() } catch (_: Exception) {}
                    return
                }
                reservation = res
                val info = describe(res)
                Log.i(TAG, "hotspot started ssid=${info["ssid"]} ip=${info["ip"]} custom=${info["custom"]}")
                answer { result.success(info) }
            }

            override fun onStopped() {
                Log.i(TAG, "hotspot stopped")
                reservation = null
                main.post { channel.invokeMethod("stopped", null) }
            }

            override fun onFailed(reason: Int) {
                Log.w(TAG, "hotspot failed reason=$reason")
                onFail(reason)
            }
        }

        fun fail(reason: Int) {
            val message = when (reason) {
                WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
                    "The phone's own hotspot or another Wi-Fi mode is on. Turn off Mobile Hotspot and try again."
                WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
                    "This phone's settings or maker don't allow a hotspot."
                WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
                    "No free Wi-Fi channel for a hotspot right now. Try again in a moment."
                else -> "The hotspot could not start (code $reason)."
            }
            answer { result.error("failed_$reason", message, null) }
        }

        fun standard() {
            wantedPassword = null
            try {
                wifi.startLocalOnlyHotspot(callback(::fail), main)
            } catch (e: SecurityException) {
                answer { result.error("permission", "SocialSave needs the Nearby devices (or Location) permission for Fast share.", null) }
            } catch (e: IllegalStateException) {
                answer { result.error("busy", "A hotspot is already running. Turn off Mobile Hotspot and try again.", null) }
            } catch (e: Exception) {
                answer { result.error("failed", e.message ?: "The hotspot could not start.", null) }
            }
        }

        // Android 13+: ask for a short, easy password and the chosen band
        // (hidden but app-callable overload that only needs
        // NEARBY_WIFI_DEVICES). Each refusal falls back one step; the last
        // step is the normal random hotspot.
        if (Build.VERSION.SDK_INT < 33) {
            bandNote = "Android ${Build.VERSION.RELEASE} picks the hotspot band itself (choosing needs Android 13+)."
            standard()
            return
        }
        @Suppress("DEPRECATION")
        val has5 = try { wifi.is5GHzBandSupported } catch (_: Throwable) { false }
        // SoftApConfiguration bands: 1 = 2.4 GHz, 2 = 5 GHz, 3 = either.
        val attempts: List<Int?> = when {
            band == "2.4" -> listOf(1, null)
            !has5 -> listOf(1, null)
            band == "5" -> listOf(2, 1, null)
            else -> listOf(2, 3, null)
        }
        bandNote = if (!has5 && band != "2.4") "Using 2.4 GHz (this phone doesn't support 5 GHz)." else ""
        val method = try {
            WifiManager::class.java.getMethod(
                "startLocalOnlyHotspot",
                Class.forName("android.net.wifi.SoftApConfiguration"),
                java.util.concurrent.Executor::class.java,
                WifiManager.LocalOnlyHotspotCallback::class.java,
            )
        } catch (e: Throwable) {
            Log.w(TAG, "custom hotspot not available: ${e.cause ?: e}")
            bandNote = "This phone doesn't let apps choose the hotspot band; using its default."
            standard()
            return
        }
        fun attempt(i: Int) {
            if (answered) return
            if (i >= attempts.size) {
                bandNote = "This phone refused SocialSave's hotspot settings; using its default band and password."
                standard()
                return
            }
            val mask = attempts[i]
            val config = customConfig(mask)
            if (config == null) {
                attempt(i + 1)
                return
            }
            try {
                Log.i(TAG, "starting hotspot band=${mask ?: "default"}")
                method.invoke(wifi, config, java.util.concurrent.Executor { main.post(it) }, callback { reason ->
                    Log.w(TAG, "hotspot with band=${mask ?: "default"} refused ($reason)")
                    main.post { attempt(i + 1) }
                })
            } catch (e: Throwable) {
                Log.w(TAG, "hotspot with band=${mask ?: "default"} failed: ${e.cause ?: e}")
                attempt(i + 1)
            }
        }
        attempt(0)
    }

    /** SoftApConfiguration with name "SocialSave-1234" and an 8-digit password, or null. */
    private fun customConfig(bandMask: Int?): Any? {
        return try {
            val rnd = java.security.SecureRandom()
            val password = reusePassword?.takeIf { it.length >= 8 } ?: (1..8).map { rnd.nextInt(10) }.joinToString("")
            val ssid = reuseSsid?.takeIf { it.isNotEmpty() } ?: ("SocialSave-" + (1..4).map { rnd.nextInt(10) }.joinToString(""))
            val builderClass = Class.forName("android.net.wifi.SoftApConfiguration\$Builder")
            val builder = builderClass.getConstructor().newInstance()
            var named = false
            try {
                val wifiSsidClass = Class.forName("android.net.wifi.WifiSsid")
                val wifiSsid = wifiSsidClass.getMethod("fromBytes", ByteArray::class.java)
                    .invoke(null, ssid.toByteArray(Charsets.UTF_8))
                builderClass.getMethod("setWifiSsid", wifiSsidClass).invoke(builder, wifiSsid)
                named = true
            } catch (_: Throwable) {
            }
            if (!named) {
                try {
                    builderClass.getMethod("setSsid", String::class.java).invoke(builder, ssid)
                } catch (_: Throwable) {
                }
            }
            // 1 = SECURITY_TYPE_WPA2_PSK (easiest for any phone or PC to join).
            builderClass.getMethod("setPassphrase", String::class.java, Int::class.javaPrimitiveType).invoke(builder, password, 1)
            if (bandMask != null) {
                builderClass.getMethod("setBand", Int::class.javaPrimitiveType).invoke(builder, bandMask)
            }
            val config = builderClass.getMethod("build").invoke(builder)
            wantedPassword = password
            config
        } catch (e: Throwable) {
            Log.w(TAG, "custom hotspot config not possible: ${e.cause ?: e}")
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun describe(res: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?> {
        var ssid: String? = null
        var password: String? = null
        if (Build.VERSION.SDK_INT >= 30) {
            val conf = res.softApConfiguration
            ssid = if (Build.VERSION.SDK_INT >= 33) conf.wifiSsid?.toString() else conf.ssid
            password = conf.passphrase
        } else {
            val conf = res.wifiConfiguration
            ssid = conf?.SSID
            password = conf?.preSharedKey
        }
        return mapOf(
            "ssid" to ssid?.trim('"'),
            "password" to password?.trim('"'),
            "ip" to apAddress(),
            "custom" to (wantedPassword != null && password?.trim('"') == wantedPassword),
            "band" to bandOf(res),
            "bandNote" to listOf(bandNote, phoneStaNote()).filter { it.isNotEmpty() }.joinToString(" "),
            "staFreq" to staFrequency(),
        )
    }

    /** MHz of the Wi-Fi network this phone is still joined to, or -1. */
    private fun staFrequency(): Int = try {
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo
        if (info == null || info.networkId == -1 && info.frequency <= 0) -1 else info.frequency
    } catch (_: Throwable) {
        -1
    }

    /**
     * Measured on a SHARP AQUOS R7 joined to a 2.4 GHz router: the hotspot has
     * to share the router's channel (one radio), and transfers ran at 1-1.5 MB/s
     * whatever band was asked for. Say so instead of promising "5 GHz".
     */
    private fun phoneStaNote(): String {
        val f = staFrequency()
        return if (f in 2400..2500) {
            "This phone is also on a 2.4 GHz Wi-Fi network, so the hotspot shares that channel and runs at about 1-2 MB/s. " +
                "For a faster link, turn Wi-Fi off on this phone first (Fast share works without it), or use a USB cable."
        } else {
            ""
        }
    }

    /** Band mask of the running hotspot (1 = 2.4, 2 = 5, 3 = either, 4 = 6 GHz), or null. */
    private fun bandOf(res: WifiManager.LocalOnlyHotspotReservation): Int? {
        if (Build.VERSION.SDK_INT < 30) return null
        return try {
            val conf = res.softApConfiguration
            conf.javaClass.getMethod("getBand").invoke(conf) as? Int
        } catch (_: Throwable) {
            null
        }
    }

    /** IPv4 address of the hotspot interface (usually 192.168.x.1). */
    private fun apAddress(): String? {
        try {
            val candidates = mutableListOf<Pair<String, String>>()
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.isUp || nif.isLoopback) continue
                for (addr in nif.inetAddresses) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    candidates.add(nif.name to addr.hostAddress!!)
                }
            }
            Log.i(TAG, "interfaces $candidates")
            val apNames = listOf("swlan", "ap", "softap", "wlan1", "wlan2", "wigig")
            candidates.firstOrNull { (n, _) -> apNames.any { n.startsWith(it) } }?.let { return it.second }
            // Hotspots hand out 192.168.x.0/24 and sit on .1.
            candidates.firstOrNull { (n, ip) -> !n.startsWith("rmnet") && ip.startsWith("192.168.") && ip.endsWith(".1") }
                ?.let { return it.second }
        } catch (e: Exception) {
            Log.w(TAG, "apAddress", e)
        }
        return null
    }

    private fun stop() {
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
    }

    // -------------------------------------------------------------- receiver

    @SuppressLint("MissingPermission")
    private fun join(ssid: String, password: String, result: MethodChannel.Result) {
        if (ssid.isEmpty()) {
            result.error("bad", "No hotspot name in the code.", null)
            return
        }
        leave()
        var answered = false
        fun answer(block: () -> Unit) {
            if (answered) return
            answered = true
            block()
        }
        main.postDelayed({
            answer { result.error("timeout", "Could not join $ssid. Join it in Wi-Fi settings, then try again.", null) }
        }, 45000)
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
                    if (password.isNotEmpty()) setWpa2Passphrase(password)
                }.build()
                val request = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .setNetworkSpecifier(spec)
                    .build()
                val cb = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        bound = cm.bindProcessToNetwork(network)
                        Log.i(TAG, "joined $ssid bound=$bound")
                        main.post { try { channel.invokeMethod("available", null) } catch (_: Exception) {} }
                        main.post { answer { result.success(mapOf("joined" to true, "bound" to bound)) } }
                    }

                    override fun onUnavailable() {
                        Log.w(TAG, "join unavailable")
                        main.post { answer { result.error("declined", "Not connected to $ssid (cancelled or not found).", null) } }
                    }

                    override fun onLost(network: Network) {
                        Log.i(TAG, "hotspot link lost")
                        if (bound) {
                            cm.bindProcessToNetwork(null)
                            bound = false
                        }
                        main.post { channel.invokeMethod("lost", null) }
                    }
                }
                joinCallback = cb
                cm.requestNetwork(request, cb)
            } catch (e: SecurityException) {
                answer { result.error("permission", "SocialSave needs the Nearby devices (or Location) permission to join.", null) }
            } catch (e: Exception) {
                answer { result.error("failed", e.message ?: "Could not join the hotspot.", null) }
            }
            return
        }
        // Android 9 and older.
        try {
            @Suppress("DEPRECATION")
            val conf = WifiConfiguration().apply {
                SSID = "\"$ssid\""
                if (password.isNotEmpty()) preSharedKey = "\"$password\"" else allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            }
            if (!wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.isWifiEnabled = true
            }
            @Suppress("DEPRECATION")
            val id = wifi.addNetwork(conf)
            if (id < 0) {
                answer { result.error("manual", "Join $ssid in Wi-Fi settings (password $password), then try again.", null) }
                return
            }
            legacyNetId = id
            @Suppress("DEPRECATION")
            wifi.disconnect()
            @Suppress("DEPRECATION")
            wifi.enableNetwork(id, true)
            @Suppress("DEPRECATION")
            wifi.reconnect()
            val started = System.currentTimeMillis()
            val poll = object : Runnable {
                override fun run() {
                    @Suppress("DEPRECATION")
                    val now = wifi.connectionInfo?.ssid?.trim('"')
                    val net = cm.allNetworks.firstOrNull {
                        cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    }
                    if (now == ssid && net != null) {
                        bound = cm.bindProcessToNetwork(net)
                        answer { result.success(mapOf("joined" to true, "bound" to bound)) }
                    } else if (System.currentTimeMillis() - started > 30000) {
                        answer { result.error("manual", "Join $ssid in Wi-Fi settings (password $password), then try again.", null) }
                    } else {
                        main.postDelayed(this, 700)
                    }
                }
            }
            main.postDelayed(poll, 1000)
        } catch (e: Exception) {
            answer { result.error("manual", "Join $ssid in Wi-Fi settings (password $password), then try again.", null) }
        }
    }

    private fun leave() {
        if (bound) {
            try {
                cm.bindProcessToNetwork(null)
            } catch (_: Exception) {
            }
            bound = false
        }
        joinCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        joinCallback = null
        if (legacyNetId >= 0) {
            try {
                @Suppress("DEPRECATION")
                wifi.removeNetwork(legacyNetId)
            } catch (_: Exception) {
            }
            legacyNetId = -1
        }
    }

    fun dispose() {
        leave()
        stop()
        channel.setMethodCallHandler(null)
    }
}

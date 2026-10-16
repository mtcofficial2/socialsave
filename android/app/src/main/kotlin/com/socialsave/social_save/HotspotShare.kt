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
class HotspotShare(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "SocialSaveHotspot"
    }

    private val channel = MethodChannel(messenger, "socialsave/hotspot")
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
            "start" -> start(result)
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

    @SuppressLint("MissingPermission")
    private fun start(result: MethodChannel.Result) {
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
        }, 15000)
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    val info = describe(res)
                    Log.i(TAG, "hotspot started ssid=${info["ssid"]} ip=${info["ip"]}")
                    answer { result.success(info) }
                }

                override fun onStopped() {
                    Log.i(TAG, "hotspot stopped")
                    reservation = null
                    main.post { channel.invokeMethod("stopped", null) }
                }

                override fun onFailed(reason: Int) {
                    Log.w(TAG, "hotspot failed reason=$reason")
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
            }, main)
        } catch (e: SecurityException) {
            answer { result.error("permission", "SocialSave needs the Nearby devices (or Location) permission for Fast share.", null) }
        } catch (e: IllegalStateException) {
            answer { result.error("busy", "A hotspot is already running. Turn off Mobile Hotspot and try again.", null) }
        } catch (e: Exception) {
            answer { result.error("failed", e.message ?: "The hotspot could not start.", null) }
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
        )
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

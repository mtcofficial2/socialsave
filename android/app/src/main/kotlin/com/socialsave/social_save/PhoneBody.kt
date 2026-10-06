package com.socialsave.social_save

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.media.AudioAttributes
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadata
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.media.RingtoneManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import android.view.WindowManager
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * Phone sensors and the media session. Pocket becomes true only after the
 * phone stays face-down or covered for two seconds. Volume keys seek only
 * while the screen is off and a video is playing.
 */
class PhoneBody(
    private val activity: MainActivity,
) : SensorEventListener, io.flutter.plugin.common.EventChannel.StreamHandler {
    private val handler = Handler(Looper.getMainLooper())
    private val sensorManager = activity.getSystemService(SensorManager::class.java)
    private val displayManager = activity.getSystemService(DisplayManager::class.java)
    private var sink: io.flutter.plugin.common.EventChannel.EventSink? = null
    private var session: MediaSession? = null
    private var receiver: BroadcastReceiver? = null
    private var displayListener: DisplayManager.DisplayListener? = null

    private var battery = -1
    private var charging = false
    private var near = false
    private var faceDown = false
    private var pocketCandidate = false
    private var pocket = false
    private var screenOff = false
    private var known = false

    private var playbackActive = false
    private var playing = false
    private var headsetEnabled = true
    private var volumeSeekEnabled = true
    private var title = "SocialSave"
    private var hookAt = 0L

    private val confirmPocket = Runnable {
        if (pocketCandidate && !pocket) {
            pocket = true
            pushState()
        }
    }
    private val clearPocket = Runnable {
        if (!pocketCandidate && pocket) {
            pocket = false
            pushState()
        }
    }
    private val singleHook = Runnable { emitAction("toggle", 0) }

    private val volumeProvider = object : VolumeProvider(VOLUME_CONTROL_RELATIVE, 0, 0) {
        override fun onAdjustVolume(direction: Int) {
            if (!volumeSeekEnabled || !screenOff || !playing) return
            if (direction > 0) emitAction("seek", 10)
            else if (direction < 0) emitAction("seek", -10)
        }
    }

    override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink) {
        sink = events
        start()
        pushState()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stop()
    }

    fun start() {
        if (receiver != null) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        val registered = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_BATTERY_CHANGED -> readBattery(intent)
                    Intent.ACTION_SCREEN_OFF -> {
                        screenOff = true
                        updateVolumeRoute()
                        pushState()
                    }
                    Intent.ACTION_SCREEN_ON -> {
                        screenOff = false
                        updateVolumeRoute()
                        pushState()
                    }
                }
            }
        }
        val sticky = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(registered, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(registered, filter)
        }
        receiver = registered
        if (sticky != null) readBattery(sticky)
        screenOff = activity.getSystemService(android.os.PowerManager::class.java)?.isInteractive == false
        sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sensorManager?.getDefaultSensor(Sensor.TYPE_PROXIMITY)?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = pushState()
            override fun onDisplayRemoved(displayId: Int) = pushState()
            override fun onDisplayChanged(displayId: Int) = Unit
        }
        displayListener = listener
        displayManager?.registerDisplayListener(listener, handler)
        ensureSession()
        known = true
    }

    fun stop() {
        handler.removeCallbacks(confirmPocket)
        handler.removeCallbacks(clearPocket)
        handler.removeCallbacks(singleHook)
        sensorManager?.unregisterListener(this)
        displayListener?.let { displayManager?.unregisterDisplayListener(it) }
        displayListener = null
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
        session?.isActive = false
        session?.release()
        session = null
    }

    fun setPlayback(
        active: Boolean,
        playing: Boolean,
        title: String?,
        headset: Boolean,
        volumeSeek: Boolean,
    ) {
        playbackActive = active
        this.playing = playing
        headsetEnabled = headset
        volumeSeekEnabled = volumeSeek
        if (!title.isNullOrBlank()) this.title = title
        ensureSession()
        val current = session ?: return
        current.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, this.title)
                .build(),
        )
        val state = if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        current.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SEEK_TO,
                )
                .setState(state, PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (playing) 1f else 0f)
                .build(),
        )
        current.isActive = active
        updateVolumeRoute()
    }

    fun vibrate(pattern: String?) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            activity.getSystemService(Vibrator::class.java)
        } ?: return
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (pattern == "failed") {
                VibrationEffect.createWaveform(longArrayOf(0, 70, 90, 70), -1)
            } else {
                VibrationEffect.createOneShot(70, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            vibrator.vibrate(effect)
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(if (pattern == "failed") 180 else 70)
        }
    }

    fun setBrightness(value: Double) {
        activity.runOnUiThread {
            val params = activity.window.attributes
            params.screenBrightness = if (value < 0) {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            } else {
                value.toFloat().coerceIn(0.01f, 1f)
            }
            activity.window.attributes = params
        }
    }

    fun copyIntoTree(tree: String, path: String, name: String): String? {
        val source = File(path)
        if (!source.exists()) return null
        val treeUri = android.net.Uri.parse(tree)
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val root = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        val mime = if (name.endsWith(".webm", ignoreCase = true)) "video/webm" else "video/mp4"
        val dest = DocumentsContract.createDocument(activity.contentResolver, root, mime, name)
            ?: return null
        activity.contentResolver.openOutputStream(dest)?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: return null
        return dest.toString()
    }

    fun clipSound(path: String, kind: String): Map<String, Any?> {
        val clipped = clipAudio(path) ?: return mapOf(
            "ok" to false,
            "needsSettings" to false,
            "message" to "This video has no audio to use.",
        )
        val label = when (kind) {
            "notification" -> "SocialSave notification"
            "alarm" -> "SocialSave alarm"
            else -> "SocialSave ringtone"
        }
        val uri = publishAudio(clipped, "$label.m4a", kind) ?: return mapOf(
            "ok" to false,
            "needsSettings" to false,
            "message" to "Could not save that sound.",
        )
        clipped.delete()
        if (!Settings.System.canWrite(activity)) {
            return mapOf(
                "ok" to true,
                "needsSettings" to true,
                "message" to "The sound is saved. Allow SocialSave to change system settings, then choose it again.",
            )
        }
        val type = when (kind) {
            "notification" -> RingtoneManager.TYPE_NOTIFICATION
            "alarm" -> RingtoneManager.TYPE_ALARM
            else -> RingtoneManager.TYPE_RINGTONE
        }
        return try {
            RingtoneManager.setActualDefaultRingtoneUri(activity, type, uri)
            mapOf(
                "ok" to true,
                "needsSettings" to false,
                "message" to "Set as the phone $kind.",
            )
        } catch (error: Exception) {
            Log.w("SocialSave", "ringtone", error)
            mapOf(
                "ok" to true,
                "needsSettings" to false,
                "message" to "Saved the sound. Set it in the phone sound settings.",
            )
        }
    }

    private fun clipAudio(path: String): File? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
        } catch (_: Exception) {
            extractor.release()
            return null
        }
        var track = -1
        var format: MediaFormat? = null
        for (index in 0 until extractor.trackCount) {
            val candidate = extractor.getTrackFormat(index)
            val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                track = index
                format = candidate
                break
            }
        }
        if (track < 0 || format == null) {
            extractor.release()
            return null
        }
        extractor.selectTrack(track)
        val dest = File(activity.cacheDir, "sound_${System.currentTimeMillis()}.m4a")
        val muxer = MediaMuxer(dest.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        return try {
            val muxTrack = muxer.addTrack(format)
            muxer.start()
            val buffer = ByteBuffer.allocate(256 * 1024)
            val info = android.media.MediaCodec.BufferInfo()
            val limitUs = 30_000_000L
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val time = extractor.sampleTime
                if (time > limitUs) break
                info.offset = 0
                info.size = size
                info.presentationTimeUs = time.coerceAtLeast(0)
                info.flags = extractor.sampleFlags
                muxer.writeSampleData(muxTrack, buffer, info)
                extractor.advance()
            }
            muxer.stop()
            if (dest.length() < 32) null else dest
        } catch (_: Exception) {
            dest.delete()
            throw IllegalStateException("Could not cut the first 30 seconds.")
        } finally {
            try {
                muxer.release()
            } catch (_: Exception) {
            }
            extractor.release()
        }
    }

    private fun publishAudio(file: File, name: String, kind: String): android.net.Uri? {
        val values = android.content.ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, name)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
            put(MediaStore.Audio.Media.IS_RINGTONE, kind == "ringtone")
            put(MediaStore.Audio.Media.IS_NOTIFICATION, kind == "notification")
            put(MediaStore.Audio.Media.IS_ALARM, kind == "alarm")
            put(MediaStore.Audio.Media.IS_MUSIC, false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_RINGTONES)
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
            if (!dir.exists()) dir.mkdirs()
            val target = File(dir, name)
            file.copyTo(target, overwrite = true)
            values.put(MediaStore.Audio.Media.DATA, target.absolutePath)
            MediaScannerConnection.scanFile(activity, arrayOf(target.absolutePath), arrayOf("audio/mp4"), null)
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val uri = activity.contentResolver.insert(collection, values) ?: return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            activity.contentResolver.openOutputStream(uri)?.use { output ->
                FileInputStream(file).use { input -> input.copyTo(output) }
            } ?: return null
            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            activity.contentResolver.update(uri, values, null, null)
        }
        return uri
    }

    override fun onSensorChanged(event: SensorEvent?) {
        val sensor = event ?: return
        when (sensor.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                val z = sensor.values.getOrNull(2) ?: return
                val down = z < -7.5f
                if (down != faceDown) {
                    faceDown = down
                    refreshPocket()
                }
            }
            Sensor.TYPE_PROXIMITY -> {
                val max = sensor.sensor.maximumRange
                val covered = sensor.values.getOrNull(0)?.let { it < max } == true
                if (covered != near) {
                    near = covered
                    refreshPocket()
                }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun refreshPocket() {
        val next = near || faceDown
        if (next == pocketCandidate) return
        pocketCandidate = next
        handler.removeCallbacks(confirmPocket)
        handler.removeCallbacks(clearPocket)
        if (next) {
            handler.postDelayed(confirmPocket, 2000)
        } else {
            handler.postDelayed(clearPocket, 400)
        }
        pushState()
    }

    private fun readBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        battery = if (level < 0) -1 else (level * 100) / scale
        charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        known = true
        pushState()
    }

    private fun externalDisplay(): Boolean {
        val displays = displayManager?.displays ?: return false
        return displays.any { it.displayId != Display.DEFAULT_DISPLAY }
    }

    private fun ensureSession() {
        if (session != null) return
        val created = MediaSession(activity, "SocialSave")
        created.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                if (!headsetEnabled || !playbackActive) {
                    return super.onMediaButtonEvent(mediaButtonIntent)
                }
                val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                } ?: return super.onMediaButtonEvent(mediaButtonIntent)
                if (event.action != KeyEvent.ACTION_DOWN) return true
                when (event.keyCode) {
                    KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                        val now = android.os.SystemClock.uptimeMillis()
                        if (now - hookAt < 450) {
                            handler.removeCallbacks(singleHook)
                            hookAt = 0
                            emitAction("next", 0)
                        } else {
                            hookAt = now
                            handler.postDelayed(singleHook, 450)
                        }
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> {
                        emitAction("next", 0)
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                        emitAction("toggle", 0)
                        return true
                    }
                }
                return super.onMediaButtonEvent(mediaButtonIntent)
            }
        })
        session = created
    }

    private fun updateVolumeRoute() {
        val current = session ?: return
        if (playbackActive && playing && screenOff && volumeSeekEnabled) {
            current.setPlaybackToRemote(volumeProvider)
        } else {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            current.setPlaybackToLocal(attrs)
        }
    }

    private fun emitAction(name: String, delta: Int) {
        val events = sink ?: return
        handler.post {
            events.success(
                mapOf(
                    "type" to "action",
                    "action" to name,
                    "delta" to delta,
                ),
            )
        }
    }

    private fun pushState() {
        val events = sink ?: return
        val payload = mapOf(
            "type" to "state",
            "battery" to battery,
            "charging" to charging,
            "pocket" to pocket,
            "faceDown" to faceDown,
            "screenOff" to screenOff,
            "externalDisplay" to externalDisplay(),
            "known" to known,
        )
        handler.post { events.success(payload) }
    }
}

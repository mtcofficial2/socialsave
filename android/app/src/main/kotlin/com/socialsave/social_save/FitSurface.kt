package com.socialsave.social_save

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.min

/**
 * Draws the decoder's picture into the encoder, fitted and padded.
 * Frames are stamped at a constant 30 fps so a 60 fps source drops frames
 * and a slower source holds a frame, without stretching.
 */
internal class FitSurface {
    private val lock = Object()
    private var available = false
    private var display = EGL14.EGL_NO_DISPLAY
    private var context = EGL14.EGL_NO_CONTEXT
    private var window = EGL14.EGL_NO_SURFACE
    private var textureId = 0
    private var program = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var decoderSurface: Surface? = null
    private var positions: FloatBuffer? = null
    private var coords: FloatBuffer? = null
    private var uTex = -1
    private var aPos = -1
    private var aTex = -1
    private var nextSlot = 0L
    private var haveFrame = false
    private var outW = 0
    private var outH = 0
    private val texMatrix = FloatArray(16)

    fun decoderInput(): Surface? = decoderSurface

    fun start(
        encoderSurface: Surface,
        codedW: Int,
        codedH: Int,
        dispW: Int,
        dispH: Int,
        rotation: Int,
        targetW: Int,
        targetH: Int,
    ): Boolean {
        outW = targetW
        outH = targetH
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return false
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] < 1) {
            return false
        }
        val config = configs[0] ?: return false
        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (context == EGL14.EGL_NO_CONTEXT) return false
        window = EGL14.eglCreateWindowSurface(display, config, encoderSurface, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == EGL14.EGL_NO_SURFACE) return false
        if (!EGL14.eglMakeCurrent(display, window, window, context)) return false
        program = buildProgram()
        if (program == 0) return false
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aTex = GLES20.glGetAttribLocation(program, "aTex")
        uTex = GLES20.glGetUniformLocation(program, "uTex")
        val sTex = GLES20.glGetUniformLocation(program, "sTex")
        GLES20.glUseProgram(program)
        if (sTex >= 0) GLES20.glUniform1i(sTex, 0)
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        val texture = SurfaceTexture(textureId)
        texture.setDefaultBufferSize(codedW.coerceAtLeast(2), codedH.coerceAtLeast(2))
        texture.setOnFrameAvailableListener {
            synchronized(lock) {
                available = true
                lock.notifyAll()
            }
        }
        surfaceTexture = texture
        decoderSurface = Surface(texture)
        positions = buffer(fittedQuad(dispW, dispH, targetW, targetH))
        coords = buffer(rotatedTex(rotation))
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDisable(GLES20.GL_BLEND)
        return aPos >= 0 && aTex >= 0
    }

    /** Shows this decoded frame, after emitting any 30 fps slots the previous one still owes. */
    fun accept(ptsUs: Long, drain: () -> Boolean): Boolean {
        if (!waitForFrame()) return false
        // A slot takes the frame nearest to it, not the last one before it.
        // Sources that are not exactly 60 fps (59.94, phone jitter) then
        // keep an even cadence instead of doubling and skipping frames.
        if (haveFrame && !emitUntil(ptsUs - STEP_US / 4, drain)) return false
        return try {
            surfaceTexture?.updateTexImage()
            haveFrame = true
            true
        } catch (e: Exception) {
            Log.w(TAG, "frame update failed", e)
            false
        }
    }

    /** Holds the last picture through the rest of the clip. */
    fun finish(durationUs: Long, drain: () -> Boolean): Boolean {
        if (!haveFrame) return false
        val covered = if (durationUs > 0) durationUs else nextSlot + STEP_US
        val end = slotEnd(covered)
        return emitUntil(end, drain)
    }

    fun release() {
        try { decoderSurface?.release() } catch (_: Exception) {}
        decoderSurface = null
        try { surfaceTexture?.release() } catch (_: Exception) {}
        surfaceTexture = null
        if (program != 0) {
            GLES20.glDeleteProgram(program)
            program = 0
        }
        if (textureId != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
            textureId = 0
        }
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        window = EGL14.EGL_NO_SURFACE
    }

    private fun emitUntil(limitUs: Long, drain: () -> Boolean): Boolean {
        while (nextSlot < limitUs) {
            if (!drain()) return false
            draw()
            EGLExt.eglPresentationTimeANDROID(display, window, nextSlot * 1_000L)
            if (!EGL14.eglSwapBuffers(display, window)) return false
            nextSlot += STEP_US
        }
        return true
    }

    private fun draw() {
        val pos = positions ?: return
        val tex = coords ?: return
        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        surfaceTexture?.getTransformMatrix(texMatrix)
        GLES20.glUniformMatrix4fv(uTex, 1, false, texMatrix, 0)
        pos.position(0)
        GLES20.glVertexAttribPointer(aPos, 4, GLES20.GL_FLOAT, false, 0, pos)
        GLES20.glEnableVertexAttribArray(aPos)
        tex.position(0)
        GLES20.glVertexAttribPointer(aTex, 4, GLES20.GL_FLOAT, false, 0, tex)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun waitForFrame(): Boolean {
        val deadline = SystemClock.elapsedRealtime() + 1_500L
        synchronized(lock) {
            while (!available) {
                val left = deadline - SystemClock.elapsedRealtime()
                if (left <= 0) return false
                try {
                    lock.wait(left)
                } catch (_: InterruptedException) {
                    return false
                }
            }
            available = false
        }
        return true
    }

    private fun buildProgram(): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, VERT)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FRAG)
        if (vs == 0 || fs == 0) return 0
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        if (ok[0] == 0) {
            Log.w(TAG, GLES20.glGetProgramInfoLog(p))
            GLES20.glDeleteProgram(p)
            return 0
        }
        return p
    }

    private fun compile(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.w(TAG, GLES20.glGetShaderInfoLog(shader))
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun buffer(values: FloatArray): FloatBuffer {
        val buf = ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        buf.put(values)
        buf.position(0)
        return buf
    }

    companion object {
        private const val TAG = "UploadPrep"
        private const val EGL_RECORDABLE_ANDROID = 0x3142
        private const val STEP_US = 1_000_000L / 30L

        private const val VERT = """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uTex;
            varying vec2 vTex;
            void main() {
              gl_Position = aPos;
              vTex = (uTex * aTex).xy;
            }
        """
        private const val FRAG = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES sTex;
            void main() {
              gl_FragColor = texture2D(sTex, vTex);
            }
        """

        private fun slotEnd(durationUs: Long): Long {
            val n = ((durationUs + STEP_US / 2) / STEP_US).coerceAtLeast(1)
            return n * STEP_US
        }

        /** Letterboxed quad in clip space. 1 means the picture fills that axis. */
        private fun fittedQuad(dispW: Int, dispH: Int, outW: Int, outH: Int): FloatArray {
            val fit = min(outW.toFloat() / dispW.coerceAtLeast(1), outH.toFloat() / dispH.coerceAtLeast(1))
            val nx = (dispW * fit / outW).coerceIn(0.01f, 1f)
            val ny = (dispH * fit / outH).coerceIn(0.01f, 1f)
            return floatArrayOf(
                -nx, -ny, 0f, 1f,
                nx, -ny, 0f, 1f,
                -nx, ny, 0f, 1f,
                nx, ny, 0f, 1f,
            )
        }

        /** Texture corners for a triangle strip, rotated about the center. */
        private fun rotatedTex(rotation: Int): FloatArray {
            val turns = when (((rotation % 360) + 360) % 360) {
                90 -> 1
                180 -> 2
                270 -> 3
                else -> 0
            }
            val base = arrayOf(
                0f to 0f,
                1f to 0f,
                0f to 1f,
                1f to 1f,
            )
            val out = FloatArray(16)
            for (i in base.indices) {
                var x = base[i].first - 0.5f
                var y = base[i].second - 0.5f
                repeat(turns) {
                    val nx = y
                    val ny = -x
                    x = nx
                    y = ny
                }
                out[i * 4] = x + 0.5f
                out[i * 4 + 1] = y + 0.5f
                out[i * 4 + 2] = 0f
                out[i * 4 + 3] = 1f
            }
            return out
        }
    }
}

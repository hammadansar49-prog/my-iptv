package com.theottdeals.theottdeals

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * Picture-in-Picture for the fullscreen player (player_screen.dart).
 *
 * Dart tells us whether the player currently wants auto-enter (video is
 * playing) and the video's display aspect; we keep the Activity's
 * [PictureInPictureParams] in step so Home (API 31+ auto-enter, or
 * onUserLeaveHint below that) and the in-player button both open a window
 * shaped like the video. Mode changes go back to Dart as
 * `changed {inPip, dismissed}`: the same player keeps running, nothing is
 * reopened.
 */
object PipBridge {
    private const val CHANNEL = "theottdeals/pip"

    // Android rejects anything outside 1:2.39 .. 2.39:1.
    private const val MAX_RATIO = 2.39

    private var channel: MethodChannel? = null
    var activity: MainActivity? = null

    /** The player wants to go PiP when the user leaves the app. */
    @Volatile private var autoEnter = false
    private var aspect = Rational(16, 9)

    fun attach(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isSupported" -> result.success(supported())
                    "configure" -> {
                        autoEnter = call.argument<Boolean>("autoEnter") ?: false
                        call.argument<Double>("aspect")?.let { aspect = rational(it) }
                        apply()
                        result.success(null)
                    }
                    "enter" -> {
                        call.argument<Double>("aspect")?.let { aspect = rational(it) }
                        result.success(enter())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("pip", e.toString(), null)
            }
        }
    }

    fun supported(): Boolean {
        val a = activity ?: return false
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            a.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun rational(value: Double): Rational {
        if (value.isNaN() || value <= 0.0) return Rational(16, 9)
        val clamped = value.coerceIn(1.0 / MAX_RATIO, MAX_RATIO)
        return Rational((clamped * 10000).roundToInt(), 10000)
    }

    private fun params(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val b = PictureInPictureParams.Builder().setAspectRatio(aspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(autoEnter)
            // The user pinch/drag-resizes the window; keep that smooth.
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    private fun apply() {
        val a = activity ?: return
        if (!supported()) return
        val p = params() ?: return
        try {
            a.setPictureInPictureParams(p)
        } catch (_: Exception) {
            // IllegalStateException on some ROMs when PiP is disabled for us.
        }
    }

    fun enter(): Boolean {
        val a = activity ?: return false
        if (!supported()) return false
        val p = params() ?: return false
        return try {
            a.enterPictureInPictureMode(p)
        } catch (_: Exception) {
            false
        }
    }

    /** Home pressed. API 31+ auto-enters from the params instead. */
    fun onUserLeaveHint() {
        if (autoEnter && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enter()
    }

    fun onModeChanged(inPip: Boolean, dismissed: Boolean) {
        channel?.invokeMethod("changed", mapOf("inPip" to inPip, "dismissed" to dismissed))
    }
}

package com.theottdeals.theottdeals

import android.annotation.SuppressLint
import android.content.Context
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The real per-device ANDROID_ID (Settings.Secure). device_info_plus's
 * `AndroidDeviceInfo.id` is Build.ID — the firmware build string, identical
 * on every phone of the same model and update — so it cannot tell two
 * devices apart for the free-trial / licence device binding.
 */
object DeviceIdBridge {
    private const val CHANNEL = "theottdeals/device"

    @SuppressLint("HardwareIds")
    fun attach(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "androidId") {
                    result.success(
                        Settings.Secure.getString(
                            context.contentResolver,
                            Settings.Secure.ANDROID_ID,
                        ),
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}

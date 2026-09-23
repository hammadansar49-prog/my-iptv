package com.theottdeals.theottdeals

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Runtime permissions, asked only from Dart after an in-app explanation
 * (notification onboarding, first download). Nothing is requested at launch.
 *
 * Kinds: "notifications" (POST_NOTIFICATIONS, Android 13+) and "media"
 * (READ_MEDIA_VIDEO on 13+, READ/WRITE_EXTERNAL_STORAGE below).
 * Answers: "granted" | "denied" | "permanentlyDenied" (the system will not
 * show its dialog again; only the app's settings page can change it).
 */
object PermissionBridge {
    private const val CHANNEL = "theottdeals/permissions"
    private const val PREFS = "permission_bridge"
    private const val REQ_NOTIFICATIONS = 7401
    private const val REQ_MEDIA = 7402

    private var appContext: Context? = null
    var activity: Activity? = null
    private val pending = mutableMapOf<Int, MethodChannel.Result>()

    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val kind = call.argument<String>("kind") ?: ""
                when (call.method) {
                    "status" -> result.success(status(kind))
                    "request" -> request(kind, result)
                    "openSettings" -> {
                        openSettings(kind)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun permissionsFor(kind: String): Array<String> = when (kind) {
        "notifications" ->
            if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS)
            else emptyArray()
        "media" -> when {
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
            Build.VERSION.SDK_INT >= 29 -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            else -> arrayOf(
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            )
        }
        else -> emptyArray()
    }

    private fun granted(context: Context, perms: Array<String>): Boolean =
        perms.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun notificationsEnabled(context: Context): Boolean {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.areNotificationsEnabled()
    }

    private fun status(kind: String): String {
        val context = activity ?: appContext ?: return "denied"
        val perms = permissionsFor(kind)
        val ok = granted(context, perms) &&
            (kind != "notifications" || notificationsEnabled(context))
        if (ok) return "granted"
        // Below 13 notifications have no runtime prompt: switched off in
        // system settings is the only way to be "not granted".
        if (perms.isEmpty()) return "permanentlyDenied"
        val a = activity
        val asked = prefs(context).getBoolean("asked_$kind", false)
        if (asked && a != null && perms.none { a.shouldShowRequestPermissionRationale(it) }) {
            return "permanentlyDenied"
        }
        return "denied"
    }

    private fun request(kind: String, result: MethodChannel.Result) {
        val a = activity
        val perms = permissionsFor(kind)
        val current = status(kind)
        if (current != "denied" || a == null || perms.isEmpty()) {
            result.success(current)
            return
        }
        val code = if (kind == "notifications") REQ_NOTIFICATIONS else REQ_MEDIA
        pending.remove(code)?.success(current)
        pending[code] = result
        prefs(a).edit().putBoolean("asked_$kind", true).apply()
        a.requestPermissions(perms, code)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onResult(requestCode: Int) {
        val kind = when (requestCode) {
            REQ_NOTIFICATIONS -> "notifications"
            REQ_MEDIA -> "media"
            else -> return
        }
        pending.remove(requestCode)?.success(status(kind))
    }

    private fun openSettings(kind: String) {
        val context = activity ?: appContext ?: return
        val pkg = context.packageName
        val intent = if (kind == "notifications" && Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, pkg)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
        }
        if (activity == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            try {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {}
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

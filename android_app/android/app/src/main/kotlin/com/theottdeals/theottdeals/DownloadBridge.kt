package com.theottdeals.theottdeals

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** MethodChannel glue between Dart's DownloadServiceBridge and [DownloadService]. */
object DownloadBridge {
    private const val CHANNEL = "theottdeals/download_service"
    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    var activity: MainActivity? = null

    fun attach(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            val context = appContext ?: activity?.applicationContext
            try {
                when (call.method) {
                    "requestPermission" -> {
                        activity?.requestNotificationPermission()
                        result.success(null)
                    }
                    "start", "update" -> {
                        if (context == null) { result.error("no_context", null, null); return@setMethodCallHandler }
                        val i = Intent(context, DownloadService::class.java).apply {
                            action = DownloadService.ACTION_SHOW
                            putExtra("id", call.argument<String>("id"))
                            putExtra("title", call.argument<String>("title"))
                            putExtra("percent", call.argument<Int>("percent") ?: -1)
                            putExtra("detail", call.argument<String>("detail"))
                            putExtra("paused", call.argument<Boolean>("paused") ?: false)
                        }
                        if (call.method == "start" && Build.VERSION.SDK_INT >= 26) {
                            context.startForegroundService(i)
                        } else {
                            context.startService(i)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        if (context != null) {
                            context.stopService(Intent(context, DownloadService::class.java))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("service", e.toString(), null)
            }
        }
    }

    fun setContext(context: Context) {
        appContext = context.applicationContext
    }

    /** Notification button → Dart DownloadManager. */
    fun dispatch(action: String, id: String) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("action", mapOf("action" to action, "id" to id))
        }
    }
}

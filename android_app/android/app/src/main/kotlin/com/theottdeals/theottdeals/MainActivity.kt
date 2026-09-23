package com.theottdeals.theottdeals

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Uses ONE process-wide cached Flutter engine instead of an Activity-owned
 * one. When the user swipes the app away from recents the Activity is
 * destroyed, but the engine (and the Dart DownloadManager running in it)
 * lives on as long as [DownloadService] keeps the process in the foreground.
 * Reopening the app re-attaches to the same engine, so the UI shows the
 * exact live download state — there is never a second downloader.
 */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        DownloadBridge.setContext(context)
        DownloadBridge.attach(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    // The engine outlives this Activity; never tear it down with it.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        DownloadBridge.activity = this
    }

    override fun onDestroy() {
        if (DownloadBridge.activity === this) DownloadBridge.activity = null
        super.onDestroy()
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
        }
    }

    companion object {
        const val ENGINE_ID = "main_engine"
    }
}

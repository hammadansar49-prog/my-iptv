package com.theottdeals.theottdeals

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

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
        PipBridge.attach(engine)
        PermissionBridge.attach(engine, context)
        GalleryBridge.attach(engine, context)
        // Dart pulls a pending announcement-notification tap on start/resume.
        MethodChannel(engine.dartExecutor.binaryMessenger, ANNOUNCEMENT_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "takePendingTap") {
                    val v = pendingAnnouncementTap
                    pendingAnnouncementTap = null
                    result.success(v)
                } else {
                    result.notImplemented()
                }
            }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super: the (possibly already running) engine may ask for it
        // as soon as it attaches.
        captureAnnouncementTap(intent)
        PipBridge.activity = this
        PermissionBridge.activity = this
        super.onCreate(savedInstanceState)
        AnnouncementNotifier.schedule(this)
        // No permission prompt at launch: notifications are asked for from
        // the in-app onboarding screen, media access at the first download.
    }

    // singleTop: a notification tap on a running app lands here, then
    // onResume, where Dart pulls it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureAnnouncementTap(intent)
    }

    private fun captureAnnouncementTap(i: Intent?) {
        if (i?.hasExtra(AnnouncementNotifier.EXTRA_TAP) != true) return
        pendingAnnouncementTap = i.getLongExtra(AnnouncementNotifier.EXTRA_TAP, 0L)
        i.removeExtra(AnnouncementNotifier.EXTRA_TAP) // not again on recreate
    }

    // The engine outlives this Activity; never tear it down with it.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        DownloadBridge.activity = this
        PipBridge.activity = this
        PermissionBridge.activity = this
        AnnouncementNotifier.appVisible = true
    }

    override fun onPause() {
        AnnouncementNotifier.appVisible = false
        super.onPause()
    }

    override fun onDestroy() {
        if (DownloadBridge.activity === this) DownloadBridge.activity = null
        if (PipBridge.activity === this) PipBridge.activity = null
        if (PermissionBridge.activity === this) PermissionBridge.activity = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        PermissionBridge.onResult(requestCode)
    }

    // Home while a video plays (below API 31; 31+ auto-enters from the params).
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        PipBridge.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // Leaving PiP while the Activity is no longer started means the user
        // closed the window (X / swipe away) rather than expanding it.
        val dismissed = !isInPictureInPictureMode &&
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        PipBridge.onModeChanged(isInPictureInPictureMode, dismissed)
    }

    companion object {
        const val ENGINE_ID = "main_engine"
        const val ANNOUNCEMENT_CHANNEL = "theottdeals/announcements"
        @Volatile var pendingAnnouncementTap: Long? = null
    }
}

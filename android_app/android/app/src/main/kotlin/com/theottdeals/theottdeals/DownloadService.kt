package com.theottdeals.theottdeals

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service (type dataSync) that keeps the process alive while the
 * Dart DownloadManager downloads, and shows the ongoing progress
 * notification with Pause/Resume and Cancel. It does no networking itself;
 * button taps are forwarded to Dart via [DownloadBridge], so the in-app UI
 * and the notification always reflect the same single DownloadManager.
 */
class DownloadService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentId: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        DownloadBridge.setContext(this)
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE, ACTION_RESUME, ACTION_CANCEL -> {
                val id = intent.getStringExtra("id") ?: currentId
                val a = when (intent.action) {
                    ACTION_PAUSE -> "pause"
                    ACTION_RESUME -> "resume"
                    else -> "cancel"
                }
                DownloadBridge.dispatch(a, id)
                return START_NOT_STICKY
            }
        }
        val id = intent?.getStringExtra("id") ?: currentId
        currentId = id
        val notification = build(
            id,
            intent?.getStringExtra("title") ?: "Downloading",
            intent?.getIntExtra("percent", -1) ?: -1,
            intent?.getStringExtra("detail") ?: "",
            intent?.getBooleanExtra("paused", false) ?: false,
        )
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        // Not sticky: if the process dies, Dart re-queues on the next launch.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15+ dataSync time limit reached: pause cleanly.
        DownloadBridge.dispatch("pause", currentId)
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "theottdeals:download").apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                ch.description = "Download progress"
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun actionIntent(action: String, id: String, req: Int): PendingIntent {
        val i = Intent(this, DownloadService::class.java).setAction(action).putExtra("id", id)
        return PendingIntent.getService(
            this, req, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    @Suppress("DEPRECATION")
    private fun build(id: String, title: String, percent: Int, detail: String, paused: Boolean): Notification {
        val b = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        if (launch != null) {
            b.setContentIntent(
                PendingIntent.getActivity(
                    this, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        }
        val text = if (percent >= 0) "$percent% · $detail" else detail
        b.setSmallIcon(if (paused) android.R.drawable.ic_media_pause else android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
        if (percent >= 0) {
            b.setProgress(100, percent, false)
        } else if (!paused) {
            b.setProgress(0, 0, true)
        }

        if (paused) {
            b.addAction(Notification.Action.Builder(null, "Resume", actionIntent(ACTION_RESUME, id, 2)).build())
        } else {
            b.addAction(Notification.Action.Builder(null, "Pause", actionIntent(ACTION_PAUSE, id, 1)).build())
        }
        b.addAction(Notification.Action.Builder(null, "Cancel", actionIntent(ACTION_CANCEL, id, 3)).build())
        if (Build.VERSION.SDK_INT >= 31) {
            b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return b.build()
    }

    companion object {
        const val CHANNEL_ID = "downloads"
        const val NOTIF_ID = 4201
        const val ACTION_SHOW = "com.theottdeals.download.SHOW"
        const val ACTION_PAUSE = "com.theottdeals.download.PAUSE"
        const val ACTION_RESUME = "com.theottdeals.download.RESUME"
        const val ACTION_CANCEL = "com.theottdeals.download.CANCEL"
    }
}

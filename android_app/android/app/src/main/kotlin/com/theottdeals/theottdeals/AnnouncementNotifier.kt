package com.theottdeals.theottdeals

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Posts the "MY IPTV" system notification for an admin announcement while the
 * app is closed or backgrounded. Shared by [AnnouncementWorker] (poll) and
 * [AnnouncementPushReceiver] (FCM data message) so both obey one dedupe rule:
 * only notify when created_at is newer than BOTH what the user dismissed
 * in-app (Dart LocalStore `lastSeenAnnouncementAt`) and what was already
 * notified (`lastNotifiedAnnouncementAt`, kept here natively).
 *
 * Deliberately pure Kotlin: no Flutter engine is started in the background,
 * so a poll never keeps the process (or the cached engine) alive.
 */
object AnnouncementNotifier {
    // v2: a channel's sound is fixed once created, so the chime needs a new id.
    const val CHANNEL_ID = "announcements_v2"
    private const val OLD_CHANNEL_ID = "announcements"
    const val EXTRA_TAP = "announcement_tap_created_at"
    private const val NOTIFICATION_ID = 7310
    private const val PREFS = "announcement_notifier"
    private const val KEY_NOTIFIED = "lastNotifiedAnnouncementAt"
    private const val WORK_NAME = "announcement_poll"

    /** Must match Dart `Licensing.rtdbUrl` default. */
    const val RTDB_URL = "https://theottdeals-reviews-default-rtdb.firebaseio.com"

    /** True while MainActivity is on screen: the live SSE popup handles it then. */
    @Volatile var appVisible = false

    /** 15 min is WorkManager's floor; KEEP so each launch doesn't reset the period. */
    fun schedule(context: Context) {
        val req = PeriodicWorkRequestBuilder<AnnouncementWorker>(15, TimeUnit.MINUTES)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            )
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, req)
    }

    fun maybeNotify(context: Context, rawText: String?, createdAt: Long?, expiresAt: Long?) {
        val text = rawText?.trim().orEmpty()
        // No created_at = no identity to dedupe on; the in-app popup still shows it.
        if (text.isEmpty() || createdAt == null || createdAt <= 0) return
        if (expiresAt != null && expiresAt > 0 && expiresAt < System.currentTimeMillis()) return
        if (appVisible) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val notified = prefs.getLong(KEY_NOTIFIED, 0L)
        if (createdAt <= notified || createdAt <= readSeenInApp(context)) return

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val sound = Uri.parse("android.resource://${context.packageName}/${R.raw.iptv_chime}")
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.deleteNotificationChannel(OLD_CHANNEL_ID)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Announcements", NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(
                        sound,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    enableVibration(true)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
            )
        }
        // singleTop activity: an existing instance gets onNewIntent, not a copy.
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_TAP, createdAt)
        }
        val pi = PendingIntent.getActivity(
            context, NOTIFICATION_ID, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_notify) // white glyph: status bar tints it; a full-colour icon renders as a blank square
            .setColor(0xFF905BF6.toInt())
            .setContentTitle("MY IPTV")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setSound(sound) // pre-Android 8; the channel's sound after
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        try {
            nm.notify(NOTIFICATION_ID, n)
        } catch (_: SecurityException) {
            return // POST_NOTIFICATIONS denied: don't mark notified.
        }
        prefs.edit().putLong(KEY_NOTIFIED, createdAt).apply()
    }

    /**
     * Dart's LocalStore is `store.json` in path_provider's application support
     * dir, which on Android is [Context.getFilesDir].
     */
    private fun readSeenInApp(context: Context): Long = try {
        val f = File(context.filesDir, "store.json")
        if (!f.exists()) 0L else JSONObject(f.readText()).optDouble("lastSeenAnnouncementAt", 0.0).toLong()
    } catch (_: Exception) {
        0L
    }
}

/** Periodic poll: works with no server at all. */
class AnnouncementWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        return try {
            val conn = URL("${AnnouncementNotifier.RTDB_URL}/iptv/announcement.json")
                .openConnection() as HttpURLConnection
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            val body = try {
                if (conn.responseCode != 200) return Result.success()
                conn.inputStream.bufferedReader().use { it.readText() }
            } finally {
                conn.disconnect()
            }
            val t = body.trim()
            if (!t.startsWith("{")) return Result.success() // "null" = no announcement
            val o = JSONObject(t)
            AnnouncementNotifier.maybeNotify(
                applicationContext,
                o.optString("text", ""),
                o.optDouble("created_at", 0.0).toLong(),
                o.optDouble("expires_at", 0.0).toLong(),
            )
            Result.success()
        } catch (_: Exception) {
            // Next period will try again; retry backoff would only add wakeups.
            Result.success()
        }
    }
}

/**
 * FCM data messages ({type: "announcement", text, created_at, expires_at}),
 * received alongside firebase_messaging's own receiver. Messages carrying a
 * `notification` payload are drawn by the FCM SDK itself, so they're skipped
 * here. Never fires until google-services.json is added.
 */
class AnnouncementPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val x = intent.extras ?: return
        if (x.getString("type") != "announcement") return
        if (x.containsKey("gcm.notification.body") || x.containsKey("gcm.n.body")) return
        AnnouncementNotifier.maybeNotify(
            context,
            x.getString("text"),
            x.getString("created_at")?.toDoubleOrNull()?.toLong(),
            x.getString("expires_at")?.toDoubleOrNull()?.toLong(),
        )
    }
}

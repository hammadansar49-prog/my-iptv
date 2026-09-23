package com.theottdeals.theottdeals

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Publishes a FINISHED download (never a .part) to the phone's Gallery under
 * Movies/MY IPTV, then deletes the app-private copy so the video is stored
 * once. Returns the public file path, which the Downloads list plays from.
 */
object GalleryBridge {
    private const val CHANNEL = "theottdeals/gallery"
    private const val FOLDER = "MY IPTV"

    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())

    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val ctx = appContext
                if (ctx == null) {
                    result.error("no_context", null, null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "publishVideo" -> {
                        val path = call.argument<String>("path") ?: ""
                        val name = call.argument<String>("displayName") ?: File(path).name
                        val title = call.argument<String>("title") ?: name
                        val mime = call.argument<String>("mime") ?: "video/mp4"
                        // Multi-GB copy: never on the main thread.
                        Thread {
                            try {
                                val out = publish(ctx, File(path), name, title, mime)
                                main.post { result.success(out) }
                            } catch (e: Exception) {
                                main.post { result.error("publish", e.toString(), null) }
                            }
                        }.start()
                    }
                    "deleteVideo" -> {
                        val path = call.argument<String>("path") ?: ""
                        Thread {
                            val ok = delete(ctx, path)
                            main.post { result.success(ok) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun publish(ctx: Context, src: File, name: String, title: String, mime: String): String {
        require(src.exists()) { "missing ${src.path}" }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            publishScoped(ctx, src, name, title, mime)
        } else {
            publishLegacy(ctx, src, name, mime)
        }
    }

    private fun publishScoped(ctx: Context, src: File, name: String, title: String, mime: String): String {
        val resolver = ctx.contentResolver
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.TITLE, title)
            put(MediaStore.Video.Media.MIME_TYPE, mime)
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/$FOLDER")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: error("MediaStore insert failed")
        try {
            val out = resolver.openOutputStream(uri) ?: error("MediaStore stream unavailable")
            out.use { o -> FileInputStream(src).use { it.copyTo(o, 1 shl 20) } }
            val done = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
        }
        @Suppress("DEPRECATION")
        val path = resolver.query(uri, arrayOf(MediaStore.Video.Media.DATA), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        if (path.isNullOrEmpty() || !File(path).canRead()) {
            // Not addressable by path here: keep the private copy playable.
            return src.path
        }
        src.delete()
        return path
    }

    @Suppress("DEPRECATION")
    private fun publishLegacy(ctx: Context, src: File, name: String, mime: String): String {
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), FOLDER)
        if (!dir.exists() && !dir.mkdirs()) error("cannot create ${dir.path}")
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var target = File(dir, name)
        var n = 2
        while (target.exists()) {
            target = File(dir, "$base ($n)$ext")
            n++
        }
        try {
            FileInputStream(src).use { input ->
                FileOutputStream(target).use { input.copyTo(it, 1 shl 20) }
            }
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        src.delete()
        MediaScannerConnection.scanFile(ctx, arrayOf(target.path), arrayOf(mime), null)
        return target.path
    }

    private fun delete(ctx: Context, path: String): Boolean {
        try {
            @Suppress("DEPRECATION")
            val rows = ctx.contentResolver.delete(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                "${MediaStore.Video.Media.DATA}=?",
                arrayOf(path),
            )
            if (rows > 0) return true
        } catch (_: Exception) {}
        val f = File(path)
        return try { !f.exists() || f.delete() } catch (_: Exception) { false }
    }
}

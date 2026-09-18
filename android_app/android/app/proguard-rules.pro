# Flutter-specific ProGuard rules for the IPTV Player app.

# Keep Flutter engine classes
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# media_kit / libmpv — JNI bindings loaded at runtime
-keep class com.alexmerzinger.** { *; }
-keep class mpv.** { *; }

# flutter_local_notifications
-keep class com.dexterous.** { *; }

# flutter_secure_storage
-keep class com.itnomals.** { *; }

# device_info_plus
-keep class dev.fluttercommunity.plus.deviceinfo.** { *; }

# url_launcher
-keep class io.flutter.plugins.urllauncher.** { *; }

# file_picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# screen_brightness
-keep class com.therankly.screenbrightness.** { *; }

# wakelock_plus
-keep class dev.fluttercommunity.plus.wakelock.** { *; }

# Keep model classes used in JSON serialization
-keep class com.veo.iptvplayer.** { *; }

# Suppress R8 warnings for Google Play Core classes referenced by Flutter
# engine but not actually used (not a Play Store deferred-components app)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

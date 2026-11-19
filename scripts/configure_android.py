import os

pub_cache = os.environ.get("PUB_CACHE", os.path.expanduser("~/.pub-cache"))
if os.path.exists(pub_cache):
    for root, _, files in os.walk(pub_cache):
        for fn in files:
            if fn in ("build.gradle", "build.gradle.kts"):
                p = os.path.join(root, fn)
                try:
                    content = open(p, "r", encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "dev.flutter.flutter-gradle-plugin" in content:
                    lines = content.splitlines()
                    changed = False
                    idx_flutter = next((i for i, l in enumerate(lines) if "apply plugin:" in l and "dev.flutter.flutter-gradle-plugin" in l), -1)
                    idx_android = next((i for i, l in enumerate(lines) if "apply plugin:" in l and ("com.android.library" in l or "com.android.application" in l)), -1)
                    if idx_flutter != -1 and idx_android != -1 and idx_flutter < idx_android:
                        lines[idx_flutter], lines[idx_android] = lines[idx_android], lines[idx_flutter]
                        changed = True
                    in_plugins = False
                    p_start = -1
                    p_end = -1
                    for i, l in enumerate(lines):
                        s = l.strip()
                        if s.startswith("plugins") and "{" in s:
                            in_plugins = True
                            p_start = i
                        elif in_plugins and s == "}":
                            p_end = i
                            break
                    if p_start != -1 and p_end != -1:
                        block = lines[p_start + 1:p_end]
                        android_lines = [l for l in block if "com.android.library" in l or "com.android.application" in l]
                        other_lines = [l for l in block if "com.android.library" not in l and "com.android.application" not in l]
                        if android_lines and (android_lines + other_lines) != block:
                            lines = lines[:p_start + 1] + android_lines + other_lines + lines[p_end:]
                            changed = True
                    if changed:
                        open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
                        print(f"Fixed plugin order in: {p}")

os.makedirs("android/app/src/main/res/xml", exist_ok=True)
with open("android/app/src/main/res/xml/file_paths.xml", "w", encoding="utf-8") as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<paths>
    <files-path name="app_files" path="." />
    <cache-path name="app_cache" path="." />
    <external-path name="external_files" path="." />
</paths>
''')

if os.path.exists("google-services.json"):
    with open("google-services.json", "rb") as src, open("android/app/google-services.json", "wb") as dst:
        dst.write(src.read())
if not os.path.exists("android/app/google-services.json"):
    raise SystemExit("ERROR: google-services.json missing!")

kt_dir = "android/app/src/main/kotlin/com/universal/universal_messenger"
os.makedirs(kt_dir, exist_ok=True)
with open(os.path.join(kt_dir, "MainActivity.kt"), "w", encoding="utf-8") as f:
    f.write('''package com.universal.universal_messenger

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.universal.messenger/icon"
    private var isCallActive = false
    private var suppressPipOnce = false
    private var activeRingtone: Ringtone? = null
    private var mediaPlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setCallActive" -> {
                    isCallActive = call.argument<Boolean>("active") ?: false
                    result.success(true)
                }
                "suppressPipOnce" -> {
                    suppressPipOnce = true
                    result.success(true)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                            }
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "isNetworkConnected" -> {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                    val connected = caps != null && (
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                    )
                    result.success(connected)
                }
                "playRingtone" -> {
                    stopRingtoneInternal()
                    try {
                        val path = call.argument<String>("path")
                        val uri = if (!path.isNullOrEmpty() && File(path).exists()) Uri.fromFile(File(path)) else RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                        activeRingtone = RingtoneManager.getRingtone(applicationContext, uri)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) activeRingtone?.isLooping = true
                        activeRingtone?.play()
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "stopRingtone" -> {
                    stopRingtoneInternal()
                    result.success(true)
                }
                "playMessageSound" -> {
                    try {
                        mediaPlayer?.release()
                        val path = call.argument<String>("path")
                        val uri = if (!path.isNullOrEmpty() && File(path).exists()) Uri.fromFile(File(path)) else RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                        mediaPlayer = MediaPlayer().apply {
                            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                            setDataSource(applicationContext, uri)
                            prepare()
                            start()
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "getContentUri" -> {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        result.success(FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path)).toString())
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
                "installApk" -> {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.success("PERMISSION_REQUIRED")
                        } else {
                            val apkUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success("STARTED")
                        }
                    } catch (e: Exception) {
                        result.error("INSTALL_ERR", e.message, null)
                    }
                }
                else -> result.success(null)
            }
        }
    }

    private fun stopRingtoneInternal() {
        try {
            activeRingtone?.stop()
            activeRingtone = null
        } catch (_: Exception) {}
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (suppressPipOnce) {
            suppressPipOnce = false
            return
        }
        if (isCallActive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16)).build())
            } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        stopRingtoneInternal()
        mediaPlayer?.release()
        super.onDestroy()
    }
}
''')

if os.path.exists("android/settings.gradle.kts"):
    txt = open("android/settings.gradle.kts", "r", encoding="utf-8").read()
    if "com.google.gms.google-services" not in txt:
        txt = txt.replace(
            'id("com.android.application")',
            'id("com.google.gms.google-services") version "4.4.2" apply false\n    id("com.android.application")',
            1
        )
        open("android/settings.gradle.kts", "w", encoding="utf-8").write(txt)
elif os.path.exists("android/settings.gradle"):
    txt = open("android/settings.gradle", "r", encoding="utf-8").read()
    if "com.google.gms.google-services" not in txt:
        txt = txt.replace(
            'id "com.android.application"',
            'id "com.google.gms.google-services" version "4.4.2" apply false\n    id "com.android.application"',
            1
        )
        open("android/settings.gradle", "w", encoding="utf-8").write(txt)

bg = "android/app/build.gradle.kts"
if os.path.exists(bg):
    lines = open(bg, "r", encoding="utf-8").read().splitlines()
    out = []
    in_plugins = False
    for l in lines:
        s = l.strip()
        if s.startswith("plugins") and "{" in s:
            in_plugins = True
            out.append(l)
            out.append('    id("com.android.application")')
            out.append('    id("kotlin-android")')
            out.append('    id("dev.flutter.flutter-gradle-plugin")')
            out.append('    id("com.google.gms.google-services")')
            continue
        if in_plugins:
            if s == "}":
                in_plugins = False
                out.append(l)
            continue
        if "minSdk =" in l or "minSdkVersion" in l:
            out.append("        minSdk = 23")
            out.append("        multiDexEnabled = true")
            continue
        if "targetSdk =" in l or "targetSdkVersion" in l:
            out.append("        targetSdk = 34")
            continue
        out.append(l)
        if "sourceCompatibility" in l:
            out.append("        isCoreLibraryDesugaringEnabled = true")
    out.append("")
    out.append("dependencies {")
    out.append('    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")')
    out.append("}")
    open(bg, "w", encoding="utf-8").write("\n".join(out) + "\n")

mp = "android/app/src/main/AndroidManifest.xml"
if os.path.exists(mp):
    m = open(mp, "r", encoding="utf-8").read()
    if "xmlns:tools" not in m:
        m = m.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
    perms = [
        "INTERNET", "ACCESS_NETWORK_STATE", "POST_NOTIFICATIONS",
        "VIBRATE", "WAKE_LOCK", "RECEIVE_BOOT_COMPLETED",
        "USE_FULL_SCREEN_INTENT", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
        "SYSTEM_ALERT_WINDOW", "CAMERA", "RECORD_AUDIO",
        "MODIFY_AUDIO_SETTINGS", "BLUETOOTH", "BLUETOOTH_CONNECT",
        "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PROJECTION",
        "FOREGROUND_SERVICE_CAMERA", "FOREGROUND_SERVICE_MICROPHONE",
        "REQUEST_INSTALL_PACKAGES"
    ]
    pt = ""
    for p in perms:
        if f"android.permission.{p}" not in m:
            pt += f'    <uses-permission android:name="android.permission.{p}"/>\n'
    if pt:
        m = m.replace("<application", pt + "    <application", 1)

    m = m.replace(
        'android:name=".MainActivity"',
        'android:name=".MainActivity"\n            android:supportsPictureInPicture="true"\n            android:resizeableActivity="true"\n            android:showWhenLocked="true"\n            android:turnScreenOn="true"',
        1
    )

    ex = (
        '        <service android:name="im.zego.zegoexpress.internal.ZegoScreenCaptureService" android:enabled="true" android:exported="false" android:foregroundServiceType="mediaProjection" tools:node="merge" />\n'
        '        <provider android:name="androidx.core.content.FileProvider" android:authorities="${applicationId}.fileprovider" android:exported="false" android:grantUriPermissions="true">\n'
        '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/file_paths" />\n'
        '        </provider>\n'
        '        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="fcm_msg_all_v1" />\n'
        '    </application>'
    )
    if "ZegoScreenCaptureService" not in m:
        m = m.replace("</application>", ex, 1)
    open(mp, "w", encoding="utf-8").write(m)

print("ANDROID_CONFIG_SUCCESS")

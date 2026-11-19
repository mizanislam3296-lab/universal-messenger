import json, os, re
from urllib.parse import unquote, urlparse

def fix_gradle(p):
    try:
        c = open(p, encoding="utf-8", errors="ignore").read()
    except Exception:
        return
    kts = p.endswith(".kts")
    orig = c
    mp = re.search(r"(^|\n)([ \t]*plugins\s*\{)([\s\S]*?)(\n[ \t]*\})", c)
    if mp:
        lines = [l for l in mp.group(3).splitlines() if l.strip()]
        if any(k in l for l in lines for k in ("com.android.", "flutter-gradle-plugin", "kotlin")):
            a = [l for l in lines if "com.android.library" in l or "com.android.application" in l]
            if not a:
                a = ['    id("com.android.library")' if kts else "    id 'com.android.library'"]
            o = [l for l in lines if "com.android.library" not in l and "com.android.application" not in l]
            c = c[:mp.start(2)] + mp.group(2) + "\n" + "\n".join(a + o) + mp.group(4) + c[mp.end(4):]
    elif re.search(r"(flutter-gradle-plugin|flutter\.gradle|\bandroid\s*\{)", c):
        lines = c.splitlines()
        ar = re.compile(r'^\s*apply[\s(]+plugin\s*[:=]\s*["\']com\.android\.(library|application)["\']')
        tr = re.compile(r'^\s*(apply[\s(]+(plugin|from)\s*[:=]|android\s*\{)')
        al = [l for l in lines if ar.match(l)]
        rem = [l for l in lines if not ar.match(l)]
        idx = next((i for i, l in enumerate(rem) if tr.match(l)), -1)
        if idx != -1:
            if not al:
                al = ['apply(plugin = "com.android.library")' if kts else "apply plugin: 'com.android.library'"]
            c = "\n".join(rem[:idx] + al + rem[idx:]) + "\n"
    if re.search(r"\bandroid\s*\{", c) and "namespace" not in c:
        mf = os.path.join(os.path.dirname(p), "src/main/AndroidManifest.xml")
        if os.path.exists(mf):
            m = re.search(r'package\s*=\s*["\']([^"\']+)["\']', open(mf, encoding="utf-8", errors="ignore").read())
            if m:
                ns = f'    namespace = "{m.group(1)}"' if kts else f'    namespace "{m.group(1)}"'
                c = re.sub(r"\bandroid\s*\{", f"android {{\n{ns}", c, count=1)
    if c != orig:
        open(p, "w", encoding="utf-8").write(c)

dirs = {os.environ.get("PUB_CACHE", ""), os.path.expanduser("~/.pub-cache"), "/root/.pub-cache", "/home/runner/.pub-cache"}
if os.path.exists(".dart_tool/package_config.json"):
    for pkg in json.load(open(".dart_tool/package_config.json", encoding="utf-8")).get("packages", []):
        u = pkg.get("rootUri", "")
        lp = unquote(urlparse(u).path) if u.startswith("file://") else os.path.abspath(os.path.join(".dart_tool", u))
        if os.path.isdir(lp):
            dirs.add(lp)
for d in dirs:
    if d and os.path.exists(d):
        for r, _, fs in os.walk(d):
            for fn in fs:
                if fn in ("build.gradle", "build.gradle.kts"):
                    fix_gradle(os.path.join(r, fn))

os.makedirs("android/app/src/main/res/xml", exist_ok=True)
open("android/app/src/main/res/xml/file_paths.xml", "w").write(
    '<?xml version="1.0" encoding="utf-8"?><paths><files-path name="f" path="."/><cache-path name="c" path="."/><external-path name="e" path="."/></paths>'
)
if os.path.exists("google-services.json"):
    open("android/app/google-services.json", "wb").write(open("google-services.json", "rb").read())
assert os.path.exists("android/app/google-services.json"), "google-services.json missing"

kt_dir = "android/app/src/main/kotlin/com/universal/universal_messenger"
os.makedirs(kt_dir, exist_ok=True)
open(os.path.join(kt_dir, "MainActivity.kt"), "w", encoding="utf-8").write('''package com.universal.universal_messenger

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.media.*
import android.net.*
import android.os.*
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
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setCallActive" -> { isCallActive = call.argument<Boolean>("active") ?: false; result.success(true) }
                "suppressPipOnce" -> { suppressPipOnce = true; result.success(true) }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                            }
                        }
                        result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }
                "isNetworkConnected" -> {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                    result.success(caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)))
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
                    } catch (_: Exception) { result.success(false) }
                }
                "stopRingtone" -> { stopRingtoneInternal(); result.success(true) }
                "playMessageSound" -> {
                    try {
                        mediaPlayer?.release()
                        val path = call.argument<String>("path")
                        val uri = if (!path.isNullOrEmpty() && File(path).exists()) Uri.fromFile(File(path)) else RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                        mediaPlayer = MediaPlayer().apply {
                            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                            setDataSource(applicationContext, uri); prepare(); start()
                        }
                        result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }
                "getContentUri" -> {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        result.success(FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path)).toString())
                    } catch (_: Exception) { result.success(null) }
                }
                "installApk" -> {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.success("PERMISSION_REQUIRED")
                        } else {
                            val apkUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                            result.success("STARTED")
                        }
                    } catch (e: Exception) { result.error("INSTALL_ERR", e.message, null) }
                }
                else -> result.success(null)
            }
        }
    }

    private fun stopRingtoneInternal() {
        try { activeRingtone?.stop(); activeRingtone = null } catch (_: Exception) {}
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (suppressPipOnce) { suppressPipOnce = false; return }
        if (isCallActive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16)).build()) } catch (_: Exception) {}
        }
    }

    override fun onDestroy() { stopRingtoneInternal(); mediaPlayer?.release(); super.onDestroy() }
}
''')

for sg, gms, hook in [
    ("android/settings.gradle.kts", 'id("com.android.application")', 'id("com.google.gms.google-services") version "4.4.2" apply false\n    id("com.android.application")'),
    ("android/settings.gradle", 'id "com.android.application"', 'id "com.google.gms.google-services" version "4.4.2" apply false\n    id "com.android.application"'),
]:
    if os.path.exists(sg):
        t = open(sg, encoding="utf-8").read()
        if "google-services" not in t:
            t = t.replace(gms, hook, 1)
        if "beforeProject" not in t:
            t += '\ngradle.beforeProject { p -> if (p.path != ":" && p.path != ":app" && p.buildFile.exists() && p.buildFile.text.contains("android")) p.pluginManager.apply("com.android.library") }\n' if sg.endswith(".gradle") else '\ngradle.beforeProject {\n    if (path != ":" && path != ":app" && buildFile.exists() && buildFile.readText().contains("android")) pluginManager.apply("com.android.library")\n}\n'
        open(sg, "w", encoding="utf-8").write(t)

bg = "android/app/build.gradle.kts"
if os.path.exists(bg):
    out, inp = [], False
    for l in open(bg, encoding="utf-8").read().splitlines():
        s = l.strip()
        if s.startswith("plugins") and "{" in s:
            inp = True
            out += [l, '    id("com.android.application")', '    id("kotlin-android")', '    id("dev.flutter.flutter-gradle-plugin")', '    id("com.google.gms.google-services")']
            continue
        if inp:
            if s == "}": inp = False; out.append(l)
            continue
        if "minSdk =" in l or "minSdkVersion" in l:
            out += ["        minSdk = 23", "        multiDexEnabled = true"]; continue
        if "targetSdk =" in l or "targetSdkVersion" in l:
            out.append("        targetSdk = 34"); continue
        out.append(l)
        if "sourceCompatibility" in l:
            out.append("        isCoreLibraryDesugaringEnabled = true")
    out += ["", "dependencies {", '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")', "}"]
    open(bg, "w", encoding="utf-8").write("\n".join(out) + "\n")

mp = "android/app/src/main/AndroidManifest.xml"
if os.path.exists(mp):
    m = open(mp, encoding="utf-8").read()
    if "xmlns:tools" not in m:
        m = m.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
    perms = ["INTERNET","ACCESS_NETWORK_STATE","POST_NOTIFICATIONS","VIBRATE","WAKE_LOCK","RECEIVE_BOOT_COMPLETED","USE_FULL_SCREEN_INTENT","REQUEST_IGNORE_BATTERY_OPTIMIZATIONS","SYSTEM_ALERT_WINDOW","CAMERA","RECORD_AUDIO","MODIFY_AUDIO_SETTINGS","BLUETOOTH","BLUETOOTH_CONNECT","FOREGROUND_SERVICE","FOREGROUND_SERVICE_MEDIA_PROJECTION","FOREGROUND_SERVICE_CAMERA","FOREGROUND_SERVICE_MICROPHONE","REQUEST_INSTALL_PACKAGES"]
    pt = "".join(f'    <uses-permission android:name="android.permission.{p}"/>\n' for p in perms if f"android.permission.{p}" not in m)
    if pt:
        m = m.replace("<application", pt + "    <application", 1)
    m = m.replace('android:name=".MainActivity"', 'android:name=".MainActivity" android:supportsPictureInPicture="true" android:resizeableActivity="true" android:showWhenLocked="true" android:turnScreenOn="true"', 1)
    ex = '        <service android:name="im.zego.zegoexpress.internal.ZegoScreenCaptureService" android:enabled="true" android:exported="false" android:foregroundServiceType="mediaProjection" tools:node="merge" />\n        <provider android:name="androidx.core.content.FileProvider" android:authorities="${applicationId}.fileprovider" android:exported="false" android:grantUriPermissions="true"><meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/file_paths" /></provider>\n        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="fcm_msg_all_v1" />\n    </application>'
    if "ZegoScreenCaptureService" not in m:
        m = m.replace("</application>", ex, 1)
    open(mp, "w", encoding="utf-8").write(m)
print("ANDROID_CONFIG_SUCCESS")

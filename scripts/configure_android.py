#!/usr/bin/env python3
"""
Configure freshly generated Android project and patch cached Flutter plugins
for AGP 9+ / modern Flutter compatibility on CI.
"""

import json
import os
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path.cwd()
ANDROID_DIR = ROOT / "android"
APP_DIR = ANDROID_DIR / "app"
MAIN_DIR = APP_DIR / "src" / "main"
MIN_COMPILE_SDK = 34


def log(msg: str) -> None:
    print(f"[configure_android] {msg}")


def collect_plugin_android_dirs() -> list[Path]:
    """Discover all plugin android/ directories from package_config.json and pub-cache."""
    android_dirs: set[Path] = set()

    # 1. Scan .dart_tool/package_config.json
    pkg_config = ROOT / ".dart_tool" / "package_config.json"
    if pkg_config.exists():
        try:
            data = json.loads(pkg_config.read_text(encoding="utf-8"))
            for pkg in data.get("packages", []):
                root_uri = pkg.get("rootUri", "")
                if not root_uri:
                    continue
                if root_uri.startswith("file://"):
                    pkg_path = Path(unquote(urlparse(root_uri).path))
                else:
                    pkg_path = (pkg_config.parent / root_uri).resolve()
                candidate = pkg_path / "android"
                if candidate.is_dir() and (
                    (candidate / "build.gradle").exists()
                    or (candidate / "build.gradle.kts").exists()
                ):
                    android_dirs.add(candidate.resolve())
        except Exception as exc:
            log(f"Warning: Could not parse package_config.json: {exc}")

    # 2. Scan PUB_CACHE or ~/.pub-cache
    pub_cache = Path(os.environ.get("PUB_CACHE", str(Path.home() / ".pub-cache")))
    if pub_cache.is_dir():
        for gradle_name in ("build.gradle", "build.gradle.kts"):
            for gradle_file in pub_cache.rglob(gradle_name):
                if gradle_file.parent.name == "android":
                    android_dirs.add(gradle_file.parent.resolve())

    return sorted(android_dirs)


def extract_and_clean_manifest_package(android_dir: Path) -> str | None:
    """Read package from plugin AndroidManifest.xml and strip deprecated package attribute."""
    manifest_path = android_dir / "src" / "main" / "AndroidManifest.xml"
    if not manifest_path.exists():
        return None

    content = manifest_path.read_text(encoding="utf-8", errors="ignore")
    tag_match = re.search(r"<manifest\b[^>]*>", content, flags=re.DOTALL)
    if not tag_match:
        return None

    manifest_tag = tag_match.group(0)
    pkg_match = re.search(r'\bpackage\s*=\s*["\']([^"\']+)["\']', manifest_tag)
    if not pkg_match:
        return None

    package_name = pkg_match.group(1).strip()
    cleaned_tag = re.sub(r'\s+\bpackage\s*=\s*["\'][^"\']+["\']', "", manifest_tag)
    new_content = (
        content[: tag_match.start()] + cleaned_tag + content[tag_match.end() :]
    )
    if new_content != content:
        manifest_path.write_text(new_content, encoding="utf-8")
    return package_name


def reorder_plugins_block(content: str) -> str:
    """Ensure com.android.library is always first inside a plugins { ... } block."""
    pattern = re.compile(r"(?m)^([ \t]*plugins\s*\{)([\s\S]*?)(\n[ \t]*\})")

    def _replace(match: re.Match) -> str:
        header, body, footer = match.group(1), match.group(2), match.group(3)
        android_lib: list[str] = []
        kotlin_lines: list[str] = []
        other_lines: list[str] = []

        for line in body.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if "com.android.library" in stripped:
                android_lib.append(line)
            elif (
                "kotlin-android" in stripped
                or "org.jetbrains.kotlin.android" in stripped
            ):
                kotlin_lines.append(line)
            else:
                other_lines.append(line)

        if not android_lib:
            return match.group(0)

        reordered = android_lib + kotlin_lines + other_lines
        return f"{header}\n" + "\n".join(reordered) + footer

    return pattern.sub(_replace, content, count=1)


def reorder_top_level_apply_plugins(content: str) -> str:
    """Ensure top-level apply plugin: 'com.android.library' runs before kotlin-android and android {}."""
    apply_re = re.compile(
        r"""^[ \t]*apply\s+plugin\s*:\s*['"]([^'"]+)['"][ \t]*$"""
    )
    lines = content.splitlines()
    depth = 0
    plugin_entries: list[tuple[str, str]] = []
    first_apply_out_idx: int | None = None
    android_block_out_idx: int | None = None
    kept_lines: list[str] = []

    for line in lines:
        code_part = re.sub(r"//.*$", "", line)
        if depth == 0:
            m = apply_re.match(line)
            if m:
                plugin_entries.append((m.group(1), line.strip()))
                if first_apply_out_idx is None:
                    first_apply_out_idx = len(kept_lines)
                continue
            if android_block_out_idx is None and re.match(r"^[ \t]*android\s*\{", line):
                android_block_out_idx = len(kept_lines)

        kept_lines.append(line)
        depth += code_part.count("{") - code_part.count("}")
        if depth < 0:
            depth = 0

    if not any(pid == "com.android.library" for pid, _ in plugin_entries):
        return content

    seen: set[str] = set()
    android_lib: list[str] = []
    kotlin_lines: list[str] = []
    other_lines: list[str] = []

    for pid, raw in plugin_entries:
        if pid in seen:
            continue
        seen.add(pid)
        if pid == "com.android.library":
            android_lib.append(raw)
        elif pid in ("kotlin-android", "org.jetbrains.kotlin.android"):
            kotlin_lines.append(raw)
        else:
            other_lines.append(raw)

    ordered = android_lib + kotlin_lines + other_lines

    if android_block_out_idx is not None and (
        first_apply_out_idx is None or first_apply_out_idx > android_block_out_idx
    ):
        insert_at = android_block_out_idx
    else:
        insert_at = first_apply_out_idx if first_apply_out_idx is not None else 0

    result = kept_lines[:insert_at] + ordered + kept_lines[insert_at:]
    trailing = "\n" if content.endswith("\n") else ""
    return "\n".join(result) + trailing


def upgrade_compile_sdk(content: str, is_kts: bool) -> str:
    """Upgrade numeric compileSdk / compileSdkVersion values below MIN_COMPILE_SDK to 34."""

    def _upgrade_num(match: re.Match) -> str:
        val = int(match.group(1))
        target = max(val, MIN_COMPILE_SDK)
        return f"compileSdk = {target}" if is_kts else f"compileSdk {target}"

    content = re.sub(
        r"\bcompileSdkVersion\s*(?:=|\()?\s*(\d+)\s*\)?",
        _upgrade_num,
        content,
    )
    content = re.sub(
        r"\bcompileSdk\s*(?:=|\s+)\s*(\d+)",
        _upgrade_num,
        content,
    )
    return content


def ensure_build_config_feature(content: str, is_kts: bool) -> str:
    """Enable buildFeatures.buildConfig per-module (required since AGP 9 removed global flag)."""
    if re.search(r"\bbuildConfig\b", content):
        return content

    bc_stmt = "buildConfig = true" if is_kts else "buildConfig true"

    if re.search(r"(?m)^[ \t]*buildFeatures\s*\{", content):
        return re.sub(
            r"(?m)^([ \t]*buildFeatures\s*\{)",
            lambda m: f"{m.group(1)}\n        {bc_stmt}",
            content,
            count=1,
        )

    if re.search(r"(?m)^[ \t]*android\s*\{", content):
        block = f"    buildFeatures {{\n        {bc_stmt}\n    }}"
        return re.sub(
            r"(?m)^([ \t]*android\s*\{)",
            lambda m: f"{m.group(1)}\n{block}",
            content,
            count=1,
        )

    return content


def infer_namespace(content: str, manifest_pkg: str | None, android_dir: Path) -> str:
    """Resolve namespace from AndroidManifest, build.gradle group, or folder name."""
    if manifest_pkg:
        return manifest_pkg
    group_match = re.search(
        r"""(?m)^\s*group\s*(?:=|\s+)\s*['"]([^'"]+)['"]""", content
    )
    if group_match:
        return group_match.group(1).strip()
    raw_name = re.sub(r"[^a-zA-Z0-9_]", "_", android_dir.parent.name).lower()
    raw_name = re.sub(r"_+", "_", raw_name).strip("_") or "plugin"
    if raw_name[0].isdigit():
        raw_name = f"p_{raw_name}"
    return f"com.universal.plugin.{raw_name}"


def patch_plugin_android_dir(android_dir: Path) -> None:
    manifest_pkg = extract_and_clean_manifest_package(android_dir)

    for gradle_name in ("build.gradle", "build.gradle.kts"):
        gradle_file = android_dir / gradle_name
        if not gradle_file.exists():
            continue

        is_kts = gradle_name.endswith(".kts")
        original = gradle_file.read_text(encoding="utf-8", errors="ignore")
        content = original

        # 1. Replace deprecated jcenter() with mavenCentral()
        content = re.sub(r"\bjcenter\s*\(\s*\)", "mavenCentral()", content)

        # 2. Reorder plugins so com.android.library is applied first
        content = reorder_plugins_block(content)
        content = reorder_top_level_apply_plugins(content)

        # 3. Upgrade compileSdk to at least 34
        content = upgrade_compile_sdk(content, is_kts=is_kts)

        # 4. Inject buildFeatures { buildConfig = true } per plugin (AGP 9 safe)
        content = ensure_build_config_feature(content, is_kts=is_kts)

        # 5. Inject namespace if missing
        has_namespace = re.search(
            r"""(?m)^\s*namespace\s*(?:=|\s+['"])""", content
        )
        if not has_namespace and re.search(r"(?m)^[ \t]*android\s*\{", content):
            ns = infer_namespace(content, manifest_pkg, android_dir)
            ns_line = f'    namespace = "{ns}"' if is_kts else f"    namespace '{ns}'"
            content = re.sub(
                r"(?m)^([ \t]*android\s*\{)",
                lambda m: f"{m.group(1)}\n{ns_line}",
                content,
                count=1,
            )

        if content != original:
            gradle_file.write_text(content, encoding="utf-8")
            log(f"Patched plugin Gradle: {gradle_file}")


def patch_all_plugins() -> None:
    plugin_dirs = collect_plugin_android_dirs()
    log(f"Found {len(plugin_dirs)} plugin android directories to inspect.")
    for android_dir in plugin_dirs:
        patch_plugin_android_dir(android_dir)


def configure_gradle_properties() -> None:
    props_file = ANDROID_DIR / "gradle.properties"
    lines = (
        props_file.read_text(encoding="utf-8").splitlines()
        if props_file.exists()
        else []
    )

    # Remove flags removed or breaking Kotlin DSL in AGP 9.0+
    removed_keys = {
        "android.defaults.buildfeatures.buildconfig",
        "android.enableJetifier",
        "android.newDsl",
    }

    desired = {
        "org.gradle.jvmargs": "-Xmx4G -XX:MaxMetaspaceSize=1G -XX:+HeapDumpOnOutOfMemoryError",
        "android.useAndroidX": "true",
        "android.builtInKotlin": "false",
    }

    updated_lines: list[str] = []
    seen: set[str] = set()
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in removed_keys:
                continue
            if key in desired:
                updated_lines.append(f"{key}={desired[key]}")
                seen.add(key)
                continue
        updated_lines.append(line)

    for key, val in desired.items():
        if key not in seen:
            updated_lines.append(f"{key}={val}")

    props_file.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    log("Configured android/gradle.properties (AGP 9 compatible)")


def configure_settings_gradle() -> None:
    kts_file = ANDROID_DIR / "settings.gradle.kts"
    groovy_file = ANDROID_DIR / "settings.gradle"

    if kts_file.exists():
        content = kts_file.read_text(encoding="utf-8")
        gms_line = '    id("com.google.gms.google-services") version "4.4.2" apply false'
        if "com.google.gms.google-services" not in content:
            content = re.sub(
                r"(?m)(plugins\s*\{[\s\S]*?)(\n\})",
                lambda m: f"{m.group(1)}\n{gms_line}{m.group(2)}",
                content,
                count=1,
            )

        before_hook = """
gradle.beforeProject {
    if (path != ":" && name != "app" && buildFile.exists()) {
        val text = buildFile.readText()
        val hasPluginsDsl = Regex("(?m)^\\\\s*plugins\\\\s*\\\\{").containsMatchIn(text)
        val usesAndroidLib = text.contains("com.android.library") || Regex("(?m)^\\\\s*android\\\\s*\\\\{").containsMatchIn(text)
        if (!hasPluginsDsl && usesAndroidLib) {
            try {
                pluginManager.apply("com.android.library")
            } catch (_: Throwable) {
            }
        }
    }
}
"""
        if "gradle.beforeProject" not in content:
            content = content.rstrip() + "\n" + before_hook

        kts_file.write_text(content, encoding="utf-8")
        log("Configured android/settings.gradle.kts")

    if groovy_file.exists():
        content = groovy_file.read_text(encoding="utf-8")
        gms_line = '    id "com.google.gms.google-services" version "4.4.2" apply false'
        if "com.google.gms.google-services" not in content:
            content = re.sub(
                r"(?m)(plugins\s*\{[\s\S]*?)(\n\})",
                lambda m: f"{m.group(1)}\n{gms_line}{m.group(2)}",
                content,
                count=1,
            )

        before_hook_groovy = """
gradle.beforeProject { proj ->
    if (proj.path != ":" && proj.name != "app" && proj.buildFile.exists()) {
        def text = proj.buildFile.text
        def hasPluginsDsl = (text =~ /(?m)^\\s*plugins\\s*\\{/).find()
        def usesAndroidLib = text.contains("com.android.library") || (text =~ /(?m)^\\s*android\\s*\\{/).find()
        if (!hasPluginsDsl && usesAndroidLib) {
            try {
                proj.pluginManager.apply("com.android.library")
            } catch (Throwable ignored) {
            }
        }
    }
}
"""
        if "gradle.beforeProject" not in content:
            content = content.rstrip() + "\n" + before_hook_groovy

        groovy_file.write_text(content, encoding="utf-8")
        log("Configured android/settings.gradle")


def write_app_build_gradle_kts() -> None:
    groovy_app = APP_DIR / "build.gradle"
    if groovy_app.exists():
        groovy_app.unlink()

    kts_content = """import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.universal.universal_messenger"
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.universal.universal_messenger"
        minSdk = 23
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

tasks.withType<KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.multidex:multidex:2.0.1")
}
"""
    (APP_DIR / "build.gradle.kts").write_text(kts_content, encoding="utf-8")
    log("Wrote android/app/build.gradle.kts")


def copy_google_services() -> None:
    src = ROOT / "google-services.json"
    dst = APP_DIR / "google-services.json"
    if not src.exists():
        log("ERROR: google-services.json not found in repository root!")
        sys.exit(1)
    shutil.copy2(src, dst)
    log("Copied google-services.json to android/app/google-services.json")


def write_file_paths_xml() -> None:
    xml_dir = MAIN_DIR / "res" / "xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    content = """<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <external-path name="external_files" path="." />
    <external-files-path name="external_app_files" path="." />
    <external-cache-path name="external_cache" path="." />
    <cache-path name="cache" path="." />
    <files-path name="files" path="." />
</paths>
"""
    (xml_dir / "file_paths.xml").write_text(content, encoding="utf-8")
    log("Wrote android/app/src/main/res/xml/file_paths.xml")


def write_android_manifest() -> None:
    manifest_content = """<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />

    <application
        android:label="Universal Messenger"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="true"
        android:requestLegacyExternalStorage="true">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize"
            android:supportsPictureInPicture="true"
            android:resizeableActivity="true"
            android:showWhenLocked="true"
            android:turnScreenOn="true">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="com.google.firebase.messaging.default_notification_channel_id"
            android:value="fcm_msg_all_v1" />

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />

        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>

        <service
            android:name="im.zego.zegoexpress.internal.ZegoScreenCaptureService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="mediaProjection"
            tools:node="merge" />
    </application>

    <queries>
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT" />
            <data android:mimeType="text/plain" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="https" />
        </intent>
    </queries>
</manifest>
"""
    (MAIN_DIR / "AndroidManifest.xml").write_text(manifest_content, encoding="utf-8")
    log("Wrote android/app/src/main/AndroidManifest.xml")


def write_main_activity_kt() -> None:
    # Remove any generated Java MainActivity to prevent duplicate classes
    for stray in MAIN_DIR.rglob("MainActivity.java"):
        stray.unlink()

    kt_dir = MAIN_DIR / "kotlin" / "com" / "universal" / "universal_messenger"
    kt_dir.mkdir(parents=True, exist_ok=True)

    kt_content = """package com.universal.universal_messenger

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
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
    companion object {
        private const val CHANNEL = "com.universal.messenger/icon"
    }

    private var isCallActive: Boolean = false
    private var suppressPipOnce: Boolean = false
    private var activeRingtone: Ringtone? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (suppressPipOnce) {
            suppressPipOnce = false
            return
        }
        if (isCallActive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(9, 16))
                    .build()
                enterPictureInPictureMode(params)
            } catch (_: Exception) {
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setCallActive" -> {
                        val active = (call.arguments as? Boolean)
                            ?: call.argument<Boolean>("active")
                            ?: false
                        isCallActive = active
                        result.success(true)
                    }

                    "suppressPipOnce" -> {
                        suppressPipOnce = (call.arguments as? Boolean) ?: true
                        result.success(true)
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestBatteryOptimizationExemption())
                    }

                    "isNetworkConnected" -> {
                        result.success(checkNetworkConnected())
                    }

                    "playRingtone" -> {
                        result.success(startRingtone())
                    }

                    "stopRingtone" -> {
                        stopActiveRingtone()
                        result.success(true)
                    }

                    "playMessageSound" -> {
                        result.success(playNotificationSound())
                    }

                    "getContentUri" -> {
                        val path = extractFilePath(call.arguments, call.argument("path"), call.argument("filePath"))
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "File path is required", null)
                        } else {
                            try {
                                val file = File(path)
                                if (!file.exists()) {
                                    result.error("FILE_NOT_FOUND", "File does not exist: $path", null)
                                } else {
                                    val uri = FileProvider.getUriForFile(
                                        this,
                                        "${applicationContext.packageName}.fileprovider",
                                        file
                                    )
                                    result.success(uri.toString())
                                }
                            } catch (e: Exception) {
                                result.error("URI_ERROR", e.message, null)
                            }
                        }
                    }

                    "installApk" -> {
                        val path = extractFilePath(call.arguments, call.argument("path"), call.argument("filePath"))
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "APK path is required", null)
                        } else {
                            installApkFile(path, result)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun extractFilePath(rawArgs: Any?, pathArg: String?, filePathArg: String?): String? {
        return pathArg ?: filePathArg ?: (rawArgs as? String)
    }

    private fun requestBatteryOptimizationExemption(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun checkNetworkConnected(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
        }
        @Suppress("DEPRECATION")
        val info = cm.activeNetworkInfo
        @Suppress("DEPRECATION")
        return info != null && info.isConnected
    }

    private fun startRingtone(): Boolean {
        return try {
            stopActiveRingtone()
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val ringtone = RingtoneManager.getRingtone(applicationContext, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ringtone.isLooping = true
                ringtone.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }
            ringtone.play()
            activeRingtone = ringtone
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopActiveRingtone() {
        try {
            activeRingtone?.stop()
        } catch (_: Exception) {
        } finally {
            activeRingtone = null
        }
    }

    private fun playNotificationSound(): Boolean {
        return try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val ringtone = RingtoneManager.getRingtone(applicationContext, uri)
            ringtone.play()
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun installApkFile(path: String, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "APK file not found: $path", null)
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                val permIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(permIntent)
                result.success(false)
                return
            }

            val apkUri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(installIntent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", e.message, null)
        }
    }

    override fun onDestroy() {
        stopActiveRingtone()
        super.onDestroy()
    }
}
"""
    (kt_dir / "MainActivity.kt").write_text(kt_content, encoding="utf-8")
    log("Wrote MainActivity.kt")


def main() -> None:
    if not ANDROID_DIR.is_dir():
        log("ERROR: android/ directory not found. Run 'flutter create' first.")
        sys.exit(1)

    patch_all_plugins()
    configure_gradle_properties()
    configure_settings_gradle()
    write_app_build_gradle_kts()
    copy_google_services()
    write_file_paths_xml()
    write_android_manifest()
    write_main_activity_kt()
    log("Android configuration and plugin patching completed successfully.")


if __name__ == "__main__":
    main()

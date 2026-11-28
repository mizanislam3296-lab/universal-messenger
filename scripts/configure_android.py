#!/usr/bin/env python3
"""
Configure freshly generated Android project, permanent release signing,
Play Protect-friendly adaptive launcher aliases, CallTaskCleanupService,
Android 8-16 screen sharing & speaker routing, native Android EditText
chat input (Ridmik Bengali space fix), and AGP 9+ plugin patches.
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
TARGET_COMPILE_SDK = 37
DEFAULT_APP_ID = "com.universal.universal_messenger"


def log(msg: str) -> None:
    print(f"[configure_android] {msg}")


def resolve_application_id() -> str:
    """Read package_name from google-services.json to prevent Firebase package mismatch."""
    gs_file = ROOT / "google-services.json"
    if not gs_file.exists():
        log("ERROR: google-services.json not found in repository root!")
        sys.exit(1)

    try:
        data = json.loads(gs_file.read_text(encoding="utf-8"))
    except Exception as exc:
        log(f"ERROR: google-services.json contains invalid JSON: {exc}")
        sys.exit(1)

    package_names: list[str] = []
    for client in data.get("client", []):
        pkg = (
            client.get("client_info", {})
            .get("android_client_info", {})
            .get("package_name", "")
            .strip()
        )
        if pkg:
            package_names.append(pkg)

    if not package_names:
        log("ERROR: No android_client_info.package_name found in google-services.json!")
        sys.exit(1)

    if DEFAULT_APP_ID in package_names:
        log(f"Matched default applicationId in google-services.json: {DEFAULT_APP_ID}")
        return DEFAULT_APP_ID

    matched = package_names[0]
    log(
        f"Note: '{DEFAULT_APP_ID}' not found in google-services.json. "
        f"Auto-matching applicationId to '{matched}'."
    )
    return matched


def collect_plugin_android_dirs() -> list[Path]:
    """Discover all plugin android/ directories from package_config.json and pub-cache."""
    android_dirs: set[Path] = set()

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
    """Force static compileSdk = 37 so flutter.compileSdkVersion never evaluates to null in AGP 9."""
    replacement = (
        f"compileSdk = {TARGET_COMPILE_SDK}"
        if is_kts
        else f"compileSdk {TARGET_COMPILE_SDK}"
    )

    content = re.sub(
        r"(?m)^([ \t]*)compileSdkVersion\s*(?:=|\s+)\s*[^\r\n]+$",
        lambda m: f"{m.group(1)}{replacement}",
        content,
    )
    content = re.sub(
        r"(?m)^([ \t]*)compileSdk\s*(?:=|\s+)\s*[^\r\n]+$",
        lambda m: f"{m.group(1)}{replacement}",
        content,
    )

    if re.search(r"(?m)^[ \t]*android\s*\{", content) and not re.search(
        r"\bcompileSdk(?:Version)?\b", content
    ):
        content = re.sub(
            r"(?m)^([ \t]*android\s*\{)",
            lambda m: f"{m.group(1)}\n    {replacement}",
            content,
            count=1,
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

        content = re.sub(r"\bjcenter\s*\(\s*\)", "mavenCentral()", content)
        content = reorder_plugins_block(content)
        content = reorder_top_level_apply_plugins(content)
        content = upgrade_compile_sdk(content, is_kts=is_kts)
        content = ensure_build_config_feature(content, is_kts=is_kts)

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


def configure_release_key_properties() -> bool:
    """Create android/key.properties if a permanent upload-keystore.jks and credentials exist."""
    keystore_file = APP_DIR / "upload-keystore.jks"
    store_pwd = os.environ.get("KEYSTORE_PASSWORD", "").strip()
    key_pwd = os.environ.get("KEY_PASSWORD", "").strip() or store_pwd
    key_alias = os.environ.get("KEY_ALIAS", "").strip() or "upload"

    key_props_file = ANDROID_DIR / "key.properties"
    if keystore_file.exists() and store_pwd and key_pwd and key_alias:
        content = (
            f"storePassword={store_pwd}\n"
            f"keyPassword={key_pwd}\n"
            f"keyAlias={key_alias}\n"
            "storeFile=upload-keystore.jks\n"
        )
        key_props_file.write_text(content, encoding="utf-8")
        log(f"Configured permanent release signing (alias={key_alias})")
        return True

    if key_props_file.exists():
        key_props_file.unlink()
    log("Permanent release keystore not configured; release build will use debug signing.")
    return False


def write_app_build_gradle_kts(application_id: str) -> None:
    groovy_app = APP_DIR / "build.gradle"
    if groovy_app.exists():
        groovy_app.unlink()

    kts_template = """import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.universal.universal_messenger"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "__APP_ID__"
        minSdk = 23
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
    kts_content = kts_template.replace("__APP_ID__", application_id)
    (APP_DIR / "build.gradle.kts").write_text(kts_content, encoding="utf-8")
    log(f"Wrote android/app/build.gradle.kts (applicationId={application_id})")


def copy_google_services() -> None:
    src = ROOT / "google-services.json"
    dst = APP_DIR / "google-services.json"
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


def write_launcher_icon_resources() -> None:
    """Generate clean, Play Protect-friendly adaptive icons for Universal Messenger aliases."""
    res_dir = MAIN_DIR / "res"
    values_dir = res_dir / "values"
    drawable_dir = res_dir / "drawable"
    drawable_v26_dir = res_dir / "drawable-v26"

    values_dir.mkdir(parents=True, exist_ok=True)
    drawable_dir.mkdir(parents=True, exist_ok=True)
    drawable_v26_dir.mkdir(parents=True, exist_ok=True)

    colors_xml = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_bg_default">#008069</color>
    <color name="ic_bg_aqua">#00BFA5</color>
    <color name="ic_bg_dark">#141A21</color>
    <color name="ic_bg_sunset">#F4511E</color>
</resources>
"""
    (values_dir / "icon_colors.xml").write_text(colors_xml, encoding="utf-8")

    fg_bodies = {
        "default": (
            "#008069",
            """    <group android:translateX="28" android:translateY="28" android:scaleX="2.16" android:scaleY="2.16">
        <path
            android:fillColor="#FFFFFF"
            android:pathData="M20,6h-1v8c0,0.55 -0.45,1 -1,1H6v1c0,1.1 0.9,2 2,2h10l4,4V8c0,-1.1 -0.9,-2 -2,-2zM17,12V4c0,-1.1 -0.9,-2 -2,-2H4c-1.1,0 -2,0.9 -2,2v13l4,-4h9c1.1,0 2,-0.9 2,-2z" />
    </group>""",
        ),
        "aqua": (
            "#00BFA5",
            """    <group android:translateX="30" android:translateY="30" android:scaleX="2.0" android:scaleY="2.0">
        <path
            android:fillColor="#FFFFFF"
            android:pathData="M2.01,21 L23,12 L2.01,3 L2,10 L17,12 L2,14 Z" />
    </group>""",
        ),
        "dark": (
            "#141A21",
            """    <group android:translateX="28" android:translateY="28" android:scaleX="2.16" android:scaleY="2.16">
        <path
            android:fillColor="#00E676"
            android:pathData="M20,6h-1v8c0,0.55 -0.45,1 -1,1H6v1c0,1.1 0.9,2 2,2h10l4,4V8c0,-1.1 -0.9,-2 -2,-2zM17,12V4c0,-1.1 -0.9,-2 -2,-2H4c-1.1,0 -2,0.9 -2,2v13l4,-4h9c1.1,0 2,-0.9 2,-2z" />
    </group>""",
        ),
        "sunset": (
            "#F4511E",
            """    <group android:translateX="28" android:translateY="28" android:scaleX="2.16" android:scaleY="2.16">
        <path
            android:fillColor="#FFFFFF"
            android:pathData="M12,17.27 L18.18,21 L16.54,13.97 L22,9.24 L14.81,8.63 L12,2 L9.19,8.63 L2,9.24 L7.46,13.97 L5.82,21 Z" />
    </group>""",
        ),
    }

    for key, (bg_hex, body) in fg_bodies.items():
        fg_xml = f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
{body}
</vector>
"""
        (drawable_dir / f"ic_alias_{key}_fg.xml").write_text(fg_xml, encoding="utf-8")

        fallback_xml = f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="{bg_hex}"
        android:pathData="M0,0 h108 v108 h-108 z" />
{body}
</vector>
"""
        (drawable_dir / f"ic_alias_{key}.xml").write_text(fallback_xml, encoding="utf-8")

        adaptive_xml = f"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_bg_{key}" />
    <foreground android:drawable="@drawable/ic_alias_{key}_fg" />
</adaptive-icon>
"""
        (drawable_v26_dir / f"ic_alias_{key}.xml").write_text(adaptive_xml, encoding="utf-8")

    log("Generated clean adaptive launcher icon resources (Play Protect-friendly)")


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
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />

    <application
        android:label="Universal Messenger"
        android:name="${applicationName}"
        android:icon="@drawable/ic_alias_default"
        android:roundIcon="@drawable/ic_alias_default"
        android:usesCleartextTraffic="false">

        <activity
            android:name="com.universal.universal_messenger.MainActivity"
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
        </activity>

        <!-- Default Launcher Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasDefault"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Universal Messenger"
            android:icon="@drawable/ic_alias_default"
            android:roundIcon="@drawable/ic_alias_default"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

        <!-- Aqua Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasAqua"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Universal Messenger"
            android:icon="@drawable/ic_alias_aqua"
            android:roundIcon="@drawable/ic_alias_aqua"
            android:enabled="false"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

        <!-- Dark Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasDark"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Universal Messenger"
            android:icon="@drawable/ic_alias_dark"
            android:roundIcon="@drawable/ic_alias_dark"
            android:enabled="false"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

        <!-- Sunset Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasSunset"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Universal Messenger"
            android:icon="@drawable/ic_alias_sunset"
            android:roundIcon="@drawable/ic_alias_sunset"
            android:enabled="false"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

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
            android:name="com.universal.universal_messenger.CallTaskCleanupService"
            android:enabled="true"
            android:exported="false"
            android:stopWithTask="false" />

        <!-- Android 8 to Android 16 Zego Screen Share Foreground Service -->
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
    log("Wrote Play Protect-friendly AndroidManifest.xml (Android 8-16 screen share ready)")


def write_call_task_cleanup_service_kt() -> None:
    kt_dir = MAIN_DIR / "kotlin" / "com" / "universal" / "universal_messenger"
    kt_dir.mkdir(parents=True, exist_ok=True)

    service_kt = """package com.universal.universal_messenger

import android.app.Service
import android.content.Intent
import android.os.IBinder

class CallTaskCleanupService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        MainActivity.handleAppSwipedFromRecents(applicationContext)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
"""
    (kt_dir / "CallTaskCleanupService.kt").write_text(service_kt, encoding="utf-8")
    log("Wrote CallTaskCleanupService.kt")


def write_main_activity_kt() -> None:
    for stray in MAIN_DIR.rglob("MainActivity.java"):
        stray.unlink()

    kt_dir = MAIN_DIR / "kotlin" / "com" / "universal" / "universal_messenger"
    kt_dir.mkdir(parents=True, exist_ok=True)

    kt_content = """package com.universal.universal_messenger

import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaScannerConnection
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Rational
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.lang.ref.WeakReference

class NativeChatInputFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        return NativeChatInputView(context, viewId, creationParams, messenger)
    }
}

class NativeChatInputView(
    private val context: Context,
    viewId: Int,
    creationParams: Map<String, Any?>?,
    messenger: BinaryMessenger
) : PlatformView {

    private val editText: EditText = EditText(context)
    private val channel = MethodChannel(messenger, "com.universal.messenger/native_chat_input_$viewId")
    private var lastReportedHeightDp: Double = 44.0
    private var lastLineCount: Int = 1
    private var suppressChangeCallback: Boolean = false

    init {
        val isDark = (creationParams?.get("isDark") as? Boolean) ?: false
        val hint = (creationParams?.get("hint") as? String) ?: "মেসেজ লিখুন..."

        editText.apply {
            this.hint = hint
            background = null
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15.5f)
            setPadding(dpToPx(14), dpToPx(10), dpToPx(14), dpToPx(10))
            gravity = Gravity.CENTER_VERTICAL or Gravity.START
            minLines = 1
            maxLines = 4
            isSingleLine = false
            isVerticalScrollBarEnabled = true
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            // TYPE_TEXT_FLAG_NO_SUGGESTIONS without CAP_SENTENCES fixes Ridmik Bengali space bug
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            }
            applyThemeColors(isDark)
        }

        editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (suppressChangeCallback) return
                val text = s?.toString() ?: ""
                channel.invokeMethod("onTextChanged", text)
                reportHeightIfLineCountChanged()
            }
        })

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "clear" -> {
                    suppressChangeCallback = true
                    editText.setText("")
                    suppressChangeCallback = false
                    try {
                        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                        imm?.restartInput(editText)
                    } catch (_: Exception) {
                    }
                    lastLineCount = 1
                    lastReportedHeightDp = 44.0
                    channel.invokeMethod("onHeightChanged", 44.0)
                    result.success(true)
                }

                "setText" -> {
                    val value = (call.arguments as? String) ?: ""
                    suppressChangeCallback = true
                    editText.setText(value)
                    editText.setSelection(value.length)
                    suppressChangeCallback = false
                    reportHeightIfLineCountChanged(force = true)
                    result.success(true)
                }

                "getText" -> {
                    result.success(editText.text?.toString() ?: "")
                }

                "setTheme" -> {
                    val dark = (call.arguments as? Boolean) ?: false
                    applyThemeColors(dark)
                    result.success(true)
                }

                "requestFocus" -> {
                    editText.requestFocus()
                    try {
                        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                        imm?.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
                    } catch (_: Exception) {
                    }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun applyThemeColors(isDark: Boolean) {
        if (isDark) {
            editText.setTextColor(Color.WHITE)
            editText.setHintTextColor(Color.parseColor("#8AFFFFFF"))
        } else {
            editText.setTextColor(Color.parseColor("#DE000000"))
            editText.setHintTextColor(Color.parseColor("#FF757575"))
        }
    }

    private fun dpToPx(dp: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            context.resources.displayMetrics
        ).toInt()
    }

    private fun reportHeightIfLineCountChanged(force: Boolean = false) {
        editText.post {
            try {
                val lines = editText.lineCount.coerceIn(1, 4)
                if (!force && lines == lastLineCount) return@post
                lastLineCount = lines
                val lineHeightPx = editText.lineHeight.coerceAtLeast(dpToPx(20))
                val desiredPx = (lines * lineHeightPx) + editText.paddingTop + editText.paddingBottom + dpToPx(2)
                val density = context.resources.displayMetrics.density
                val heightDp = (desiredPx / density).toDouble().coerceIn(44.0, 124.0)
                if (force || kotlin.math.abs(heightDp - lastReportedHeightDp) >= 2.0) {
                    lastReportedHeightDp = heightDp
                    channel.invokeMethod("onHeightChanged", heightDp)
                }
            } catch (_: Exception) {
            }
        }
    }

    override fun getView(): View = editText

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }
}

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.universal.messenger/icon"
        private const val CALL_PREFS = "universal_call_state"
        private const val CALL_NOTIF_ID = 99001
        private const val CALL_NOTIF_TAG = "universal_incoming_call"
        private val ICON_ALIASES = mapOf(
            "default" to "com.universal.universal_messenger.AliasDefault",
            "aqua" to "com.universal.universal_messenger.AliasAqua",
            "dark" to "com.universal.universal_messenger.AliasDark",
            "sunset" to "com.universal.universal_messenger.AliasSunset"
        )

        @Volatile
        private var activeInstance: WeakReference<MainActivity>? = null

        @Volatile
        private var activeMethodChannel: MethodChannel? = null

        fun stopZegoScreenCaptureServicesStatic(context: Context) {
            val serviceNames = listOf(
                "im.zego.zegoexpress.internal.ZegoScreenCaptureService",
                "im.zego.internal.screencapture.ZegoScreenCaptureService"
            )
            for (cls in serviceNames) {
                try {
                    val intent = Intent().setClassName(context.packageName, cls)
                    context.stopService(intent)
                } catch (_: Exception) {
                }
            }
        }

        fun clearCallNotificationsStatic(context: Context) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(CALL_NOTIF_ID)
                nm.cancel(CALL_NOTIF_TAG, 0)
                nm.cancel(CALL_NOTIF_TAG, CALL_NOTIF_ID)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    for (sbn in nm.activeNotifications) {
                        val ch = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            sbn.notification.channelId
                        } else {
                            null
                        }
                        if (ch == "fcm_call_all_v1" || ch == "call_ch_master_v1" || sbn.id == CALL_NOTIF_ID) {
                            if (sbn.tag != null) {
                                nm.cancel(sbn.tag, sbn.id)
                            } else {
                                nm.cancel(sbn.id)
                            }
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }

        fun handleAppSwipedFromRecents(context: Context) {
            val prefs = context.getSharedPreferences(CALL_PREFS, Context.MODE_PRIVATE)
            val wasInCall = prefs.getBoolean("in_call", false)
            val activeCallId = prefs.getString("call_id", "") ?: ""
            val activeCallDocId = prefs.getString("call_doc_id", "") ?: ""

            stopZegoScreenCaptureServicesStatic(context)
            clearCallNotificationsStatic(context)

            try {
                val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.mode = AudioManager.MODE_NORMAL
                am.isMicrophoneMute = false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                }
            } catch (_: Exception) {
            }

            if (!wasInCall && activeCallId.isEmpty()) {
                return
            }

            prefs.edit()
                .putBoolean("in_call", false)
                .putBoolean("killed_in_call", true)
                .putString("killed_call_id", activeCallId)
                .putString("killed_call_doc_id", activeCallDocId)
                .remove("call_id")
                .remove("call_doc_id")
                .apply()

            val mainHandler = Handler(Looper.getMainLooper())
            mainHandler.post {
                try {
                    activeInstance?.get()?.stopActiveRingtone()
                    activeMethodChannel?.invokeMethod(
                        "onAppSwipedFromRecents",
                        mapOf(
                            "callId" to activeCallId,
                            "callDocId" to activeCallDocId
                        )
                    )
                } catch (_: Exception) {
                }
            }

            mainHandler.postDelayed({
                try {
                    stopZegoScreenCaptureServicesStatic(context)
                    clearCallNotificationsStatic(context)
                    activeInstance?.get()?.finishAndRemoveTask()
                } catch (_: Exception) {
                }
                android.os.Process.killProcess(android.os.Process.myPid())
            }, 1200)
        }
    }

    private var isCallActive: Boolean = false
    private var isScreenSharing: Boolean = false
    private var suppressPipOnce: Boolean = false
    private var activeRingtone: Ringtone? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activeInstance = WeakReference(this)
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
        if (isScreenSharing) {
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
        activeInstance = WeakReference(this)

        // Register genuine native Android EditText for Ridmik Bengali typing
        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory(
                "com.universal.messenger/native_chat_input",
                NativeChatInputFactory(flutterEngine.dartExecutor.binaryMessenger)
            )

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        activeMethodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppFilesDir" -> {
                    try {
                        result.success(applicationContext.filesDir.absolutePath)
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }

                "setSpeakerphone" -> {
                    val enabled = (call.arguments as? Boolean)
                        ?: call.argument<Boolean>("enabled")
                        ?: false
                    result.success(setSpeakerphoneOn(enabled))
                }

                "setAppIcon" -> {
                    val type = call.argument<String>("type")
                        ?: (call.arguments as? String)
                        ?: "default"
                    result.success(switchLauncherIcon(type))
                }

                "pinCustomShortcut" -> {
                    val path = extractFilePath(call.arguments, call.argument("path"), call.argument("filePath"))
                    val label = call.argument<String>("label") ?: "Universal Messenger"
                    if (path.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(pinCustomHomeShortcut(path, label))
                    }
                }

                "setCallActive" -> {
                    val active = (call.arguments as? Boolean)
                        ?: call.argument<Boolean>("active")
                        ?: false
                    val callId = call.argument<String>("callId") ?: ""
                    val callDocId = call.argument<String>("callDocId") ?: ""
                    isCallActive = active
                    setCallAudioMode(active)
                    val prefs = getSharedPreferences(CALL_PREFS, Context.MODE_PRIVATE)
                    if (active) {
                        prefs.edit()
                            .putBoolean("in_call", true)
                            .putString("call_id", callId)
                            .putString("call_doc_id", callDocId)
                            .apply()
                        try {
                            startService(Intent(this, CallTaskCleanupService::class.java))
                        } catch (_: Exception) {
                        }
                    } else {
                        prefs.edit()
                            .putBoolean("in_call", false)
                            .remove("call_id")
                            .remove("call_doc_id")
                            .apply()
                        isScreenSharing = false
                        stopZegoScreenCaptureServicesStatic(applicationContext)
                        clearCallNotificationsStatic(applicationContext)
                        try {
                            stopService(Intent(this, CallTaskCleanupService::class.java))
                        } catch (_: Exception) {
                        }
                    }
                    result.success(true)
                }

                "consumeKilledCallState" -> {
                    val prefs = getSharedPreferences(CALL_PREFS, Context.MODE_PRIVATE)
                    val killed = prefs.getBoolean("killed_in_call", false)
                    val callId = prefs.getString("killed_call_id", "") ?: ""
                    val callDocId = prefs.getString("killed_call_doc_id", "") ?: ""
                    if (killed) {
                        prefs.edit()
                            .putBoolean("killed_in_call", false)
                            .remove("killed_call_id")
                            .remove("killed_call_doc_id")
                            .apply()
                        result.success(mapOf("callId" to callId, "callDocId" to callDocId))
                    } else {
                        result.success(null)
                    }
                }

                "setCallAudioMode" -> {
                    val active = (call.arguments as? Boolean)
                        ?: call.argument<Boolean>("active")
                        ?: false
                    result.success(setCallAudioMode(active))
                }

                "setScreenSharing" -> {
                    val active = (call.arguments as? Boolean)
                        ?: call.argument<Boolean>("active")
                        ?: false
                    isScreenSharing = active
                    if (!active) {
                        stopZegoScreenCaptureServicesStatic(applicationContext)
                    }
                    result.success(true)
                }

                "stopScreenShareService" -> {
                    isScreenSharing = false
                    stopZegoScreenCaptureServicesStatic(applicationContext)
                    result.success(true)
                }

                "moveToBackground" -> {
                    suppressPipOnce = true
                    moveTaskToBack(true)
                    result.success(true)
                }

                "clearCallNotifications" -> {
                    clearCallNotificationsStatic(applicationContext)
                    result.success(true)
                }

                "requestFullScreenIntentPermission" -> {
                    result.success(requestFullScreenIntentPermission())
                }

                "suppressPipOnce" -> {
                    suppressPipOnce = (call.arguments as? Boolean) ?: true
                    result.success(true)
                }

                "saveMediaFile" -> {
                    val path = extractFilePath(call.arguments, call.argument("path"), call.argument("filePath"))
                    val fileName = call.argument<String>("fileName") ?: "media_${System.currentTimeMillis()}"
                    val mediaType = call.argument<String>("mediaType") ?: "file"
                    if (path.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        Thread {
                            val saved = saveMediaToDevice(path, fileName, mediaType)
                            runOnUiThread { result.success(saved) }
                        }.start()
                    }
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

    private fun setSpeakerphoneOn(enabled: Boolean): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devices = am.availableCommunicationDevices
                if (enabled) {
                    val speaker = devices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speaker != null) {
                        am.setCommunicationDevice(speaker)
                    }
                } else {
                    val preferred = devices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                            it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                    }
                    if (preferred != null) {
                        am.setCommunicationDevice(preferred)
                    } else {
                        am.clearCommunicationDevice()
                    }
                }
            }
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = enabled
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun requestFullScreenIntentPermission(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (!nm.canUseFullScreenIntent()) {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                        data = Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    return false
                }
            }
            true
        } catch (_: Exception) {
            true
        }
    }

    private fun setCallAudioMode(active: Boolean): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (active) {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                am.isMicrophoneMute = false
                volumeControlStream = AudioManager.STREAM_VOICE_CALL
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                }
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
                am.mode = AudioManager.MODE_NORMAL
                volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun guessMimeType(fileName: String, mediaType: String): String {
        val lower = fileName.lowercase()
        return when {
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".mp4") -> "video/mp4"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".mov") -> "video/quicktime"
            lower.endsWith(".avi") -> "video/x-msvideo"
            lower.endsWith(".mp3") -> "audio/mpeg"
            lower.endsWith(".aac") -> "audio/aac"
            lower.endsWith(".m4a") -> "audio/mp4"
            lower.endsWith(".wav") -> "audio/wav"
            lower.endsWith(".ogg") || lower.endsWith(".opus") -> "audio/ogg"
            lower.endsWith(".pdf") -> "application/pdf"
            lower.endsWith(".zip") -> "application/zip"
            lower.endsWith(".apk") -> "application/vnd.android.package-archive"
            lower.endsWith(".txt") -> "text/plain"
            mediaType == "image" -> "image/jpeg"
            mediaType == "video" -> "video/mp4"
            else -> "application/octet-stream"
        }
    }

    private fun saveMediaToDevice(sourcePath: String, fileName: String, mediaType: String): Boolean {
        return try {
            val src = File(sourcePath)
            if (!src.exists()) return false
            val safeName = fileName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
            val mime = guessMimeType(safeName, mediaType)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val (collection, relPath) = when (mediaType) {
                    "image" -> Pair(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_PICTURES}/Universal Messenger"
                    )
                    "video" -> Pair(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_MOVIES}/Universal Messenger"
                    )
                    else -> Pair(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        "${Environment.DIRECTORY_DOWNLOADS}/Universal Messenger"
                    )
                }

                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }

                val uri = contentResolver.insert(collection, values) ?: return false
                contentResolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(src).use { input ->
                        input.copyTo(out)
                    }
                } ?: return false

                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val baseDir = Environment.getExternalStoragePublicDirectory(
                    when (mediaType) {
                        "image" -> Environment.DIRECTORY_PICTURES
                        "video" -> Environment.DIRECTORY_MOVIES
                        else -> Environment.DIRECTORY_DOWNLOADS
                    }
                )
                val targetDir = File(baseDir, "Universal Messenger")
                if (!targetDir.exists()) targetDir.mkdirs()
                val dst = File(targetDir, safeName)
                FileInputStream(src).use { input ->
                    FileOutputStream(dst).use { out ->
                        input.copyTo(out)
                    }
                }
                MediaScannerConnection.scanFile(
                    applicationContext,
                    arrayOf(dst.absolutePath),
                    arrayOf(mime),
                    null
                )
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun switchLauncherIcon(type: String): Boolean {
        val normalized = type.lowercase().trim()
        if (normalized == "custom") {
            return true
        }
        val targetClass = ICON_ALIASES[normalized] ?: ICON_ALIASES["default"]!!
        return try {
            val pm = applicationContext.packageManager
            val pkg = applicationContext.packageName

            pm.setComponentEnabledSetting(
                ComponentName(pkg, targetClass),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )

            for ((_, aliasClass) in ICON_ALIASES) {
                if (aliasClass != targetClass) {
                    pm.setComponentEnabledSetting(
                        ComponentName(pkg, aliasClass),
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        PackageManager.DONT_KILL_APP
                    )
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun pinCustomHomeShortcut(path: String, label: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val file = File(path)
            if (!file.exists()) return false

            val shortcutManager = getSystemService(ShortcutManager::class.java) ?: return false
            if (!shortcutManager.isRequestPinShortcutSupported) return false

            val rawBitmap = BitmapFactory.decodeFile(file.absolutePath) ?: return false
            val scaled = Bitmap.createScaledBitmap(rawBitmap, 192, 192, true)

            val launchIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }

            val shortcut = ShortcutInfo.Builder(this, "custom_icon_${System.currentTimeMillis()}")
                .setShortLabel(label)
                .setLongLabel(label)
                .setIcon(Icon.createWithBitmap(scaled))
                .setIntent(launchIntent)
                .build()

            shortcutManager.requestPinShortcut(shortcut, null)
            true
        } catch (_: Exception) {
            false
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

    fun stopActiveRingtone() {
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
                result.success("PERMISSION_REQUIRED")
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
            result.success("STARTED")
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", e.message, null)
        }
    }

    override fun onDestroy() {
        stopActiveRingtone()
        setCallAudioMode(false)
        stopZegoScreenCaptureServicesStatic(applicationContext)
        clearCallNotificationsStatic(applicationContext)
        if (isFinishing) {
            try {
                stopService(Intent(this, CallTaskCleanupService::class.java))
            } catch (_: Exception) {
            }
        }
        super.onDestroy()
    }
}
"""
    (kt_dir / "MainActivity.kt").write_text(kt_content, encoding="utf-8")
    log("Wrote MainActivity.kt with Ridmik Bengali space fix & Android 8-16 support")


def main() -> None:
    if not ANDROID_DIR.is_dir():
        log("ERROR: android/ directory not found. Run 'flutter create' first.")
        sys.exit(1)

    app_id = resolve_application_id()
    patch_all_plugins()
    configure_gradle_properties()
    configure_settings_gradle()
    configure_release_key_properties()
    write_app_build_gradle_kts(app_id)
    copy_google_services()
    write_file_paths_xml()
    write_launcher_icon_resources()
    write_android_manifest()
    write_call_task_cleanup_service_kt()
    write_main_activity_kt()
    log("Android configuration and plugin patching completed successfully.")


if __name__ == "__main__":
    main()

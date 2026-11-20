#!/usr/bin/env python3
"""
Configure freshly generated Android project, generate adaptive launcher aliases,
and patch cached Flutter plugins for AGP 9+ / modern Flutter compatibility on CI.
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


def write_app_build_gradle_kts(application_id: str) -> None:
    groovy_app = APP_DIR / "build.gradle"
    if groovy_app.exists():
        groovy_app.unlink()

    kts_template = """import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
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
    """Generate adaptive icons + fallback drawables for all home-screen icon aliases."""
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
    <color name="ic_bg_google">#FFFFFF</color>
    <color name="ic_bg_chatgpt">#0D0D0D</color>
    <color name="ic_bg_playstore">#FFFFFF</color>
    <color name="ic_bg_aqua">#00BFA5</color>
    <color name="ic_bg_dark">#141A21</color>
    <color name="ic_bg_sunset">#F4511E</color>
</resources>
"""
    (values_dir / "icon_colors.xml").write_text(colors_xml, encoding="utf-8")

    # Foreground vector contents (108x108 adaptive icon viewport, safe zone 21..87)
    fg_bodies = {
        "default": (
            "#008069",
            """    <group android:translateX="28" android:translateY="28" android:scaleX="2.16" android:scaleY="2.16">
        <path
            android:fillColor="#FFFFFF"
            android:pathData="M20,6h-1v8c0,0.55 -0.45,1 -1,1H6v1c0,1.1 0.9,2 2,2h10l4,4V8c0,-1.1 -0.9,-2 -2,-2zM17,12V4c0,-1.1 -0.9,-2 -2,-2H4c-1.1,0 -2,0.9 -2,2v13l4,-4h9c1.1,0 2,-0.9 2,-2z" />
    </group>""",
        ),
        "google": (
            "#FFFFFF",
            """    <group android:translateX="30" android:translateY="30">
        <path
            android:fillColor="#EA4335"
            android:pathData="M24,9.5 c3.54,0 6.71,1.22 9.21,3.6 l6.85,-6.85 C35.9,2.38 30.47,0 24,0 C14.62,0 6.51,5.38 2.56,13.22 l7.98,6.19 C12.43,13.72 17.74,9.5 24,9.5 z" />
        <path
            android:fillColor="#4285F4"
            android:pathData="M46.98,24.55 c0,-1.57 -0.15,-3.09 -0.38,-4.55 H24 v9.02 h12.94 c-0.58,2.96 -2.26,5.48 -4.78,7.18 l7.73,6 c4.51,-4.18 7.09,-10.36 7.09,-17.65 z" />
        <path
            android:fillColor="#FBBC05"
            android:pathData="M10.53,28.59 c-0.48,-1.45 -0.76,-2.99 -0.76,-4.59 s0.27,-3.14 0.76,-4.59 l-7.98,-6.19 C0.92,16.46 0,20.12 0,24 c0,3.88 0.92,7.54 2.56,10.78 l7.97,-6.19 z" />
        <path
            android:fillColor="#34A853"
            android:pathData="M24,48 c6.48,0 11.93,-2.13 15.89,-5.81 l-7.73,-6 c-2.15,1.45 -4.92,2.3 -8.16,2.3 c-6.26,0 -11.57,-4.22 -13.47,-9.91 l-7.98,6.19 C6.51,42.62 14.62,48 24,48 z" />
    </group>""",
        ),
        "chatgpt": (
            "#0D0D0D",
            """    <group android:translateX="28.8" android:translateY="28.8" android:scaleX="2.1" android:scaleY="2.1">
        <path
            android:fillColor="#FFFFFF"
            android:pathData="M22.2819,9.8211 a5.9847,5.9847 0 0 0 -0.5157,-4.9108 a6.0462,6.0462 0 0 0 -6.5098,-2.9 A6.0651,6.0651 0 0 0 4.9807,4.1818 a5.9847,5.9847 0 0 0 -3.9977,2.9 a6.0462,6.0462 0 0 0 0.7427,7.0966 a5.98,5.98 0 0 0 0.511,4.9107 a6.051,6.051 0 0 0 6.5146,2.9001 A5.9847,5.9847 0 0 0 13.2599,24 a6.0557,6.0557 0 0 0 5.7718,-4.2058 a5.9894,5.9894 0 0 0 3.9977,-2.9001 a6.0557,6.0557 0 0 0 -0.7475,-7.0729 z m-9.022,12.6081 a4.4755,4.4755 0 0 1 -2.8764,-1.0408 l0.1419,-0.0804 l4.7783,-2.7582 a0.7948,0.7948 0 0 0 0.3927,-0.6813 v-6.7369 l2.02,1.1686 a0.071,0.071 0 0 1 0.038,0.052 v5.5826 a4.504,4.504 0 0 1 -4.4945,4.4944 z m-9.6607,-4.1254 a4.4708,4.4708 0 0 1 -0.5346,-3.0137 l0.142,0.0852 l4.783,2.7582 a0.7712,0.7712 0 0 0 0.7806,0 l5.8428,-3.3685 v2.3324 a0.0804,0.0804 0 0 1 -0.0332,0.0615 L9.74,19.9502 a4.4992,4.4992 0 0 1 -6.1408,-1.6464 z M2.3408,7.8956 a4.485,4.485 0 0 1 2.3655,-1.9728 V11.6 a0.7664,0.7664 0 0 0 0.3879,0.6765 l5.8144,3.3543 l-2.0201,1.1685 a0.0757,0.0757 0 0 1 -0.071,0 l-4.8303,-2.7865 A4.504,4.504 0 0 1 2.3408,7.872 z m16.5963,3.8558 L13.1038,8.364 L15.1192,7.2 a0.0757,0.0757 0 0 1 0.071,0 l4.8303,2.7913 a4.4944,4.4944 0 0 1 -0.6765,8.1042 v-5.6772 a0.79,0.79 0 0 0 -0.407,-0.667 z m2.0107,-3.0231 l-0.142,-0.0852 l-4.7735,-2.7818 a0.7759,0.7759 0 0 0 -0.7854,0 L9.409,9.2297 V6.8974 a0.0662,0.0662 0 0 1 0.0284,-0.0615 l4.8303,-2.7866 a4.4992,4.4992 0 0 1 6.6802,4.66 z M8.3065,12.863 l-2.02,-1.1638 a0.0804,0.0804 0 0 1 -0.038,-0.0567 V6.0742 a4.4992,4.4992 0 0 1 7.3757,-3.4537 l-0.142,0.0805 L8.704,5.459 a0.7948,0.7948 0 0 0 -0.3927,0.6813 z m1.0976,-2.3654 l2.602,-1.4998 l2.6069,1.4998 v2.9994 l-2.5974,1.4997 l-2.6067,-1.4997 Z" />
    </group>""",
        ),
        "playstore": (
            "#FFFFFF",
            """    <group android:translateX="32" android:translateY="30">
        <path
            android:fillColor="#4285F4"
            android:pathData="M5,4 L25,24 L5,44 Z" />
        <path
            android:fillColor="#34A853"
            android:pathData="M5,4 L31.5,19.1 L25,24 Z" />
        <path
            android:fillColor="#EA4335"
            android:pathData="M5,44 L25,24 L31.5,28.9 Z" />
        <path
            android:fillColor="#FBBC04"
            android:pathData="M25,24 L31.5,19.1 L40,24 L31.5,28.9 Z" />
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
        # Foreground-only vector for Android 8+ adaptive icon
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

        # Fallback full icon for API < 26
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

        # Adaptive icon for API 26+ (clean rounded/squircle home screen look)
        adaptive_xml = f"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_bg_{key}" />
    <foreground android:drawable="@drawable/ic_alias_{key}_fg" />
</adaptive-icon>
"""
        (drawable_v26_dir / f"ic_alias_{key}.xml").write_text(adaptive_xml, encoding="utf-8")

    log("Generated adaptive launcher icon resources for all aliases")


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
        android:icon="@drawable/ic_alias_default"
        android:roundIcon="@drawable/ic_alias_default"
        android:usesCleartextTraffic="true"
        android:requestLegacyExternalStorage="true">

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

        <!-- Google Disguise Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasGoogle"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Google"
            android:icon="@drawable/ic_alias_google"
            android:roundIcon="@drawable/ic_alias_google"
            android:enabled="false"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

        <!-- ChatGPT Disguise Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasChatgpt"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="ChatGPT"
            android:icon="@drawable/ic_alias_chatgpt"
            android:roundIcon="@drawable/ic_alias_chatgpt"
            android:enabled="false"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity-alias>

        <!-- Play Store Disguise Alias -->
        <activity-alias
            android:name="com.universal.universal_messenger.AliasPlaystore"
            android:targetActivity="com.universal.universal_messenger.MainActivity"
            android:label="Play Store"
            android:icon="@drawable/ic_alias_playstore"
            android:roundIcon="@drawable/ic_alias_playstore"
            android:enabled="false"
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
    log("Wrote android/app/src/main/AndroidManifest.xml with launcher aliases")


def write_main_activity_kt() -> None:
    for stray in MAIN_DIR.rglob("MainActivity.java"):
        stray.unlink()

    kt_dir = MAIN_DIR / "kotlin" / "com" / "universal" / "universal_messenger"
    kt_dir.mkdir(parents=True, exist_ok=True)

    kt_content = """package com.universal.universal_messenger

import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
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
        private val ICON_ALIASES = mapOf(
            "default" to "com.universal.universal_messenger.AliasDefault",
            "google" to "com.universal.universal_messenger.AliasGoogle",
            "chatgpt" to "com.universal.universal_messenger.AliasChatgpt",
            "playstore" to "com.universal.universal_messenger.AliasPlaystore",
            "aqua" to "com.universal.universal_messenger.AliasAqua",
            "dark" to "com.universal.universal_messenger.AliasDark",
            "sunset" to "com.universal.universal_messenger.AliasSunset"
        )
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

    private fun switchLauncherIcon(type: String): Boolean {
        val normalized = type.lowercase().trim()
        if (normalized == "custom") {
            return true
        }
        val targetClass = ICON_ALIASES[normalized] ?: ICON_ALIASES["default"]!!
        return try {
            val pm = applicationContext.packageManager
            val pkg = applicationContext.packageName

            // Enable new alias FIRST so Android launcher never sees 0 active icons
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
    log("Wrote MainActivity.kt with launcher icon switcher")


def main() -> None:
    if not ANDROID_DIR.is_dir():
        log("ERROR: android/ directory not found. Run 'flutter create' first.")
        sys.exit(1)

    app_id = resolve_application_id()
    patch_all_plugins()
    configure_gradle_properties()
    configure_settings_gradle()
    write_app_build_gradle_kts(app_id)
    copy_google_services()
    write_file_paths_xml()
    write_launcher_icon_resources()
    write_android_manifest()
    write_main_activity_kt()
    log("Android configuration and plugin patching completed successfully.")


if __name__ == "__main__":
    main()

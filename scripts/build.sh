#!/usr/bin/env bash
set -euo pipefail

echo "==> Step 0: Syncing missing root *_screen.dart files & auto-patching Dart code..."
mkdir -p lib/screens
for f in *_screen.dart; do
  if [[ -f "$f" && ! -f "lib/screens/$f" ]]; then
    echo "Copying missing screen file: $f -> lib/screens/$f"
    cp "$f" "lib/screens/$f"
  fi
done

python3 - <<'PY'
import pathlib, re

file_picker_pat = re.compile(r'await\s+FilePicker\.pickFiles\(([^)]*)\)')
double_gt_pat = re.compile(r'StreamBuilder<\s*(QuerySnapshot|DocumentSnapshot)\s*>>\s*\(')
zego_express_imp_pat = re.compile(
    r"^\s*import\s+'package:zego_express_engine/zego_express_engine\.dart';\s*\n?",
    flags=re.MULTILINE,
)
audio_fn_pat = re.compile(
    r'Future<void>\s+_applyClearAudioAndHardwareSettings\(\)\s+async\s*\{[\s\S]*?\}\s*catch\s*\(_\)\s*\{\}\s*\}'
)
screen_fn_pat = re.compile(
    r'Future<void>\s+_optimizeScreenShareStream\(\)\s+async\s*\{[\s\S]*?\}\s*catch\s*\(_\)\s*\{\}\s*\}'
)
send_sched_sig_pat = re.compile(
    r'static\s+Future<bool>\s+sendScheduledDoc\s*\([^)]*\)\s*async\s*\{'
)
fresh_data_pat = re.compile(r'final\s+d\s*=\s*fresh\.data\(\)\s*;')
doc_is_snap_pat = re.compile(r'if\s*\(\s*doc\s+is\s+DocumentSnapshot[^)]*\)')

for p in pathlib.Path('lib').rglob('*.dart'):
    text = p.read_text(encoding='utf-8')
    new_text = file_picker_pat.sub(
        r'((await FilePicker.platform.pickFiles(\1))?.files ?? <PlatformFile>[])',
        text,
    )
    new_text = double_gt_pat.sub(r'StreamBuilder<\1>(', new_text)

    if p.name == 'call_screen.dart':
        prebuilt_imp = "import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';"
        uikit_imp = "import 'package:zego_uikit/zego_uikit.dart';"
        if prebuilt_imp in new_text and uikit_imp not in new_text:
            new_text = new_text.replace(prebuilt_imp, f"{prebuilt_imp}\n{uikit_imp}", 1)
        new_text = zego_express_imp_pat.sub('', new_text)
        new_text = audio_fn_pat.sub(
            "Future<void> _applyClearAudioAndHardwareSettings() async {\n"
            "    try {\n"
            "      await _nativeChannel.invokeMethod('setCallAudioMode', {'active': true});\n"
            "    } catch (_) {}\n"
            "  }",
            new_text,
        )
        new_text = screen_fn_pat.sub(
            "Future<void> _optimizeScreenShareStream() async {\n"
            "    try {\n"
            "      await _nativeChannel.invokeMethod('setCallAudioMode', {'active': true});\n"
            "    } catch (_) {}\n"
            "  }",
            new_text,
        )
        new_text = new_text.replace(
            'await ZegoUIKit().startSharingScreen();',
            'ZegoUIKit().startSharingScreen();',
        )

    if p.name == 'settings_screen.dart':
        new_text = send_sched_sig_pat.sub(
            'static Future<bool> sendScheduledDoc(DocumentSnapshot doc) async {',
            new_text,
            count=1,
        )
        new_text = fresh_data_pat.sub(
            'final d = fresh.data() as Map<String, dynamic>?;',
            new_text,
        )

    if p.name == 'chat_screen.dart':
        new_text = doc_is_snap_pat.sub('if (doc is DocumentSnapshot)', new_text)

    if new_text != text:
        p.write_text(new_text, encoding='utf-8')
        print(f"Patched {p}")
PY

echo "==> Step 1: Cleaning old android/ directory..."
rm -rf android

echo "==> Step 2: Generating fresh Android platform files..."
flutter create . \
  --platforms=android \
  --org com.universal \
  --project-name universal_messenger

echo "==> Step 3: Fetching Dart & Flutter packages..."
flutter pub get

echo "==> Step 4: Patching plugins and configuring native Android files..."
python3 scripts/configure_android.py

echo "==> Step 5: Encoding FCM_SERVICE_ACCOUNT..."
if [[ -n "${FCM_SERVICE_ACCOUNT:-}" ]]; then
  FCM_B64="$(printf '%s' "$FCM_SERVICE_ACCOUNT" | base64 -w 0)"
else
  echo "Warning: FCM_SERVICE_ACCOUNT is empty. Passing empty FCM_SA_B64."
  FCM_B64=""
fi

echo "==> Step 6: Building release APK (split-per-abi)..."
flutter build apk --release --split-per-abi --dart-define="FCM_SA_B64=${FCM_B64}"

echo "==> Step 7: Preparing direct release APK (Universal-Messenger.apk)..."
SRC_APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
DST_APK="build/app/outputs/flutter-apk/Universal-Messenger.apk"

if [[ ! -f "$SRC_APK" ]]; then
  echo "ERROR: Expected APK not found at $SRC_APK"
  exit 1
fi

cp "$SRC_APK" "$DST_APK"
echo "==> Build complete: $DST_APK"

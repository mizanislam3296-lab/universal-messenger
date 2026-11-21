#!/usr/bin/env bash
set -euo pipefail

echo "==> Step 0: Smart-syncing root *_screen.dart & lib/screens/ (always keeping newest commit)..."
mkdir -p lib/screens
for f in *_screen.dart; do
  if [[ -f "$f" ]]; then
    if [[ ! -f "lib/screens/$f" ]]; then
      echo "Copying missing screen file: $f -> lib/screens/$f"
      cp "$f" "lib/screens/$f"
    else
      root_ts="$(git log -1 --format=%ct -- "$f" 2>/dev/null || echo 0)"
      lib_ts="$(git log -1 --format=%ct -- "lib/screens/$f" 2>/dev/null || echo 0)"
      if [[ "${root_ts:-0}" -gt "${lib_ts:-0}" ]]; then
        echo "Root $f is newer ($root_ts > $lib_ts); syncing -> lib/screens/$f"
        cp "$f" "lib/screens/$f"
      fi
    fi
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
send_sched_sig_pat = re.compile(
    r'static\s+Future<bool>\s+sendScheduledDoc\s*\([^)]*\)\s*async\s*\{'
)
fresh_data_pat = re.compile(r'final\s+d\s*=\s*fresh\.data\(\)\s*;')
doc_is_snap_pat = re.compile(r'if\s*\(\s*doc\s+is\s+DocumentSnapshot[^)]*\)')
fb_init_pat = re.compile(r'(await\s+Firebase\.initializeApp\s*\([\s\S]*?\)\s*;)')

for p in pathlib.Path('lib').rglob('*.dart'):
    text = p.read_text(encoding='utf-8')
    new_text = file_picker_pat.sub(
        r'((await FilePicker.platform.pickFiles(\1))?.files ?? <PlatformFile>[])',
        text,
    )
    new_text = double_gt_pat.sub(r'StreamBuilder<\1>(', new_text)

    if p.name == 'main.dart' and 'universalFcmBackgroundHandler' not in new_text:
        fcm_imp = "import 'package:firebase_messaging/firebase_messaging.dart';"
        set_imp = "import 'package:universal_messenger/screens/settings_screen.dart';"
        header = ''
        if fcm_imp not in new_text:
            header += f"{fcm_imp}\n"
        if set_imp not in new_text:
            header += f"{set_imp}\n"
        if header:
            new_text = header + new_text
        new_text = fb_init_pat.sub(
            r'\1\n  FirebaseMessaging.onBackgroundMessage(universalFcmBackgroundHandler);',
            new_text,
            count=1,
        )

    if p.name == 'call_screen.dart':
        prebuilt_imp = "import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';"
        uikit_imp = "import 'package:zego_uikit/zego_uikit.dart';"
        if prebuilt_imp in new_text and uikit_imp not in new_text:
            new_text = new_text.replace(prebuilt_imp, f"{prebuilt_imp}\n{uikit_imp}", 1)
        new_text = zego_express_imp_pat.sub('', new_text)
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
        if 'callId: callId,' in new_text and 'callerId: _currentUser.uid,' not in new_text:
            new_text = new_text.replace(
                'callId: callId,',
                'callId: callId,\n      chatId: _chatId,\n      callerId: _currentUser.uid,\n      callerName: callerName,\n      callerEmail: callerEmail,',
                1,
            )

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

echo "==> Step 4: Preparing permanent Release Keystore (if configured in GitHub Secrets)..."
if [[ -n "${KEYSTORE_B64:-}" ]]; then
  printf '%s' "$KEYSTORE_B64" | tr -d '\n\r ' | base64 -d > android/app/upload-keystore.jks
  echo "Decoded android/app/upload-keystore.jks successfully."
else
  echo "Note: KEYSTORE_B64 secret not configured yet. Using debug signing."
fi

echo "==> Step 5: Patching plugins and configuring native Android files..."
python3 scripts/configure_android.py

echo "==> Step 6: Encoding FCM_SERVICE_ACCOUNT..."
if [[ -n "${FCM_SERVICE_ACCOUNT:-}" ]]; then
  FCM_B64="$(printf '%s' "$FCM_SERVICE_ACCOUNT" | base64 -w 0)"
else
  echo "Warning: FCM_SERVICE_ACCOUNT is empty. Passing empty FCM_SA_B64."
  FCM_B64=""
fi

echo "==> Step 7: Building verified arm64-v8a release APK (v15.0.0)..."
flutter build apk --release --split-per-abi \
  --build-name=15.0.0 \
  --build-number=15 \
  --dart-define="FCM_SA_B64=${FCM_B64}"

echo "==> Step 8: Preparing and verifying Universal-Messenger.apk..."
SRC_APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
DST_APK="build/app/outputs/flutter-apk/Universal-Messenger.apk"

if [[ ! -f "$SRC_APK" ]]; then
  echo "ERROR: Expected APK not found at $SRC_APK"
  exit 1
fi

cp "$SRC_APK" "$DST_APK"

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
APKSIGNER="$(find "$SDK_DIR/build-tools" -name apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
if [[ -n "$APKSIGNER" ]]; then
  echo "==> Verifying APK signature with $APKSIGNER..."
  "$APKSIGNER" verify --verbose "$DST_APK"
else
  echo "Warning: apksigner not found in $SDK_DIR/build-tools; skipping verification."
fi

ls -lh "$DST_APK"
echo "==> Build complete: $DST_APK"

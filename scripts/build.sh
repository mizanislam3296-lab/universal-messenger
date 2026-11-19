#!/usr/bin/env bash
set -euo pipefail

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

echo "==> Step 7: Copying arm64-v8a APK to app-release.apk..."
SRC_APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
DST_APK="build/app/outputs/flutter-apk/app-release.apk"

if [[ ! -f "$SRC_APK" ]]; then
  echo "ERROR: Expected APK not found at $SRC_APK"
  exit 1
fi

cp "$SRC_APK" "$DST_APK"
echo "==> Build complete: $DST_APK"

#!/usr/bin/env bash
set -e

rm -rf android
flutter create . --platforms=android --org com.universal --project-name universal_messenger
flutter pub get
python3 scripts/configure_android.py

if [ -n "$FCM_SERVICE_ACCOUNT" ]; then
  echo "FCM_SERVICE_ACCOUNT detected"
  FCM_B64=$(printf '%s' "$FCM_SERVICE_ACCOUNT" | base64 -w 0)
  flutter build apk --release --split-per-abi --dart-define=FCM_SA_B64=$FCM_B64
else
  echo "WARNING: FCM_SERVICE_ACCOUNT empty"
  flutter build apk --release --split-per-abi
fi

cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk build/app/outputs/flutter-apk/app-release.apk

#!/bin/bash
set -euo pipefail
export JAVA_HOME="${JAVA_HOME:-/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$JAVA_HOME/bin:$HOME/development/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

cd "$(dirname "$0")/.."
SERIAL="$(adb devices | awk '/[[:space:]]device$/{print $1; exit}')"
if [[ -z "${SERIAL}" ]]; then
  echo "未检测到已连接的安卓手机（adb devices 为空）"
  exit 1
fi

echo "==> 设备: ${SERIAL}"
echo "==> 开始 flutter build apk --release (arm64 + armeabi-v7a) ..."
flutter build apk --release --target-platform android-arm64,android-arm
APK="build/app/outputs/flutter-apk/app-release.apk"
DIST="dist/File2File-Android-release.apk"
mkdir -p dist
cp -f "$APK" "$DIST"
ls -lh "$APK" "$DIST"

echo "==> 推送到手机 /sdcard/Download/File2File-release.apk ..."
adb -s "$SERIAL" push "$APK" /sdcard/Download/File2File-release.apk
adb -s "$SERIAL" shell ls -lh /sdcard/Download/File2File-release.apk
echo "==> 完成。请在手机「文件管理 / Download」里安装 File2File-release.apk"

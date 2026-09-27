#!/usr/bin/env bash
# 一键：启动 File2File arm64 模拟器(1080x1920) + flutter run
# 不包含任何 Token / 密码；登录请在 App 内手动输入。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tool/env.sh"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"

AVD_NAME="${AVD_NAME:-File2File_API35_arm64}"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter)}"

if [[ -z "${FLUTTER_BIN}" ]]; then
  echo "未找到 flutter，请先: source tool/env.sh" >&2
  exit 1
fi

if [[ ! -d "$HOME/.android/avd/${AVD_NAME}.avd" ]]; then
  echo "找不到模拟器 AVD: ${AVD_NAME}" >&2
  echo "可用列表:" >&2
  emulator -list-avds >&2 || true
  exit 1
fi

cd "$ROOT"

adb start-server >/dev/null

device_id=""
pick_emulator() {
  adb devices | awk '/^emulator-/{print $1; exit}'
}

boot_completed() {
  local id="$1"
  adb -s "$id" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'
}

device_id="$(pick_emulator || true)"
if [[ -z "${device_id}" ]]; then
  echo "==> 启动模拟器 ${AVD_NAME} (1080x1920)…"
  # -no-snapshot-load 避免旧分辨率快照；首次冷启稍慢
  nohup emulator -avd "$AVD_NAME" -no-snapshot-load -gpu auto \
    >/tmp/file2file-emulator.log 2>&1 &
  echo "    日志: /tmp/file2file-emulator.log"

  echo "==> 等待 adb 设备…"
  for _ in $(seq 1 60); do
    device_id="$(pick_emulator || true)"
    [[ -n "${device_id}" ]] && break
    sleep 2
  done
  if [[ -z "${device_id}" ]]; then
    echo "模拟器未能出现在 adb devices" >&2
    tail -40 /tmp/file2file-emulator.log >&2 || true
    exit 1
  fi
else
  echo "==> 已有模拟器: ${device_id}"
fi

echo "==> 等待开机完成 (${device_id})…"
adb -s "$device_id" wait-for-device
for _ in $(seq 1 90); do
  if [[ "$(boot_completed "$device_id")" == "1" ]]; then
    break
  fi
  sleep 2
done
if [[ "$(boot_completed "$device_id")" != "1" ]]; then
  echo "模拟器开机超时" >&2
  exit 1
fi

# 有物理键盘时仍弹出软键盘；并确保 Mac 键入能进模拟器（AVD 已设 hw.keyboard=yes）
adb -s "$device_id" shell settings put secure show_ime_with_hard_keyboard 1 >/dev/null

echo "==> 卸载旧调试包（避免 Kernel binary 损坏导致白屏）…"
adb -s "$device_id" uninstall com.file2file.file2file >/dev/null 2>&1 || true

echo "==> flutter run → ${device_id}"
exec "$FLUTTER_BIN" run -d "$device_id" --purge-persistent-cache

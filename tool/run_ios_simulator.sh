#!/usr/bin/env bash
# 一键：启动 iPhone 模拟器 + flutter run
# 不包含任何 Token / 密码；登录请在 App 内手动输入。
#
# 可选环境变量：
#   IOS_SIMULATOR   模拟器名称（默认：iPhone 15）
#   IOS_DEVICE_UDID 指定已有设备 UDID 时优先使用
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tool/env.sh"

FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter)}"
SIM_NAME="${IOS_SIMULATOR:-iPhone 15}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS 模拟器只能在 macOS 上运行。" >&2
  exit 1
fi

if [[ -z "${FLUTTER_BIN}" ]]; then
  echo "未找到 flutter，请先: source tool/env.sh" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "未找到 Xcode 命令行工具（xcrun）。请安装 Xcode 并执行: xcode-select --install" >&2
  exit 1
fi

if ! xcrun simctl help >/dev/null 2>&1; then
  echo "无法调用 simctl。请打开一次 Xcode，并确认已安装 iOS Simulator runtime。" >&2
  exit 1
fi

list_available() {
  xcrun simctl list devices available
}

booted_iphone_udid() {
  list_available | awk -F '[()]' '
    /iPhone/ && /Booted/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }
      }
    }
  '
}

udid_for_name() {
  local name="$1"
  list_available | awk -F '[()]' -v n="$name" '
    index($0, n) && /iPhone/ && !/unavailable/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }
      }
    }
  '
}

first_iphone_udid() {
  list_available | awk -F '[()]' '
    /iPhone/ && !/unavailable/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }
      }
    }
  '
}

device_id="${IOS_DEVICE_UDID:-}"
if [[ -z "${device_id}" ]]; then
  device_id="$(booted_iphone_udid || true)"
fi
if [[ -z "${device_id}" ]]; then
  device_id="$(udid_for_name "$SIM_NAME" || true)"
fi
if [[ -z "${device_id}" ]]; then
  device_id="$(first_iphone_udid || true)"
fi

if [[ -z "${device_id}" ]]; then
  echo "找不到可用的 iPhone 模拟器。" >&2
  echo "请在 Xcode → Settings → Platforms 安装 iOS Simulator runtime。" >&2
  echo "当前可用设备：" >&2
  list_available >&2 || true
  exit 1
fi

echo "==> 模拟器: ${device_id}"
if list_available | grep -F "$device_id" | grep -q "Booted"; then
  echo "==> 已开机"
else
  echo "==> 启动模拟器…"
  xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
  open -a Simulator --args -CurrentDeviceUDID "$device_id"
  echo "==> 等待开机完成…"
  if ! xcrun simctl bootstatus "$device_id" -b >/dev/null; then
    echo "模拟器开机超时或失败" >&2
    exit 1
  fi
fi

cd "$ROOT"

echo "==> flutter pub get"
"$FLUTTER_BIN" pub get >/dev/null

pod_install() {
  local attempt="$1"
  echo "==> pod install (第 ${attempt} 次)"
  (cd "$ROOT/ios" && pod install)
}

echo "==> 安装 iOS CocoaPods 依赖"
pod_ok=0
for i in 1 2 3; do
  if pod_install "$i"; then
    pod_ok=1
    break
  fi
  echo "pod install 失败，3 秒后重试…" >&2
  sleep 3
done
if [[ "$pod_ok" -ne 1 ]]; then
  echo "pod install 三次均失败。常见原因是 CocoaPods 源站超时。" >&2
  echo "可检查网络后重跑本脚本，或手动: cd ios && pod install" >&2
  exit 1
fi

# 模拟器使用 libwebrpc-ios-simulator.a（Apple Silicon arm64）。
echo "==> flutter run → ${device_id}"
exec "$FLUTTER_BIN" run -d "$device_id" --purge-persistent-cache

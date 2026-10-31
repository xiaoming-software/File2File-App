#!/usr/bin/env bash
# 打 App Store 用 IPA（需已登录 Xcode Apple ID，且 Team 有 Apple Distribution）。
# 用法：
#   ./tool/release_ios_store.sh              # 只导出 IPA 到 dist/
#   ./tool/release_ios_store.sh --upload     # 导出后用 notary/altool 上传（需 ASC API 或 Apple ID）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tool/env.sh"

UPLOAD=0
for a in "$@"; do
  case "$a" in
    --upload) UPLOAD=1 ;;
    -h|--help)
      echo "用法: $0 [--upload]"
      exit 0
      ;;
  esac
done

cd "$ROOT"
mkdir -p "$ROOT/dist"

echo "[INFO] pod install..."
(cd ios && pod install)

echo "[INFO] flutter build ipa (App Store)..."
flutter build ipa \
  --release \
  --export-options-plist=ios/ExportOptions-AppStore.plist

IPA="$(find build/ios/ipa -name '*.ipa' 2>/dev/null | head -1 || true)"
if [[ -z "${IPA}" ]]; then
  echo "[ERROR] 未找到 IPA。请确认 Xcode 已登录 Apple ID，Signing 为 Automatic，Team=B35S9Y7DUX，且已有 Apple Distribution 证书。" >&2
  exit 1
fi

DEST="$ROOT/dist/$(basename "$IPA")"
cp -f "$IPA" "$DEST"
echo "[OK] IPA: $DEST"

if [[ "$UPLOAD" -eq 1 ]]; then
  echo "[INFO] 上传到 App Store Connect（xcrun altool）..."
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "[ERROR] 请设置环境变量：" >&2
    echo "  export APPLE_ID='你的AppleID邮箱'" >&2
    echo "  export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'  # appleid.apple.com 生成的 App 专用密码" >&2
    exit 1
  fi
  xcrun altool --upload-app --type ios -f "$DEST" \
    -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"
  echo "[OK] 已提交上传。到 App Store Connect → TestFlight/版本 查看处理状态。"
else
  echo "[INFO] 未上传。可用 Transporter App 拖入 IPA，或："
  echo "  APPLE_ID=... APPLE_APP_SPECIFIC_PASSWORD=... $0 --upload"
fi

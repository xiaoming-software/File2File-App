#!/usr/bin/env bash
# 一键：用固定本机签名打包 Android APK，打 git tag，并发布为 GitHub Latest Release。
# 不包含 Token / 密码；也不把 keystore 提交进仓库。
#
# 用法：
#   1. 改下面的 VERSION_NAME
#   2. ./tool/release_android.sh
#
# 覆盖安装条件：applicationId 不变 + 同一份 upload.jks + 每次更高的 VERSION_CODE。
set -euo pipefail

# ======== 发版时只改这里 ========
VERSION_NAME="0.1.0"
# =================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tool/env.sh"

REPO="${GITHUB_REPO:-xiaoming-software/File2File-App}"
TAG="v${VERSION_NAME}"
KEYSTORE_DIR="$ROOT/android/keystore"
KEYSTORE_FILE="$KEYSTORE_DIR/upload.jks"
KEY_PROPS="$ROOT/android/key.properties"
KEY_ALIAS="upload"
DIST_DIR="$ROOT/dist"
VERSION_CODE="$(date +%s)"
APK_NAME="File2File-Android-${VERSION_NAME}-${VERSION_CODE}.apk"

FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter)}"

if [[ ! "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
  echo "VERSION_NAME 格式无效: ${VERSION_NAME}（示例: 0.1.0）" >&2
  exit 1
fi

if [[ -z "${FLUTTER_BIN}" ]]; then
  echo "未找到 flutter，请先: source tool/env.sh" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "未找到 GitHub CLI (gh)。安装: brew install gh && gh auth login" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh 未登录。请执行: gh auth login" >&2
  exit 1
fi

if ! command -v keytool >/dev/null 2>&1; then
  echo "未找到 keytool。请确认 JAVA_HOME / JDK 已配置。" >&2
  exit 1
fi

cd "$ROOT"

remote_tag_exists() {
  git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1
}

release_exists() {
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1
}

if release_exists; then
  echo "GitHub 上已有 Release ${TAG}：" >&2
  gh release view "$TAG" --repo "$REPO" --json url --jq .url >&2
  echo "请提高 VERSION_NAME 后再发新版。" >&2
  exit 1
fi

if remote_tag_exists; then
  echo "远程已有 tag ${TAG}，但还没有 Release。将补发 Release。"
elif git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> 本地已有 tag ${TAG}，跳过创建，尝试推送到 GitHub"
else
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "警告: 工作区有未提交改动。tag 会打在当前 HEAD 上，APK 按当前工作区代码构建。" >&2
  fi
fi

ensure_keystore() {
  if [[ -f "$KEYSTORE_FILE" && -f "$KEY_PROPS" ]]; then
    echo "==> 使用已有签名: ${KEYSTORE_FILE}"
    return
  fi
  if [[ -f "$KEYSTORE_FILE" || -f "$KEY_PROPS" ]]; then
    echo "签名文件不完整：需要同时存在" >&2
    echo "  ${KEYSTORE_FILE}" >&2
    echo "  ${KEY_PROPS}" >&2
    echo "请勿只保留其中一个，否则无法覆盖安装。" >&2
    exit 1
  fi

  echo "==> 首次发版：生成本地 upload keystore（不会提交到 git）"
  mkdir -p "$KEYSTORE_DIR"
  local pass
  pass="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  keytool -genkeypair \
    -v \
    -keystore "$KEYSTORE_FILE" \
    -alias "$KEY_ALIAS" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass "$pass" \
    -keypass "$pass" \
    -dname "CN=File2File, OU=xiaoming-software, O=xiaoming-software, C=CN"

  cat > "$KEY_PROPS" <<EOF
storePassword=${pass}
keyPassword=${pass}
keyAlias=${KEY_ALIAS}
storeFile=keystore/upload.jks
EOF
  chmod 600 "$KEY_PROPS" "$KEYSTORE_FILE"
  echo "==> 已写入 ${KEY_PROPS}"
  echo "    请备份 android/keystore/upload.jks 和 android/key.properties；丢失后用户无法覆盖更新。"
}

ensure_keystore

mkdir -p "$DIST_DIR"
EXISTING_APK="$(ls -t "$DIST_DIR"/File2File-Android-"${VERSION_NAME}"-*.apk 2>/dev/null | head -1 || true)"
if [[ "${SKIP_BUILD:-}" == "1" && -n "${EXISTING_APK}" ]]; then
  DEST_APK="$EXISTING_APK"
  APK_NAME="$(basename "$DEST_APK")"
  echo "==> 跳过构建，使用已有 APK: ${DEST_APK}"
else
  echo "==> 构建 ${APK_NAME}"
  echo "    versionName=${VERSION_NAME}  versionCode=${VERSION_CODE}  abi=arm64-v8a"
  "$FLUTTER_BIN" pub get >/dev/null
  "$FLUTTER_BIN" build apk --release \
    --build-name="$VERSION_NAME" \
    --build-number="$VERSION_CODE"

  SRC_APK="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
  if [[ ! -f "$SRC_APK" ]]; then
    echo "未找到 APK: ${SRC_APK}" >&2
    exit 1
  fi
  DEST_APK="$DIST_DIR/$APK_NAME"
  cp "$SRC_APK" "$DEST_APK"
fi

echo "==> 推送 tag ${TAG}"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "File2File Android ${VERSION_NAME} (${VERSION_CODE})"
fi
if ! remote_tag_exists; then
  git push origin "refs/tags/${TAG}"
else
  echo "    远程 tag 已存在，跳过 push"
fi

NOTES="$(cat <<EOF
## File2File ${VERSION_NAME}

Android 安装包（arm64-v8a）。应用 ID：\`com.file2file.file2file\`。

- 文件：\`${APK_NAME}\`
- versionName：\`${VERSION_NAME}\`
- versionCode：\`${VERSION_CODE}\`

### 安装

1. 用 **arm64** Android 手机下载 APK。
2. 允许「未知来源 / 安装未知应用」。
3. 与旧版签名相同时，可直接覆盖安装并保留本地数据。

首次从电脑调试包（debug 签名）换成正式包时，需要先卸载旧 App，之后的正式版之间即可覆盖更新。
EOF
)"

echo "==> 发布 GitHub Release ${TAG} → ${REPO}"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "File2File ${VERSION_NAME}" \
  --notes "$NOTES" \
  "$DEST_APK"

echo
echo "完成: ${DEST_APK}"
gh release view "$TAG" --repo "$REPO" --web >/dev/null 2>&1 || true
gh release view "$TAG" --repo "$REPO" --json url --jq .url

#!/usr/bin/env bash
#
# build-and-install.sh — 用真实开发者证书签名构建 SayIt.app 并安装到 /Applications。
#
# 默认走 Automatic 签名（CODE_SIGN_STYLE=Automatic + DEVELOPMENT_TEAM=95JJW8BPVA，
# 来自 project.yml）。若 Automatic 因 provisioning 失败，可手动降级为：
#   SIGN_MODE=manual /path/to/build-and-install.sh
# 手动模式使用 "Apple Development: WENTONG LIU (X2U6Z8Z9B7)" 且不带 provisioning profile
# （macOS 非 App Store 应用允许无 profile）。
#
# 幂等：可重复运行，每次重新生成工程、重建、覆盖安装。
# 不做 notarize（公证）——那是对外分发(Developer ID)才需要的，留待 v3。

set -euo pipefail

REPO="/Users/liuwentong/Project/me/sayit"
SCHEME="SayIt"
CONFIG="Release"
BUILD_DIR="${REPO}/build"
PRODUCT="${BUILD_DIR}/Build/Products/${CONFIG}/SayIt.app"
DEST="/Applications/SayIt.app"
TEAM="95JJW8BPVA"
DEV_IDENTITY="Apple Development: WENTONG LIU (X2U6Z8Z9B7)"
SIGN_MODE="${SIGN_MODE:-auto}"   # auto | manual

echo "==> [1/6] xcodegen generate"
xcodegen generate --spec "${REPO}/project.yml"

echo "==> [2/6] xcodebuild (${CONFIG}) — 签名模式: ${SIGN_MODE}"
if [[ "${SIGN_MODE}" == "manual" ]]; then
  xcodebuild \
    -project "${REPO}/SayIt.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEV_IDENTITY}" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build
else
  xcodebuild \
    -project "${REPO}/SayIt.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    -allowProvisioningUpdates \
    build
fi

echo "==> [3/6] 定位产物"
if [[ ! -d "${PRODUCT}" ]]; then
  echo "ERROR: 构建产物未找到: ${PRODUCT}" >&2
  exit 1
fi
echo "    产物: ${PRODUCT}"

echo "==> [4/6] 退出旧实例并覆盖安装到 /Applications"
killall SayIt 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${PRODUCT}" "${DEST}"

# 清理重复的同 bundle-id 副本：磁盘上残留的旧 .app 会污染 TCC（隐私授权）与
# LaunchServices（重复登记 → 弹错应用、授权错乱）。安装后只保留 /Applications/SayIt.app。
# 幂等：目标不存在时 rm -rf 静默通过。
echo "    清理重复 bundle 副本（仅保留 ${DEST}）"
# 仓库内 Release 输出（已拷贝到 /Applications，源副本不再需要）。
rm -rf "${REPO}/build"
# Xcode DerivedData 里的旧产物（含 SayIt.app 同 bundle-id 副本）。
rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/SayIt-"*

echo "==> [5/6] 验证签名"
codesign --verify --strict "${DEST}"
codesign -dv --verbose=2 "${DEST}"

echo "==> [6/6] 完成"
echo ""
echo "✅ 安装完成: ${DEST}"
echo "提示："
echo "  - 首次打开若被 Gatekeeper 拦截，可在 Finder 右键 → 打开。"
echo "  - 到「系统设置 → 隐私与安全性」授予：麦克风、辅助功能（文字注入/全局热键）。"
echo "  - 默认按住右 ⌘ 说话；首次本地转写会下载模型，可先在设置里用云端 STT。"

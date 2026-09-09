#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> 编译 TokenBar (Release, universal: arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

APP_NAME="TokenBar"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "==> 创建应用包结构: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 定位编译产物：--arch 多架构构建输出于 .build/apple/Products/Release，
# 单架构构建输出于 .build/release，按顺序探测
BIN=""
for candidate in ".build/apple/Products/Release/$APP_NAME" ".build/release/$APP_NAME"; do
    if [ -f "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done
if [ -z "$BIN" ]; then
    echo "错误：未找到编译产物，请检查 swift build 输出" >&2
    exit 1
fi

echo "==> 使用产物: $BIN"
lipo -info "$BIN"

# 复制可执行文件
cp "$BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 复制 Info.plist
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 复制应用图标
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "警告：未找到 Resources/AppIcon.icns，应用将使用默认图标" >&2
fi

# 复制 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 签名身份。
#
# 为什么不用 ad-hoc（`--sign -`）：ad-hoc 签名没有稳定的 designated requirement，
# 钥匙串 ACL 只能按 cdhash 匹配，而 cdhash 每次重新编译都会变 —— 于是每次构建后
# 首次读取钥匙串都会弹一次「TokenBar 想访问钥匙串」。这个授权框卡在主线程上时会
# 冻结整个额度刷新流程（详见 Services/SecretStore.swift 的 prefetch 注释）。
#
# 用固定的开发者证书签名后，ACL 按签名身份 + bundle id 匹配，重新编译不再反复授权。
# 用 SHA-1 哈希而不是证书名精确指定：本机有一张同名但已吊销的证书
# （CSSMERR_TP_CERT_REVOKED），按名字签会撞上它。
# 可用 CODESIGN_IDENTITY 环境变量覆盖；设成 "-" 可退回 ad-hoc。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-6A23BDDF68FFAB1F4512525597A063684EAE0B4D}"

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "==> 执行 ad-hoc 签名（钥匙串会反复要求授权）..."
    codesign --force --deep --sign - "$APP_BUNDLE"
elif security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
    echo "==> 使用开发者证书签名: $CODESIGN_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "警告：签名身份 $CODESIGN_IDENTITY 不可用，退回 ad-hoc 签名" >&2
    echo "      （钥匙串将反复要求授权；用 security find-identity -v -p codesigning 查看可用身份）" >&2
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> 构建完成！产物路径: $APP_BUNDLE"
echo "可以通过以下命令启动测试："
echo "open $APP_BUNDLE"

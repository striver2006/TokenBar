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

# 复制 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> 执行本地签名..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 构建完成！产物路径: $APP_BUNDLE"
echo "可以通过以下命令启动测试："
echo "open $APP_BUNDLE"

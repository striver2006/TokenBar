#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> 编译 TokenBar (Release)..."
swift build -c release

APP_NAME="TokenBar"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "==> 创建应用包结构: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 复制可执行文件
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
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

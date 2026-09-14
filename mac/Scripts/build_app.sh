#!/bin/bash
set -e

# 用法: ./Scripts/build_app.sh [--distribute] [--clean]
#   默认        : signing.local.env 配置的证书签名 → build/TokenBar.app（日常开发/自用）
#   --distribute : Developer ID Application 证书 + Hardened Runtime 签名
#                  → build/dist/TokenBar.app（可提交公证的分发版，见 Scripts/notarize_app.sh）
#   --clean      : 删除 build/ 与 build/dist/ 两个产物路径，然后退出（不构建）。
#
# 启动方式注意：调试请用 `open build/TokenBar.app`，不要在 IDE 集成终端里直接执行
# 可执行文件——macOS 26 的 ControlCenter 会把状态项记到"负责进程"（IDE）名下，IDE 在
# 「系统设置 › 菜单栏 › 应用程序」里若是关闭状态，TokenBar 的图标会被连坐隐藏
# （详见 doc/TROUBLESHOOTING_菜单栏图标不显示.md 第九节）。
#
# 签名身份原则：钥匙串 ACL 的 designated requirement 绑定签名证书——日常构建必须
# **始终用同一张证书**（换身份 = 已授权的钥匙串条目全部要重新授权一轮）。
# 本机自 2026-09-13 起统一用 Developer ID Application（signing.local.env），
# 默认构建与分发版同身份，钥匙串授权只有一套；两者区别只剩 Hardened Runtime、
# 输出目录与是否走公证。--distribute 身份缺失时直接报错退出，绝不静默降级。
DISTRIBUTE=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --distribute) DISTRIBUTE=1 ;;
        --clean) CLEAN=1 ;;
        *) echo "未知参数: $arg（可用: --distribute --clean）" >&2; exit 1 ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [ "$CLEAN" -eq 1 ]; then
    echo "==> 删除构建产物..."
    rm -rf "$PROJECT_DIR/build/TokenBar.app" "$PROJECT_DIR/build/dist/TokenBar.app"
    echo "==> 清理完成"
    exit 0
fi

echo "==> 编译 TokenBar (Release, universal: arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

APP_NAME="TokenBar"
if [ "$DISTRIBUTE" -eq 1 ]; then
    BUILD_DIR="$PROJECT_DIR/build/dist"
else
    BUILD_DIR="$PROJECT_DIR/build"
fi
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
# 建议用 SHA-1 哈希而不是证书名指定：同名证书可能有多张（例如已吊销的旧证书，
# 按名字签会撞上它报 CSSMERR_TP_CERT_REVOKED）。
#
# 签名身份是每台机器各自的本地配置，不进仓库。取值优先级：
#   1. CODESIGN_IDENTITY 环境变量
#   2. Scripts/signing.local.env（未跟踪，见同目录 signing.local.env.example）
#   3. 都没有则退回 ad-hoc
SIGNING_ENV="$PROJECT_DIR/Scripts/signing.local.env"
if [ -z "$CODESIGN_IDENTITY" ] && [ -z "$CODESIGN_DISTRIBUTION_IDENTITY" ] && [ -f "$SIGNING_ENV" ]; then
    # shellcheck source=/dev/null
    . "$SIGNING_ENV"
fi

if [ "$DISTRIBUTE" -eq 1 ]; then
    # ---- 分发签名：Developer ID Application + Hardened Runtime（公证的硬性要求）----
    # 身份优先级：CODESIGN_DISTRIBUTION_IDENTITY 环境变量 → signing.local.env
    #            → 钥匙串里自动探测第一张 "Developer ID Application" 证书。
    # 找不到就报错退出：发布产物绝不能静默降级成开发签名或 ad-hoc。
    # find-identity 输出形如 `   5) <SHA-1哈希> "Developer ID Application: ..."`，哈希在第 2 列
    CODESIGN_DISTRIBUTION_IDENTITY="${CODESIGN_DISTRIBUTION_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
    if [ -z "$CODESIGN_DISTRIBUTION_IDENTITY" ] || \
       ! security find-identity -v -p codesigning | grep -q "$CODESIGN_DISTRIBUTION_IDENTITY"; then
        echo "错误：未找到可用的 Developer ID Application 证书，无法构建分发版。" >&2
        echo "  - 确认已在 https://developer.apple.com 创建 Developer ID 证书并导入本机钥匙串" >&2
        echo "  - 或在 Scripts/signing.local.env 里显式配置 CODESIGN_DISTRIBUTION_IDENTITY" >&2
        exit 1
    fi
    echo "==> 使用 Developer ID 证书签名（Hardened Runtime）: $CODESIGN_DISTRIBUTION_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_DISTRIBUTION_IDENTITY" --options runtime --timestamp "$APP_BUNDLE"
    echo "==> 构建完成！分发产物路径: $APP_BUNDLE"
    echo "下一步：提交公证并落票："
    echo "  ./Scripts/notarize_app.sh"
else
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

    if [ "$CODESIGN_IDENTITY" = "-" ]; then
        echo "==> 执行 ad-hoc 签名（钥匙串会反复要求授权）..."
        echo "    如需固定签名身份：cp Scripts/signing.local.env.example Scripts/signing.local.env 并填入" >&2
        echo "    security find-identity -v -p codesigning 里的 SHA-1 哈希" >&2
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
fi

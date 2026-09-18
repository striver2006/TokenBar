#!/bin/bash
set -e

# 把已签名的 TokenBar.app 打成 macOS 安装用 DMG（含「拖到 Applications」快捷方式）。
#
# 用法: ./Scripts/make_dmg.sh [app路径] [--notarize] [--profile 公证凭据名]
#   app 路径默认 build/dist/TokenBar.app（即 build_app.sh --distribute 的产物）
#   --notarize  额外把 DMG 提交公证并落票（分发给他人才需要；本机自用可跳过）
#   --profile   公证凭据名，默认取环境变量 NOTARY_PROFILE 或 "TokenBar-notary"
#
# 产物：与 app 同目录的 TokenBar-v<版本>-macOS-universal.dmg
#
# 前置条件：app 必须已用 Developer ID Application 证书签名
# （DMG 只是容器，里面的 app 签名决定 Gatekeeper 是否放行）。
# 完整分发链路：
#   ./Scripts/build_app.sh --distribute   # Developer ID + Hardened Runtime
#   ./Scripts/notarize_app.sh             # app 公证 + 落票（可选但推荐）
#   ./Scripts/make_dmg.sh --notarize      # 打 DMG，并把 DMG 也公证落票

APP_PATH=""
NOTARIZE=0
PROFILE="${NOTARY_PROFILE:-TokenBar-notary}"
while [ $# -gt 0 ]; do
    case "$1" in
        --notarize) NOTARIZE=1; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        -*) echo "未知参数: $1（可用: --notarize --profile <名称>）" >&2; exit 1 ;;
        *) APP_PATH="$1"; shift ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$PROJECT_DIR/build/dist/TokenBar.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "错误：未找到 $APP_PATH" >&2
    echo "请先执行: ./Scripts/build_app.sh --distribute" >&2
    exit 1
fi

# ---- 前置校验：必须 Developer ID 签名，否则装到别人机器上会被 Gatekeeper 拦 ----
SIGN_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if ! grep -q "Developer ID Application" <<<"$SIGN_INFO"; then
    echo "错误：$APP_PATH 不是 Developer ID 签名（当前为：$(grep -m1 Authority <<<"$SIGN_INFO")）" >&2
    echo "请用 ./Scripts/build_app.sh --distribute 重新构建。" >&2
    exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DIST_DIR="$(cd "$(dirname "$APP_PATH")" && pwd)"
DMG_PATH="$DIST_DIR/$APP_NAME-v$VERSION-macOS-universal.dmg"
VOLUME_NAME="$APP_NAME"

echo "==> 准备 DMG 内容（$APP_NAME v$VERSION）..."
STAGE="$(mktemp -d -t tokenbar-dmg)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

# DMG 自身也签名：公证要求容器有 Developer ID 签名，且能让磁盘映像通过 Gatekeeper 校验
IDENTITY="${CODESIGN_DISTRIBUTION_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
if [ -n "$IDENTITY" ]; then
    echo "==> 签名 DMG（Developer ID）..."
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
fi

if [ "$NOTARIZE" -eq 1 ]; then
    echo "==> 提交 DMG 公证（凭据: $PROFILE）..."
    NOTARY_OUTPUT="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait 2>&1)" \
        || { echo "$NOTARY_OUTPUT" >&2; exit 1; }
    echo "$NOTARY_OUTPUT"
    if ! grep -q "status: Accepted" <<<"$NOTARY_OUTPUT"; then
        echo "错误：DMG 公证未通过，见上方输出。" >&2
        exit 1
    fi
    echo "==> 落票（staple）..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

echo "==> Gatekeeper 评估..."
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" 2>&1 || true

shasum -a 256 "$DMG_PATH"
echo "==> 完成 ✅ DMG 产物: $DMG_PATH"

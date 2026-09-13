#!/bin/bash
set -e

# 提交公证 → 落票（staple）→ 产出发布 zip。
#
# 用法: ./Scripts/notarize_app.sh [app路径] [--profile 公证凭据名]
#   app 路径默认 build/dist/TokenBar.app（即 build_app.sh --distribute 的产物）
#   凭据名默认取环境变量 NOTARY_PROFILE，或 "TokenBar-notary"
#
# 前置条件（一次性，本机已配置则跳过）：
#   1. build_app.sh --distribute 构建的 Developer ID + Hardened Runtime 签名产物
#   2. App Store Connect API Key 存进钥匙串：
#      xcrun notarytool store-credentials TokenBar-notary \
#        --key-id <KeyID> --issuer <IssuerID> --key </path/to/AuthKey.p8>
#
# 产物：与 app 同目录的 TokenBar-v<版本>-macOS-universal.zip（落票后重新压缩，
# 命名与 CI Release 一致，可直接作为 GitHub Release 附件）。

APP_PATH=""
PROFILE="${NOTARY_PROFILE:-TokenBar-notary}"
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        *) APP_PATH="$1"; shift ;;
    esac
done
APP_PATH="${APP_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/dist/TokenBar.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "错误：未找到 $APP_PATH" >&2
    echo "请先执行: ./Scripts/build_app.sh --distribute" >&2
    exit 1
fi

# ---- 前置校验 ----
SIGN_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if ! grep -q "Developer ID Application" <<<"$SIGN_INFO"; then
    echo "错误：$APP_PATH 不是 Developer ID 签名（当前为：$(grep -m1 Authority <<<"$SIGN_INFO")）" >&2
    echo "公证只接受 Developer ID 证书。请用 ./Scripts/build_app.sh --distribute 重新构建。" >&2
    exit 1
fi
if ! codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -q "runtime"; then
    echo "错误：签名未启用 Hardened Runtime（--options runtime），公证会被拒绝。" >&2
    echo "请用 ./Scripts/build_app.sh --distribute 重新构建。" >&2
    exit 1
fi

# 凭据存在性用 notarytool 自身探测（它会查钥匙串；马上要联网提交，预检无额外成本。
# 不用 security find-generic-password：notarytool 存储条目的 service 名并非公开约定，按名查会漏判）
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "错误：钥匙串里没有公证凭据 \"$PROFILE\"。一次性配置方法：" >&2
    echo "  1. https://appstoreconnect.apple.com → 用户和访问 → 集成/App Store Connect API → 密钥" >&2
    echo "     创建密钥（需 Admin 角色），下载 .p8，记下 Key ID 与 Issuer ID" >&2
    echo "  2. xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "       --key-id <KeyID> --issuer <IssuerID> --key </path/to/AuthKey_XXXX.p8>" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DIST_DIR="$(dirname "$APP_PATH")"
ZIP_PATH="$DIST_DIR/TokenBar-v$VERSION-macOS-universal.zip"

echo "==> 提交公证（凭据: $PROFILE，版本: v$VERSION）..."
SUBMIT_ZIP="$(mktemp -t TokenBar-notary).zip"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
SUBMIT_OUTPUT="$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait 2>&1)" \
    || { echo "$SUBMIT_OUTPUT" >&2; exit 1; }
echo "$SUBMIT_OUTPUT"
if grep -q "status: Accepted" <<<"$SUBMIT_OUTPUT"; then
    echo "==> 公证通过 ✅"
elif grep -q "status: Invalid" <<<"$SUBMIT_OUTPUT"; then
    echo "错误：公证被拒绝。查看详细日志定位问题：" >&2
    SUBMISSION_ID="$(grep -oE 'id: [0-9a-f-]{36}' <<<"$SUBMIT_OUTPUT" | head -1 | cut -d' ' -f2)"
    [ -n "$SUBMISSION_ID" ] && echo "  xcrun notarytool log $SUBMISSION_ID --keychain-profile \"$PROFILE\"" >&2
    exit 1
else
    echo "错误：未预期的公证结果，见上方输出。" >&2
    exit 1
fi
rm -f "$SUBMIT_ZIP"

echo "==> 落票（staple）..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Gatekeeper 校验..."
spctl -a -vv --assess "$APP_PATH"

echo "==> 打包发布 zip（落票后）..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"

echo "==> 完成 ✅ 发布产物: $ZIP_PATH"
echo "可直接作为 GitHub Release 附件上传（与 CI 的命名规则一致）。"

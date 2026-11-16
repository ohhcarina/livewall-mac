#!/bin/zsh
# Packs dist/LiveWall.app into dist/LiveWall-<version>.dmg (run build-app.sh first).
# Notarized release: build with SIGN_IDENTITY="Developer ID Application: …", then run this with the same SIGN_IDENTITY
# and NOTARY_ENV=<file with ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH> (an App Store Connect team API key): the dmg is
# signed, sent to Apple's notary service and stapled. Without SIGN_IDENTITY the dmg is unsigned and carries a note on
# how to open it past Gatekeeper.
set -e
cd "${0:A:h}/.."
VERSION="${VERSION:-0.1.0}"
STAGE="dist/dmg-stage"
DMG="dist/LiveWall-$VERSION.dmg"

[[ -d dist/LiveWall.app ]] || { echo "dist/LiveWall.app not found: run scripts/build-app.sh first" >&2; exit 1; }
rm -rf -- "${STAGE:?}"
mkdir -p "$STAGE"
cp -R dist/LiveWall.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[[ -z "$SIGN_IDENTITY" ]] && cat > "$STAGE/首次打开必读.txt" <<'TXT'
这一版 LiveWall 没有经过 Apple 公证，第一次打开 macOS 会拦住它。

1. 把 LiveWall 拖进「应用程序」。
2. 双击打开，出现「无法验证开发者」时点「完成」。
3. 打开「系统设置 › 隐私与安全性」，拉到最下面，在 LiveWall 那一行点「仍要打开」。
   只需要这一次。

也可以在终端里执行：  xattr -dr com.apple.quarantine /Applications/LiveWall.app
TXT
rm -f -- "${DMG:?}"
hdiutil create -volname "LiveWall $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf -- "${STAGE:?}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --display --verbose=2 dist/LiveWall.app 2>&1 | grep -q "Authority=Developer ID Application" ||
        { echo "dist/LiveWall.app is not signed with a Developer ID: rebuild with SIGN_IDENTITY" >&2; exit 1; }
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    if [[ -n "$NOTARY_ENV" ]]; then
        source "$NOTARY_ENV"
        xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    fi
fi
echo "-> $DMG ($(du -h "$DMG" | cut -f1))"

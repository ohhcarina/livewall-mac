#!/bin/zsh
# Builds dist/<PRODUCT>.app (universal, ad-hoc signed unless SIGN_IDENTITY is set).
#   VERSION=0.1.0 scripts/build-app.sh
# For a notarized release set SIGN_IDENTITY to the Developer ID Application identity, then see make-dmg.sh.
set -e
cd "${0:A:h}/.."
VERSION="${VERSION:-0.1.0}"
PRODUCT="${PRODUCT:-LiveWall}"
PKG="Packaging"; [[ "$PRODUCT" != LiveWall ]] && PKG="Packaging/$PRODUCT"
APP="dist/$PRODUCT.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$PRODUCT"

rm -rf -- "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
# Package.swift links every binary as built with the real SDK (`sdkVersion`): recorded as 14.0, the app falls back to
# the old look (no Liquid Glass) and writes HDR covers ~3x too bright. Stop if that constant lags behind Xcode's SDK.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if otool -l "$APP/Contents/MacOS/$PRODUCT" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; f=0}' | grep -qv "^$SDK_VERSION\$"; then
    echo "error: $PRODUCT records an SDK other than $SDK_VERSION: set sdkVersion in Package.swift" >&2
    exit 1
fi
sed "s/__VERSION__/$VERSION/g" $PKG/Info.plist > "$APP/Contents/Info.plist"

# Packaging/AppIcon.icon is an Icon Composer document (edited as files). actool turns it into Assets.car (the layered
# icon macOS 26+ renders live) plus AppIcon.icns (the flat fallback macOS 14/15 shows).
xcrun actool $PKG/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "dist/actool-partial.plist" >/dev/null
rm -f dist/actool-partial.plist

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "-> $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/$PRODUCT"))"

# A stable place to double-click the latest build: a real copy at <project root>/<PRODUCT>.app (a symlink would make
# the app show its own icon with an alias badge). The repo sits at <project root>/livewall or, as a worktree, at
# <project root>/_worktrees/<name>; skipped when neither parent holds _handoff.
ROOT="${0:A:h:h:h:h}"
[[ -d "$ROOT/_handoff" ]] || ROOT="${ROOT:h}"
if [[ -d "$ROOT/_handoff" ]]; then
    rm -rf -- "$ROOT/$PRODUCT.app"
    ditto "$APP" "$ROOT/$PRODUCT.app"
    echo "-> ${ROOT:A}/$PRODUCT.app"
fi

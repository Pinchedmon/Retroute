#!/bin/sh
# Builds Retroute.app and dist/Retroute-<version>.zip.
# The mihomo core is downloaded from the official MetaCubeX release and checked against a pinned SHA-256.
set -eu
cd "$(dirname "$0")"

MIHOMO_VERSION=v1.19.31
# go1.20 / amd64-v1 build: the last Go that runs on macOS 10.13, and no AVX requirement for old CPUs.
MIHOMO_ASSET="mihomo-darwin-amd64-v1-go120-${MIHOMO_VERSION}.gz"
MIHOMO_SHA256=3c22fd940e6718a52bebbb942b72535c497944364802ddd9184b1b5027dee48a

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP=build/Retroute.app

mkdir -p build/cache dist
CORE_GZ="build/cache/$MIHOMO_ASSET"
if [ ! -f "$CORE_GZ" ]; then
    curl -fL -o "$CORE_GZ" "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${MIHOMO_ASSET}"
fi
echo "$MIHOMO_SHA256  $CORE_GZ" | shasum -a 256 -c -

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
clang -fobjc-arc -O2 -mmacosx-version-min=10.13 -arch x86_64 \
    -framework Cocoa -framework IOKit \
    Sources/main.m -o "$APP/Contents/MacOS/Retroute"
gunzip -c "$CORE_GZ" > "$APP/Contents/Resources/mihomo"
chmod +x "$APP/Contents/Resources/mihomo"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Ad-hoc signature: no Apple Developer ID, so Gatekeeper still asks on first launch (see README).
codesign --force --deep --sign - "$APP"

rm -f "dist/Retroute-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/Retroute-$VERSION.zip"
shasum -a 256 "dist/Retroute-$VERSION.zip"

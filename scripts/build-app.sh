#!/bin/bash
# Builds the package and assembles an ad-hoc signed build/Spool.app.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

# A DEVELOPER_DIR you set wins. Otherwise use Xcode when it is installed in the usual place
# (xcode-select may point to the Command Line Tools), and leave the toolchain choice alone if not.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

set -a
# shellcheck source=../Config/build.env
. Config/build.env
set +a
: "${BUNDLE_ID_PREFIX:?BUNDLE_ID_PREFIX missing in Config/build.env}"
: "${VERSION:?VERSION missing in Config/build.env}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Spool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Spool" "$APP/Contents/MacOS/Spool"
cp "$BIN/spool-statusline" "$APP/Contents/MacOS/spool-statusline"

scripts/check-strings.sh

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

for lang in en uk; do
    plutil -lint -s "Resources/$lang.lproj/Localizable.strings"
    cp -R "Resources/$lang.lproj" "$APP/Contents/Resources/"
done

sed -e "s|\${BUNDLE_ID_PREFIX}|$BUNDLE_ID_PREFIX|g" \
    -e "s|\${VERSION}|$VERSION|g" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/spool-statusline"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($CONFIG)"

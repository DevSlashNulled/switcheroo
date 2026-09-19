#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
switcheroo_binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p dist
switcheroo_staging="$(mktemp -d "$PWD/dist/.switcheroo-build.XXXXXX")"
switcheroo_cleanup() {
    if [ -e "$switcheroo_staging/Previous.app" ] && [ ! -e dist/Switcheroo.app ]; then
        printf 'Previous build preserved at %s/Previous.app\n' "$switcheroo_staging" >&2
    else
        rm -rf "$switcheroo_staging"
    fi
}
trap switcheroo_cleanup EXIT
switcheroo_bundle="$switcheroo_staging/Switcheroo.app"
mkdir -p "$switcheroo_bundle/Contents/MacOS" "$switcheroo_bundle/Contents/Resources"
cp "$switcheroo_binary_dir/Switcheroo" "$switcheroo_bundle/Contents/MacOS/Switcheroo"
cp Resources/Info.plist "$switcheroo_bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$switcheroo_staging/Switcheroo.iconset"
iconutil -c icns "$switcheroo_staging/Switcheroo.iconset" -o "$switcheroo_bundle/Contents/Resources/Switcheroo.icns"
codesign --force --sign - "$switcheroo_bundle"
codesign --verify --strict "$switcheroo_bundle"
# Replacing whole bundles also keeps a running development copy's executable intact.
if [ -e dist/Switcheroo.app ]; then
    mv dist/Switcheroo.app "$switcheroo_staging/Previous.app"
fi
if ! mv "$switcheroo_bundle" dist/Switcheroo.app; then
    if [ -e "$switcheroo_staging/Previous.app" ]; then
        mv "$switcheroo_staging/Previous.app" dist/Switcheroo.app
    fi
    exit 1
fi
printf 'Built %s/dist/Switcheroo.app\n' "$PWD"

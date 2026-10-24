#!/bin/sh
set -eu
wavepaper_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$wavepaper_root"
wavepaper_configuration=${1:-release}
case "$wavepaper_configuration" in debug|release) ;; *) exit 2 ;; esac
swift build -c "$wavepaper_configuration" --arch arm64 --product Wavepaper
wavepaper_bin=$(swift build -c "$wavepaper_configuration" --arch arm64 --show-bin-path)
wavepaper_app="$wavepaper_root/dist/Wavepaper.app"
mkdir -p "$wavepaper_app/Contents/MacOS" "$wavepaper_app/Contents/Resources" .build/icon-tools
install -m 755 "$wavepaper_bin/Wavepaper" "$wavepaper_app/Contents/MacOS/Wavepaper"
cp Support/Info.plist "$wavepaper_app/Contents/Info.plist"
if [ ! -f .build/icon-tools/GenerateIcon ] || [ Tools/GenerateIcon.swift -nt .build/icon-tools/GenerateIcon ]; then
    xcrun swiftc -swift-version 6 Tools/GenerateIcon.swift -o .build/icon-tools/GenerateIcon
fi
if [ ! -f .build/icon-tools/AppIcon.icns ] || [ .build/icon-tools/GenerateIcon -nt .build/icon-tools/AppIcon.icns ]; then
    .build/icon-tools/GenerateIcon .build/icon-tools/AppIcon.iconset
    /usr/bin/iconutil -c icns .build/icon-tools/AppIcon.iconset -o .build/icon-tools/AppIcon.icns
fi
cp .build/icon-tools/AppIcon.icns "$wavepaper_app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --identifier local.wavepaper.app "$wavepaper_app"
echo "$wavepaper_app"

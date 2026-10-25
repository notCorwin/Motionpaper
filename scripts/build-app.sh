#!/bin/sh
set -eu
wavepaper_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$wavepaper_root"
wavepaper_configuration=${1:-release}
case "$wavepaper_configuration" in debug|release) ;; *) exit 2 ;; esac

wavepaper_commit=$(git rev-parse HEAD)
case "$wavepaper_commit" in *[!0-9a-f]*|'') echo "error: expected a lowercase full git commit hash" >&2; exit 1 ;; esac
[ "${#wavepaper_commit}" -eq 40 ] || { echo "error: expected a lowercase full git commit hash" >&2; exit 1; }

wavepaper_repository=${GITHUB_REPOSITORY:-}
if [ -z "$wavepaper_repository" ]; then
    wavepaper_origin=$(git remote get-url origin 2>/dev/null || true)
    case "$wavepaper_origin" in
        https://github.com/*|ssh://git@github.com/*) wavepaper_repository=${wavepaper_origin#*github.com/} ;;
        git@github.com:*) wavepaper_repository=${wavepaper_origin#git@github.com:} ;;
        *) echo "error: set GITHUB_REPOSITORY or configure a GitHub origin" >&2; exit 1 ;;
    esac
    wavepaper_repository=${wavepaper_repository%.git}
fi
case "$wavepaper_repository" in
    */*/*|/*|*/|''|*[!A-Za-z0-9_./-]*) echo "error: invalid GitHub repository slug: $wavepaper_repository" >&2; exit 1 ;;
    */*) ;;
    *) echo "error: expected GITHUB_REPOSITORY in owner/repository form" >&2; exit 1 ;;
esac

wavepaper_update_url="https://github.com/$wavepaper_repository/releases/latest/download/update.json"
swift build -c "$wavepaper_configuration" --arch arm64 --product Wavepaper
wavepaper_bin=$(swift build -c "$wavepaper_configuration" --arch arm64 --show-bin-path)
wavepaper_app="$wavepaper_root/dist/Wavepaper.app"
mkdir -p "$wavepaper_app/Contents/MacOS" "$wavepaper_app/Contents/Resources" .build/icon-tools
install -m 755 "$wavepaper_bin/Wavepaper" "$wavepaper_app/Contents/MacOS/Wavepaper"
cp Support/Info.plist "$wavepaper_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :WavepaperCommit $wavepaper_commit" "$wavepaper_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :WavepaperUpdateURL $wavepaper_update_url" "$wavepaper_app/Contents/Info.plist"
if [ ! -f .build/icon-tools/GenerateIcon ] || [ Tools/GenerateIcon.swift -nt .build/icon-tools/GenerateIcon ]; then
    xcrun swiftc -swift-version 6 Tools/GenerateIcon.swift -o .build/icon-tools/GenerateIcon
fi
if [ ! -f .build/icon-tools/AppIcon.icns ] || [ .build/icon-tools/GenerateIcon -nt .build/icon-tools/AppIcon.icns ]; then
    .build/icon-tools/GenerateIcon .build/icon-tools/AppIcon.iconset
    /usr/bin/iconutil -c icns .build/icon-tools/AppIcon.iconset -o .build/icon-tools/AppIcon.icns
fi
cp .build/icon-tools/AppIcon.icns "$wavepaper_app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --identifier local.wavepaper.app "$wavepaper_app"
/usr/bin/codesign --verify --deep --strict "$wavepaper_app"
echo "$wavepaper_app"

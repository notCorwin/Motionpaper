#!/bin/sh
set -eu
motionpaper_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$motionpaper_root"
motionpaper_configuration=${1:-release}
case "$motionpaper_configuration" in debug|release) ;; *) exit 2 ;; esac

motionpaper_commit=$(git rev-parse HEAD)
case "$motionpaper_commit" in *[!0-9a-f]*|'') echo "error: expected a lowercase full git commit hash" >&2; exit 1 ;; esac
[ "${#motionpaper_commit}" -eq 40 ] || { echo "error: expected a lowercase full git commit hash" >&2; exit 1; }

motionpaper_repository=${GITHUB_REPOSITORY:-}
if [ -z "$motionpaper_repository" ]; then
    motionpaper_origin=$(git remote get-url origin 2>/dev/null || true)
    case "$motionpaper_origin" in
        https://github.com/*|ssh://git@github.com/*) motionpaper_repository=${motionpaper_origin#*github.com/} ;;
        git@github.com:*) motionpaper_repository=${motionpaper_origin#git@github.com:} ;;
        *) echo "error: set GITHUB_REPOSITORY or configure a GitHub origin" >&2; exit 1 ;;
    esac
    motionpaper_repository=${motionpaper_repository%.git}
fi
case "$motionpaper_repository" in
    */*/*|/*|*/|''|*[!A-Za-z0-9_./-]*) echo "error: invalid GitHub repository slug: $motionpaper_repository" >&2; exit 1 ;;
    */*) ;;
    *) echo "error: expected GITHUB_REPOSITORY in owner/repository form" >&2; exit 1 ;;
esac

motionpaper_repository_url="https://github.com/$motionpaper_repository"
motionpaper_update_url="https://api.github.com/repos/$motionpaper_repository/releases/latest"
swift build -c "$motionpaper_configuration" --arch arm64
motionpaper_arm64_bin=$(swift build -c "$motionpaper_configuration" --arch arm64 --show-bin-path)
swift build -c "$motionpaper_configuration" --arch x86_64
motionpaper_x86_64_bin=$(swift build -c "$motionpaper_configuration" --arch x86_64 --show-bin-path)
motionpaper_app="$motionpaper_root/dist/Motionpaper.app"
mkdir -p "$motionpaper_app/Contents/MacOS" "$motionpaper_app/Contents/Resources" "$motionpaper_app/Contents/Helpers" .build/icon-tools
motionpaper_executable="$motionpaper_app/Contents/MacOS/Motionpaper"
motionpaper_updater="$motionpaper_app/Contents/Helpers/MotionpaperUpdater"
rm -f "$motionpaper_executable" "$motionpaper_updater"
xcrun lipo -create "$motionpaper_arm64_bin/Motionpaper" "$motionpaper_x86_64_bin/Motionpaper" -output "$motionpaper_executable"
xcrun lipo -create "$motionpaper_arm64_bin/MotionpaperUpdater" "$motionpaper_x86_64_bin/MotionpaperUpdater" -output "$motionpaper_updater"
chmod 755 "$motionpaper_executable" "$motionpaper_updater"
/usr/bin/codesign --force --sign - --identifier local.motionpaper.updater "$motionpaper_updater"
cp Support/Info.plist "$motionpaper_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MotionpaperCommit $motionpaper_commit" "$motionpaper_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MotionpaperUpdateURL $motionpaper_update_url" "$motionpaper_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MotionpaperRepositoryURL $motionpaper_repository_url" "$motionpaper_app/Contents/Info.plist"
if [ ! -f .build/icon-tools/GenerateIcon ] || [ Tools/GenerateIcon.swift -nt .build/icon-tools/GenerateIcon ]; then
    xcrun swiftc -swift-version 6 Tools/GenerateIcon.swift -o .build/icon-tools/GenerateIcon
fi
if [ ! -f .build/icon-tools/AppIcon.icns ] || [ ! -f .build/icon-tools/StatusIcon.png ] || \
   [ .build/icon-tools/GenerateIcon -nt .build/icon-tools/AppIcon.icns ] || \
   [ assets/AppIcon.png -nt .build/icon-tools/AppIcon.icns ]; then
    .build/icon-tools/GenerateIcon assets/AppIcon.png .build/icon-tools
    /usr/bin/iconutil -c icns .build/icon-tools/AppIcon.iconset -o .build/icon-tools/AppIcon.icns
fi
cp .build/icon-tools/AppIcon.icns "$motionpaper_app/Contents/Resources/AppIcon.icns"
cp .build/icon-tools/StatusIcon.png "$motionpaper_app/Contents/Resources/StatusIcon.png"
/usr/bin/codesign --force --sign - --identifier local.motionpaper.app "$motionpaper_app"
sh scripts/verify-app.sh "$motionpaper_app"
echo "$motionpaper_app"

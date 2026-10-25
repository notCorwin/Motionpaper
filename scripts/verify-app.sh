#!/bin/sh
set -eu

motionpaper_app=${1:-dist/Motionpaper.app}
motionpaper_executable="$motionpaper_app/Contents/MacOS/Motionpaper"
motionpaper_updater="$motionpaper_app/Contents/Helpers/MotionpaperUpdater"

[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$motionpaper_app/Contents/Info.plist")" = "15.0" ] || {
    echo "error: the app bundle must support macOS 15.0" >&2
    exit 1
}

for motionpaper_binary in "$motionpaper_executable" "$motionpaper_updater"; do
    [ -x "$motionpaper_binary" ] || {
        echo "error: missing executable: $motionpaper_binary" >&2
        exit 1
    }
    xcrun lipo "$motionpaper_binary" -verify_arch arm64 x86_64
    for motionpaper_arch in arm64 x86_64; do
        if ! xcrun vtool -show-build -arch "$motionpaper_arch" "$motionpaper_binary" |
            awk '$1 == "platform" && $2 == "MACOS" { macos = 1 } $1 == "minos" { minos = $2 } END { exit !(macos && minos == "15.0") }'; then
            echo "error: $motionpaper_binary ($motionpaper_arch) must target macOS 15.0" >&2
            exit 1
        fi
    done
done

for motionpaper_arch in arm64 x86_64; do
    if ! xcrun otool -l -arch "$motionpaper_arch" "$motionpaper_executable" |
        awk '
            $1 == "cmd" { command = $2 }
            $1 == "name" && $2 ~ /Wallpaper[.]framework/ {
                found = 1
                if (command == "LC_LOAD_WEAK_DYLIB") weak = 1
                else strong = 1
            }
            END { exit !(found && weak && !strong) }
        '; then
        echo "error: Wallpaper.framework must be weak-linked for $motionpaper_arch" >&2
        exit 1
    fi
    if ! xcrun nm -m -arch "$motionpaper_arch" "$motionpaper_executable" |
        awk '
            /\(undefined\).*Wallpaper.*takeIdle/ {
                count++
                if ($0 !~ /weak external/) strong = 1
            }
            END { exit !(count == 2 && !strong) }
        '; then
        echo "error: the Swift wallpaper method and async descriptor must be weak imports for $motionpaper_arch" >&2
        exit 1
    fi
done

/usr/bin/codesign --verify --all-architectures --deep --strict "$motionpaper_app"

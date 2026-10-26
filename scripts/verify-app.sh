#!/bin/sh
set -eu

motionpaper_app=${1:-dist/Motionpaper.app}
motionpaper_executable="$motionpaper_app/Contents/MacOS/Motionpaper"
motionpaper_updater="$motionpaper_app/Contents/Helpers/MotionpaperUpdater"

[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$motionpaper_app/Contents/Info.plist")" = "15.0" ] || {
    echo "error: the app bundle must support macOS 15.0" >&2
    exit 1
}

motionpaper_info="$motionpaper_app/Contents/Info.plist"
motionpaper_channel=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperReleaseChannel' "$motionpaper_info")
motionpaper_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$motionpaper_info")
motionpaper_bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$motionpaper_info")
motionpaper_commit=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperCommit' "$motionpaper_info")
motionpaper_repository_url=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperRepositoryURL' "$motionpaper_info")
motionpaper_update_url=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperUpdateURL' "$motionpaper_info")
motionpaper_stable_update_url=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperStableUpdateURL' "$motionpaper_info")
case "$motionpaper_channel" in stable|autobuild) ;; *) echo "error: invalid MotionpaperReleaseChannel metadata" >&2; exit 1 ;; esac
[ "$motionpaper_version" = "$motionpaper_bundle_version" ] || {
    echo "error: CFBundleShortVersionString and CFBundleVersion must match" >&2
    exit 1
}
case "$motionpaper_version" in *[!0-9.]*|.*|*.) echo "error: invalid three-part bundle version" >&2; exit 1 ;; esac
case "$motionpaper_version" in *.*.*) ;; *) echo "error: invalid three-part bundle version" >&2; exit 1 ;; esac
motionpaper_major=${motionpaper_version%%.*}
motionpaper_remainder=${motionpaper_version#*.}
motionpaper_minor=${motionpaper_remainder%%.*}
motionpaper_patch=${motionpaper_remainder#*.}
case "$motionpaper_patch" in *.*) echo "error: invalid three-part bundle version" >&2; exit 1 ;; esac
for motionpaper_component in "$motionpaper_major" "$motionpaper_minor" "$motionpaper_patch"; do
    case "$motionpaper_component" in ''|*[!0-9]*) echo "error: invalid three-part bundle version" >&2; exit 1 ;; esac
    [ "$motionpaper_component" = 0 ] || case "$motionpaper_component" in 0*) echo "error: leading zero in bundle version" >&2; exit 1 ;; esac
done
case "$motionpaper_commit" in *[!0-9a-f]*|'') echo "error: invalid MotionpaperCommit metadata" >&2; exit 1 ;; esac
[ "${#motionpaper_commit}" -eq 40 ] || { echo "error: invalid MotionpaperCommit metadata" >&2; exit 1; }
case "$motionpaper_repository_url" in https://github.com/*/*) ;; *) echo "error: invalid MotionpaperRepositoryURL metadata" >&2; exit 1 ;; esac
motionpaper_repository=${motionpaper_repository_url#https://github.com/}
case "$motionpaper_repository" in
    */*/*|/*|*/|''|*[!A-Za-z0-9_./-]*) echo "error: invalid MotionpaperRepositoryURL metadata" >&2; exit 1 ;;
    */*) ;;
    *) echo "error: invalid MotionpaperRepositoryURL metadata" >&2; exit 1 ;;
esac
motionpaper_expected_stable_url="https://api.github.com/repos/$motionpaper_repository/releases?per_page=100"
[ "$motionpaper_stable_update_url" = "$motionpaper_expected_stable_url" ] || {
    echo "error: MotionpaperStableUpdateURL does not match the repository release source" >&2
    exit 1
}
if [ "$motionpaper_channel" = stable ]; then
    motionpaper_expected_update_url=$motionpaper_expected_stable_url
else
    motionpaper_expected_update_url="https://api.github.com/repos/$motionpaper_repository/releases/latest"
fi
[ "$motionpaper_update_url" = "$motionpaper_expected_update_url" ] || {
    echo "error: MotionpaperUpdateURL does not match the release channel source" >&2
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

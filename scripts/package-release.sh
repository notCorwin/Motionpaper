#!/bin/sh
set -eu

motionpaper_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$motionpaper_root"

motionpaper_app=${1:-dist/Motionpaper.app}
case "$motionpaper_app" in /*) ;; *) motionpaper_app="$motionpaper_root/$motionpaper_app" ;; esac
[ -d "$motionpaper_app" ] || { echo "error: app bundle not found: $motionpaper_app" >&2; exit 1; }

motionpaper_commit=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperCommit' "$motionpaper_app/Contents/Info.plist")
case "$motionpaper_commit" in *[!0-9a-f]*|'') echo "error: app bundle has an invalid MotionpaperCommit" >&2; exit 1 ;; esac
[ "${#motionpaper_commit}" -eq 40 ] || { echo "error: app bundle has an invalid MotionpaperCommit" >&2; exit 1; }

motionpaper_channel=$(/usr/libexec/PlistBuddy -c 'Print :MotionpaperReleaseChannel' "$motionpaper_app/Contents/Info.plist")
motionpaper_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$motionpaper_app/Contents/Info.plist")
motionpaper_bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$motionpaper_app/Contents/Info.plist")
case "$motionpaper_channel" in stable|autobuild) ;; *) echo "error: app bundle has an invalid MotionpaperReleaseChannel" >&2; exit 1 ;; esac
[ "$motionpaper_version" = "$motionpaper_bundle_version" ] || {
    echo "error: app bundle short version and build version do not match" >&2
    exit 1
}
case "$motionpaper_version" in
    *[!0-9.]*|.*|*.) echo "error: app bundle has an invalid three-part version" >&2; exit 1 ;;
    *.*.*) ;;
    *) echo "error: app bundle has an invalid three-part version" >&2; exit 1 ;;
esac
motionpaper_major=${motionpaper_version%%.*}
motionpaper_remainder=${motionpaper_version#*.}
motionpaper_minor=${motionpaper_remainder%%.*}
motionpaper_patch=${motionpaper_remainder#*.}
case "$motionpaper_patch" in *.*) echo "error: app bundle has an invalid three-part version" >&2; exit 1 ;; esac
for motionpaper_component in "$motionpaper_major" "$motionpaper_minor" "$motionpaper_patch"; do
    case "$motionpaper_component" in ''|*[!0-9]*) echo "error: app bundle has an invalid three-part version" >&2; exit 1 ;; esac
    [ "$motionpaper_component" = 0 ] || case "$motionpaper_component" in 0*) echo "error: app bundle has a leading-zero version component" >&2; exit 1 ;; esac
done

motionpaper_dist="$motionpaper_root/dist"
if [ "$motionpaper_channel" = stable ]; then
    motionpaper_dmg="$motionpaper_dist/Motionpaper-v$motionpaper_version.dmg"
else
    motionpaper_short_commit=$(printf '%s' "$motionpaper_commit" | cut -c 1-12)
    motionpaper_dmg="$motionpaper_dist/Motionpaper-$motionpaper_short_commit.dmg"
fi
mkdir -p "$motionpaper_dist"
motionpaper_stage=$(mktemp -d "$motionpaper_dist/.motionpaper-dmg.XXXXXX")
trap 'rm -rf "$motionpaper_stage"' EXIT HUP INT TERM

ditto "$motionpaper_app" "$motionpaper_stage/Motionpaper.app"
ln -s /Applications "$motionpaper_stage/Applications"
hdiutil create -quiet -volname Motionpaper -srcfolder "$motionpaper_stage" -ov -format UDZO "$motionpaper_dmg"
hdiutil verify -quiet "$motionpaper_dmg"
printf '%s\n' "$motionpaper_dmg"

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

motionpaper_short_commit=$(printf '%s' "$motionpaper_commit" | cut -c 1-12)
motionpaper_dist="$motionpaper_root/dist"
motionpaper_dmg="$motionpaper_dist/Motionpaper-$motionpaper_short_commit.dmg"
mkdir -p "$motionpaper_dist"
motionpaper_stage=$(mktemp -d "$motionpaper_dist/.motionpaper-dmg.XXXXXX")
trap 'rm -rf "$motionpaper_stage"' EXIT HUP INT TERM

ditto "$motionpaper_app" "$motionpaper_stage/Motionpaper.app"
ln -s /Applications "$motionpaper_stage/Applications"
hdiutil create -quiet -volname Motionpaper -srcfolder "$motionpaper_stage" -ov -format UDZO "$motionpaper_dmg"
hdiutil verify -quiet "$motionpaper_dmg"
printf '%s\n' "$motionpaper_dmg"

#!/bin/sh
set -eu

wavepaper_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$wavepaper_root"

wavepaper_app=${1:-dist/Wavepaper.app}
case "$wavepaper_app" in /*) ;; *) wavepaper_app="$wavepaper_root/$wavepaper_app" ;; esac
[ -d "$wavepaper_app" ] || { echo "error: app bundle not found: $wavepaper_app" >&2; exit 1; }

wavepaper_commit=$(/usr/libexec/PlistBuddy -c 'Print :WavepaperCommit' "$wavepaper_app/Contents/Info.plist")
case "$wavepaper_commit" in *[!0-9a-f]*|'') echo "error: app bundle has an invalid WavepaperCommit" >&2; exit 1 ;; esac
[ "${#wavepaper_commit}" -eq 40 ] || { echo "error: app bundle has an invalid WavepaperCommit" >&2; exit 1; }

wavepaper_short_commit=$(printf '%s' "$wavepaper_commit" | cut -c 1-12)
wavepaper_dist="$wavepaper_root/dist"
wavepaper_dmg="$wavepaper_dist/Wavepaper-$wavepaper_short_commit.dmg"
mkdir -p "$wavepaper_dist"
wavepaper_stage=$(mktemp -d "$wavepaper_dist/.wavepaper-dmg.XXXXXX")
trap 'rm -rf "$wavepaper_stage"' EXIT HUP INT TERM

ditto "$wavepaper_app" "$wavepaper_stage/Wavepaper.app"
ln -s /Applications "$wavepaper_stage/Applications"
hdiutil create -quiet -volname Wavepaper -srcfolder "$wavepaper_stage" -ov -format UDZO "$wavepaper_dmg"
hdiutil verify -quiet "$wavepaper_dmg"
printf '%s\n' "$wavepaper_dmg"

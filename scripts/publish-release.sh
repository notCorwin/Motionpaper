#!/usr/bin/env bash
set -euo pipefail

repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
commit=${RELEASE_COMMIT:?RELEASE_COMMIT is required}
channel=${MOTIONPAPER_RELEASE_CHANNEL:-autobuild}
version=${MOTIONPAPER_VERSION:?MOTIONPAPER_VERSION is required}
: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: RELEASE_COMMIT must be a lowercase full git commit hash" >&2
    exit 1
fi
if [[ ! $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "error: GITHUB_REPOSITORY must be in owner/repository form" >&2
    exit 1
fi
if [[ $channel != stable && $channel != autobuild ]]; then
    echo "error: MOTIONPAPER_RELEASE_CHANNEL must be stable or autobuild" >&2
    exit 1
fi
if [[ ! $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: MOTIONPAPER_VERSION must be three non-leading-zero numeric components" >&2
    exit 1
fi

short_commit=${commit:0:12}
if [[ $channel == stable ]]; then
    tag="v$version"
    dmg_name="Motionpaper-$version-$short_commit.dmg"
else
    tag="Autobuild-$commit"
    dmg_name="Motionpaper-$short_commit.dmg"
fi
dmg_path="dist/$dmg_name"
download_url="https://github.com/$repository/releases/download/$tag/$dmg_name"
[[ -s $dmg_path ]] || { echo "error: release DMG not found: $dmg_path" >&2; exit 1; }

default_branch=${DEFAULT_BRANCH:-}
if [[ $channel == autobuild && -z $default_branch ]]; then
    echo "error: DEFAULT_BRANCH is required for Autobuild releases" >&2
    exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

branch_path=''
if [[ $channel == autobuild ]]; then
    branch_path=$(jq -rn --arg branch "$default_branch" '$branch | @uri')
fi

default_branch_head() {
    gh api "repos/$repository/branches/$branch_path" --jq '.commit.sha'
}

is_current_default_head() {
    [[ $(default_branch_head) == "$commit" ]]
}

current_latest_tag() {
    gh api "repos/$repository/releases/latest" --jq '.tag_name'
}

highest_stable_release() {
    python3 - "$1" <<'PY'
import json
import re
import sys

releases = json.load(open(sys.argv[1], encoding="utf-8"))
pattern = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
matches = []
for release in releases:
    if release.get("draft") is not False or release.get("prerelease") is True or not release.get("published_at"):
        continue
    match = pattern.fullmatch(release.get("tag_name", ""))
    if match:
        version = tuple(int(component) for component in match.groups())
        matches.append((version, int(release["id"]), release["tag_name"]))
if matches:
    _, release_id, tag = max(matches)
    print(f"{release_id}\t{tag}")
PY
}

latest_published_autobuild() {
    python3 - "$1" <<'PY'
import json
import re
import sys

releases = json.load(open(sys.argv[1], encoding="utf-8"))
pattern = re.compile(r"^Autobuild-([0-9a-f]{40})$")
matches = []
for release in releases:
    tag = release.get("tag_name", "")
    if release.get("draft") is not False or release.get("prerelease") is True or not release.get("published_at") or not pattern.fullmatch(tag):
        continue
    matches.append((release["published_at"], int(release["id"]), tag))
if matches:
    _, release_id, tag = max(matches)
    print(f"{release_id}\t{tag}")
PY
}

version_at_least() {
    python3 - "$1" "$2" <<'PY'
import sys

requested = tuple(int(part) for part in sys.argv[1].split("."))
existing = tuple(int(part) for part in sys.argv[2].split("."))
raise SystemExit(0 if requested >= existing else 1)
PY
}

fetch_releases() {
    gh api --paginate "repos/$repository/releases?per_page=100" | jq -s 'add // []' >"$1"
}

reconcile_latest_stable() {
    local releases_file=$1 stable_row stable_id stable_tag attempt verified_file verified_row
    for attempt in 1 2 3; do
        stable_row=$(highest_stable_release "$releases_file")
        [[ -n $stable_row ]] || return 0
        IFS=$'\t' read -r stable_id stable_tag <<<"$stable_row"
        if [[ $(current_latest_tag) != "$stable_tag" ]]; then
            gh api --method PATCH "repos/$repository/releases/$stable_id" -f make_latest=true >"$work_dir/latest-release.json"
        fi
        verified_file="$work_dir/latest-stable-verified-$attempt.json"
        fetch_releases "$verified_file"
        verified_row=$(highest_stable_release "$verified_file")
        if [[ $verified_row == "$stable_row" && $(current_latest_tag) == "$stable_tag" ]]; then
            return 0
        fi
        releases_file=$verified_file
    done
    echo "error: latest stable release kept changing during reconciliation" >&2
    return 1
}

is_current_latest_autobuild() {
    local releases_file="$work_dir/current-releases.json" latest_row latest_tag
    fetch_releases "$releases_file"
    latest_row=$(latest_published_autobuild "$releases_file")
    [[ -n $latest_row ]] || return 1
    IFS=$'\t' read -r _ latest_tag <<<"$latest_row"
    [[ $latest_tag == "$tag" ]]
}

resolve_tag_commit() {
    local requested_tag=$1
    local ref_file="$work_dir/tag-ref.json"
    local object_type object_sha depth
    if ! gh api "repos/$repository/git/ref/tags/$requested_tag" >"$ref_file" 2>/dev/null; then
        return 1
    fi
    object_type=$(jq -r '.object.type // empty' "$ref_file")
    object_sha=$(jq -r '.object.sha // empty' "$ref_file")
    for ((depth = 0; depth < 10; depth++)); do
        case "$object_type" in
            commit)
                [[ $object_sha =~ ^[0-9a-f]{40}$ ]] || return 1
                printf '%s\n' "$object_sha"
                return 0
                ;;
            tag)
                [[ $object_sha =~ ^[0-9a-f]{40}$ ]] || return 1
                gh api "repos/$repository/git/tags/$object_sha" >"$work_dir/tag-object.json" || return 1
                object_type=$(jq -r '.object.type // empty' "$work_dir/tag-object.json")
                object_sha=$(jq -r '.object.sha // empty' "$work_dir/tag-object.json")
                ;;
            *) return 1 ;;
        esac
    done
    return 1
}

assert_tag_target() {
    local requested_tag=$1 expected_commit=$2 resolved_commit
    resolved_commit=$(resolve_tag_commit "$requested_tag") || {
        echo "error: release tag $requested_tag does not resolve to a commit" >&2
        return 1
    }
    [[ $resolved_commit == "$expected_commit" ]] || {
        echo "error: release tag $requested_tag resolves to $resolved_commit instead of $expected_commit" >&2
        return 1
    }
}

validate_release_identity() {
    local json_file=$1 expected_tag=$2 expected_commit=$3 actual_tag actual_target
    actual_tag=$(jq -r '.tag_name // empty' "$json_file")
    actual_target=$(jq -r '.target_commitish // empty' "$json_file")
    [[ $actual_tag == "$expected_tag" && $actual_target =~ ^[0-9a-f]{40}$ && $actual_target == "$expected_commit" ]] || {
        echo "error: release $expected_tag must name the expected tag and full commit target" >&2
        return 1
    }
}

asset_count() {
    local json_file=$1 asset_name=$2
    jq --arg name "$asset_name" '[.assets[]? | select(.name == $name)] | length' "$json_file"
}

asset_metadata() {
    local json_file=$1 asset_name=$2 field=$3
    jq --arg name "$asset_name" -r --arg field "$field" \
        '[.assets[]? | select(.name == $name)][0][$field] // empty' "$json_file"
}

file_size() {
    wc -c <"$1" | tr -d '[:space:]'
}

file_sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

validate_legacy_manifest() {
    local manifest_path=$1
    jq -e \
        --arg repository "$repository" \
        'type == "object" and
         (keys | sort) == ["commit", "downloadURL", "publishedAt", "sha256", "size"] and
         (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
         (.publishedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
         (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
         (.size | type == "number" and . > 0 and floor == .) and
         (.commit as $commit | .downloadURL == ("https://github.com/" + $repository + "/releases/download/Autobuild-" + $commit + "/Motionpaper-" + ($commit[0:12]) + ".dmg"))' \
        "$manifest_path" >/dev/null || {
        echo "error: update.json does not satisfy the legacy updater contract" >&2
        return 1
    }
}

asset_download_url() {
    local expected_tag=$1 asset_name=$2
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repository" "$expected_tag" "$asset_name"
}

validate_asset_metadata() {
    local json_file=$1 asset_name=$2 expected_url=$3 count state size digest browser_url
    count=$(asset_count "$json_file" "$asset_name")
    [[ $count == 1 ]] || { echo "error: release must contain exactly one $asset_name asset" >&2; return 1; }
    state=$(asset_metadata "$json_file" "$asset_name" state)
    size=$(asset_metadata "$json_file" "$asset_name" size)
    digest=$(asset_metadata "$json_file" "$asset_name" digest)
    browser_url=$(asset_metadata "$json_file" "$asset_name" browser_download_url)
    [[ $state == uploaded ]] || { echo "error: release asset $asset_name is not uploaded" >&2; return 1; }
    [[ $size =~ ^[1-9][0-9]*$ ]] || { echo "error: release asset $asset_name has an invalid size" >&2; return 1; }
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: release asset $asset_name has an invalid SHA-256" >&2; return 1; }
    # GitHub uses an untagged temporary URL while a release is a draft.
    # The published validation below requires the final, tag-bound URL.
    if [[ $(jq -r '.draft' "$json_file") != true ]]; then
        [[ $browser_url == "$expected_url" ]] || { echo "error: release asset $asset_name has an invalid browser_download_url" >&2; return 1; }
    fi
}

validate_update_manifest() {
    local manifest_path=$1 expected_commit=$2 expected_url=$3 dmg_size=$4 dmg_digest=$5
    validate_legacy_manifest "$manifest_path" || return
    jq -e \
        --arg commit "$expected_commit" \
        --arg url "$expected_url" \
        --arg sha256 "${dmg_digest#sha256:}" \
        --argjson size "$dmg_size" \
        'type == "object" and
         .commit == $commit and
         .downloadURL == $url and
         .sha256 == $sha256 and
         .size == $size and
         (.size | type == "number" and . > 0 and floor == .)' \
        "$manifest_path" >/dev/null || {
        echo "error: update.json does not satisfy the legacy updater contract" >&2
        return 1
    }
}

validate_uploaded_assets() {
    local json_file=$1 expected_tag=$2 expected_commit=$3 expected_channel=$4
    local expected_dmg_name=$5 expected_url=$6 expected_dmg_path=$7 update_path=${8:-}
    local update_count uploaded_size uploaded_digest local_size local_digest dmg_size dmg_digest

    validate_release_identity "$json_file" "$expected_tag" "$expected_commit" || return
    update_count=$(asset_count "$json_file" update.json)
    validate_asset_metadata "$json_file" "$expected_dmg_name" "$(asset_download_url "$expected_tag" "$expected_dmg_name")" || return
    if [[ $expected_channel == autobuild ]]; then
        [[ $update_count == 1 && -n $update_path && -s $update_path ]] || {
            echo "error: Autobuild release must contain exactly one update.json asset" >&2
            return 1
        }
    elif [[ -n $update_path ]]; then
        [[ $update_count == 1 && -s $update_path ]] || {
            echo "error: stable release compatibility update.json is missing" >&2
            return 1
        }
    else
        [[ $update_count == 0 ]] || { echo "error: stable release has an unverified update.json asset" >&2; return 1; }
    fi

    uploaded_size=$(asset_metadata "$json_file" "$expected_dmg_name" size)
    uploaded_digest=$(asset_metadata "$json_file" "$expected_dmg_name" digest)
    local_size=$(file_size "$expected_dmg_path")
    local_digest=$(file_sha256 "$expected_dmg_path")
    dmg_size=$local_size
    dmg_digest=$local_digest
    [[ $uploaded_size == "$local_size" && $uploaded_digest == "sha256:$local_digest" ]] || {
        echo "error: uploaded DMG size or SHA-256 does not match the package" >&2
        return 1
    }

    if [[ $expected_channel == autobuild || -n $update_path ]]; then
        uploaded_size=$(asset_metadata "$json_file" update.json size)
        uploaded_digest=$(asset_metadata "$json_file" update.json digest)
        local_size=$(file_size "$update_path")
        local_digest=$(file_sha256 "$update_path")
        [[ $uploaded_size == "$local_size" && $uploaded_digest == "sha256:$local_digest" ]] || {
            echo "error: uploaded update.json size or SHA-256 does not match the manifest" >&2
            return 1
        }
        validate_asset_metadata "$json_file" update.json "$(asset_download_url "$expected_tag" update.json)" || return
        if [[ $expected_channel == stable ]]; then
            validate_legacy_manifest "$update_path"
            return
        fi
        validate_update_manifest "$update_path" "$expected_commit" "$expected_url" "$dmg_size" "sha256:$dmg_digest"
    fi
}

validate_published_release() {
    local json_file=$1 expected_tag=$2 expected_commit=$3 expected_channel=$4
    local expected_dmg_name=$5 expected_url=$6 validation_dir=$7
    local published is_draft update_count dmg_size dmg_digest update_size update_digest downloaded_size downloaded_digest
    local manifest="$validation_dir/update.json"

    validate_release_identity "$json_file" "$expected_tag" "$expected_commit" || return
    is_draft=$(jq -r '.draft' "$json_file")
    published=$(jq -r '.published_at // empty' "$json_file")
    [[ $is_draft == false && -n $published ]] || {
        echo "error: release $expected_tag is not a complete published release" >&2
        return 1
    }
    assert_tag_target "$expected_tag" "$expected_commit" || return

    validate_asset_metadata "$json_file" "$expected_dmg_name" "$(asset_download_url "$expected_tag" "$expected_dmg_name")" || return
    dmg_size=$(asset_metadata "$json_file" "$expected_dmg_name" size)
    dmg_digest=$(asset_metadata "$json_file" "$expected_dmg_name" digest)
    update_count=$(asset_count "$json_file" update.json)
    if [[ $expected_channel == autobuild ]]; then
        [[ $update_count == 1 ]] || { echo "error: Autobuild release $expected_tag is missing update.json" >&2; return 1; }
        validate_asset_metadata "$json_file" update.json "$(asset_download_url "$expected_tag" update.json)" || return
    else
        [[ $update_count -le 1 ]] || { echo "error: stable release $expected_tag has duplicate update.json assets" >&2; return 1; }
        if [[ $update_count == 1 ]]; then
            validate_asset_metadata "$json_file" update.json "$(asset_download_url "$expected_tag" update.json)" || return
        fi
    fi

    if [[ $expected_channel == autobuild || $update_count == 1 ]]; then
        mkdir -p "$validation_dir"
        gh release download "$expected_tag" --repo "$repository" --pattern update.json --dir "$validation_dir" --clobber || return
        update_size=$(asset_metadata "$json_file" update.json size)
        update_digest=$(asset_metadata "$json_file" update.json digest)
        downloaded_size=$(file_size "$manifest")
        downloaded_digest=$(file_sha256 "$manifest")
        [[ $downloaded_size == "$update_size" && "sha256:$downloaded_digest" == "$update_digest" ]] || {
            echo "error: published update.json asset size or SHA-256 is invalid for $expected_tag" >&2
            return 1
        }
        if [[ $expected_channel == autobuild ]]; then
            validate_update_manifest "$manifest" "$expected_commit" "$expected_url" "$dmg_size" "$dmg_digest"
        else
            validate_legacy_manifest "$manifest"
        fi
    fi
}

download_autobuild_manifest() {
    local release_id=$1 autobuild_tag=$2 destination=$3 autobuild_commit autobuild_dmg autobuild_url
    [[ $autobuild_tag =~ ^Autobuild-([0-9a-f]{40})$ ]] || {
        echo "error: invalid Autobuild release tag $autobuild_tag" >&2
        return 1
    }
    autobuild_commit=${BASH_REMATCH[1]}
    autobuild_dmg="Motionpaper-${autobuild_commit:0:12}.dmg"
    autobuild_url=$(asset_download_url "$autobuild_tag" "$autobuild_dmg")
    gh api "repos/$repository/releases/$release_id" >"$work_dir/source-autobuild.json"
    validate_published_release \
        "$work_dir/source-autobuild.json" "$autobuild_tag" "$autobuild_commit" autobuild \
        "$autobuild_dmg" "$autobuild_url" "$work_dir/source-autobuild-assets"
    cp "$work_dir/source-autobuild-assets/update.json" "$destination"
}

validate_stable_release_for_sync() {
    local json_file=$1 stable_tag=$2 stable_commit stable_version stable_dmg published is_draft
    [[ $stable_tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
    stable_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    stable_commit=$(jq -r '.target_commitish // empty' "$json_file")
    [[ $stable_commit =~ ^[0-9a-f]{40}$ ]] || {
        echo "error: stable release $stable_tag has an invalid commit target" >&2
        return 1
    }
    validate_release_identity "$json_file" "$stable_tag" "$stable_commit" || return
    is_draft=$(jq -r '.draft' "$json_file")
    published=$(jq -r '.published_at // empty' "$json_file")
    [[ $is_draft == false && -n $published ]] || {
        echo "error: cannot sync compatibility metadata to incomplete stable release $stable_tag" >&2
        return 1
    }
    assert_tag_target "$stable_tag" "$stable_commit" || return
    stable_dmg="Motionpaper-$stable_version-${stable_commit:0:12}.dmg"
    validate_asset_metadata "$json_file" "$stable_dmg" "$(asset_download_url "$stable_tag" "$stable_dmg")"
}

sync_manifest_to_latest_stable() {
    local manifest_path=$1 attempt releases_file stable_row stable_id stable_tag
    local stable_file stable_commit stable_version stable_dmg stable_dmg_id stable_dmg_size stable_dmg_digest stable_dmg_url
    local asset_id updated_releases updated_row updated_tag manifest_size manifest_digest compat_count compat_size compat_digest compat_matches

    for attempt in 1 2; do
        releases_file="$work_dir/sync-releases-$attempt.json"
        fetch_releases "$releases_file"
        stable_row=$(highest_stable_release "$releases_file")
        [[ -n $stable_row ]] || {
            echo "No published stable release exists for Autobuild compatibility sync."
            return 0
        }
        IFS=$'\t' read -r stable_id stable_tag <<<"$stable_row"
        stable_file="$work_dir/sync-stable-$attempt.json"
        gh api "repos/$repository/releases/$stable_id" >"$stable_file"
        validate_stable_release_for_sync "$stable_file" "$stable_tag"

        stable_commit=$(jq -r '.target_commitish' "$stable_file")
        stable_version=${stable_tag#v}
        stable_dmg="Motionpaper-$stable_version-${stable_commit:0:12}.dmg"
        stable_dmg_id=$(asset_metadata "$stable_file" "$stable_dmg" id)
        stable_dmg_size=$(asset_metadata "$stable_file" "$stable_dmg" size)
        stable_dmg_digest=$(asset_metadata "$stable_file" "$stable_dmg" digest)
        stable_dmg_url=$(asset_metadata "$stable_file" "$stable_dmg" browser_download_url)
        [[ -n $stable_dmg_id ]] || {
            echo "error: stable release $stable_tag has no DMG asset to preserve" >&2
            return 1
        }

        manifest_size=$(file_size "$manifest_path")
        manifest_digest="sha256:$(file_sha256 "$manifest_path")"
        compat_count=$(asset_count "$stable_file" update.json)
        compat_size=$(asset_metadata "$stable_file" update.json size)
        compat_digest=$(asset_metadata "$stable_file" update.json digest)
        compat_matches=false
        if [[ $compat_count == 1 && $compat_size == "$manifest_size" && $compat_digest == "$manifest_digest" ]] &&
            validate_asset_metadata "$stable_file" update.json "$(asset_download_url "$stable_tag" update.json)" >/dev/null 2>&1; then
            compat_matches=true
        fi
        if [[ $compat_matches != true ]]; then
            while IFS= read -r asset_id; do
                [[ -n $asset_id ]] && gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
            done < <(jq -r '.assets[]? | select(.name == "update.json") | .id' "$stable_file")
            gh release upload "$stable_tag" "$manifest_path" --repo "$repository"
        fi

        gh api "repos/$repository/releases/$stable_id" >"$work_dir/synced-stable.json"
        validate_published_release \
            "$work_dir/synced-stable.json" "$stable_tag" "$(jq -r '.target_commitish' "$stable_file")" stable \
            "$stable_dmg" "$(asset_download_url "$stable_tag" "$stable_dmg")" "$work_dir/synced-stable-validation"
        [[ $(asset_metadata "$work_dir/synced-stable.json" "$stable_dmg" id) == "$stable_dmg_id" &&
           $(asset_metadata "$work_dir/synced-stable.json" "$stable_dmg" size) == "$stable_dmg_size" &&
           $(asset_metadata "$work_dir/synced-stable.json" "$stable_dmg" digest) == "$stable_dmg_digest" &&
           $(asset_metadata "$work_dir/synced-stable.json" "$stable_dmg" browser_download_url) == "$stable_dmg_url" ]] || {
            echo "error: stable release DMG changed during compatibility sync" >&2
            return 1
        }
        cmp -s "$manifest_path" "$work_dir/synced-stable-validation/update.json" || {
            echo "error: stable compatibility update.json does not match the validated Autobuild manifest" >&2
            return 1
        }

        updated_releases="$work_dir/post-sync-releases-$attempt.json"
        fetch_releases "$updated_releases"
        updated_row=$(highest_stable_release "$updated_releases")
        [[ -n $updated_row ]] || return 0
        IFS=$'\t' read -r _ updated_tag <<<"$updated_row"
        if [[ $updated_tag == "$stable_tag" ]]; then
            return 0
        fi
    done
    echo "error: highest stable release kept changing during Autobuild compatibility sync" >&2
    return 1
}

sync_latest_autobuild_to_latest_stable() {
    local preferred_id=${1:-} preferred_tag=${2:-} preferred_manifest=${3:-}
    local attempt releases_file autobuild_row autobuild_id autobuild_tag manifest_dir manifest_path
    local after_sync_file after_sync_row
    for attempt in 1 2; do
        releases_file="$work_dir/latest-autobuild-$attempt.json"
        fetch_releases "$releases_file"
        autobuild_row=$(latest_published_autobuild "$releases_file")
        [[ -n $autobuild_row ]] || return 0
        IFS=$'\t' read -r autobuild_id autobuild_tag <<<"$autobuild_row"
        if [[ $autobuild_id == "$preferred_id" && $autobuild_tag == "$preferred_tag" && -s "$preferred_manifest" ]]; then
            manifest_path=$preferred_manifest
        else
            manifest_dir="$work_dir/latest-autobuild-$attempt"
            mkdir -p "$manifest_dir"
            manifest_path="$manifest_dir/update.json"
            download_autobuild_manifest "$autobuild_id" "$autobuild_tag" "$manifest_path"
        fi
        sync_manifest_to_latest_stable "$manifest_path"

        after_sync_file="$work_dir/latest-autobuild-after-sync-$attempt.json"
        fetch_releases "$after_sync_file"
        after_sync_row=$(latest_published_autobuild "$after_sync_file")
        [[ $after_sync_row == "$autobuild_row" ]] && return 0
    done
    echo "error: latest Autobuild kept changing during stable compatibility sync" >&2
    return 1
}

if [[ $channel == stable ]]; then
    assert_tag_target "$tag" "$commit"
elif is_current_default_head; then
    :
else
    echo "Skipping release for $commit: $default_branch has advanced."
    exit 0
fi

if [[ $channel == autobuild ]]; then
    if ! gh api "repos/$repository/git/ref/tags/$tag" >"$work_dir/tag-ref.json" 2>/dev/null; then
        gh api --method POST "repos/$repository/git/refs" \
            -f "ref=refs/tags/$tag" -f "sha=$commit" >"$work_dir/created-tag.json"
    fi
    assert_tag_target "$tag" "$commit"
fi

release_file="$work_dir/release.json"
gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$tag\")" >"$work_dir/matching-releases.json"
release_exists=false
if [[ -s $work_dir/matching-releases.json ]]; then
    jq -s 'sort_by(.draft, .id) | first' "$work_dir/matching-releases.json" >"$release_file"
    release_exists=true
    validate_release_identity "$release_file" "$tag" "$commit"
fi

release_is_draft=false
if [[ $release_exists == true ]]; then
    release_is_draft=$(jq -r '.draft' "$release_file")
fi

legacy_manifest_path=''
if [[ $release_exists == true && $release_is_draft == false ]]; then
    validation_dir="$work_dir/reuse-assets"
    validate_published_release \
        "$release_file" "$tag" "$commit" "$channel" "$dmg_name" "$download_url" \
        "$validation_dir"
    release_id=$(jq -r '.id' "$release_file")
    if [[ $channel == autobuild ]]; then
        legacy_manifest_path="$validation_dir/update.json"
    fi
    echo "Reusing complete published $channel release $tag."
else
    # A draft can be resumed; a published release above is validation-only and is never overwritten.
    if [[ $release_exists == false ]]; then
        release_name=Autobuild
        if [[ $channel == stable ]]; then
            release_name="Motionpaper $version"
            release_notes="Support/ReleaseNotes/$version.md"
            if [[ -f $release_notes ]]; then
                cp "$release_notes" "$work_dir/release-body.md"
            else
                printf 'Motionpaper stable release %s.\n' "$version" >"$work_dir/release-body.md"
            fi
        else
            printf 'Automated release for %s commit %s.\n' "$default_branch" "$commit" >"$work_dir/release-body.md"
        fi
        jq -n \
            --arg tag_name "$tag" \
            --arg target_commitish "$commit" \
            --arg name "$release_name" \
            --rawfile body "$work_dir/release-body.md" \
            --argjson draft true \
            --arg make_latest false \
            '{tag_name: $tag_name, target_commitish: $target_commitish, name: $name, body: $body, draft: $draft, make_latest: $make_latest}' \
            >"$work_dir/release-request.json"
        if ! gh api --method POST "repos/$repository/releases" \
            --input "$work_dir/release-request.json" >"$release_file"; then
            cat "$release_file" >&2
            exit 1
        fi
    fi

    validate_release_identity "$release_file" "$tag" "$commit"
    release_id=$(jq -r '.id' "$release_file")
    release_is_draft=$(jq -r '.draft' "$release_file")
    [[ $release_is_draft == true ]] || {
        echo "error: refusing to replace assets in a published release" >&2
        exit 1
    }
    assert_tag_target "$tag" "$commit"
    update_path=''
    if [[ $channel == autobuild ]]; then
        while IFS= read -r asset_id; do
            [[ -n $asset_id ]] && gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
        done < <(jq -r '.assets[]?.id' "$release_file")

        update_path="$work_dir/update.json"
        dmg_size=$(file_size "$dmg_path")
        dmg_sha256=$(file_sha256 "$dmg_path")
        published_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        jq -n -S \
            --arg commit "$commit" \
            --arg publishedAt "$published_at" \
            --arg downloadURL "$download_url" \
            --arg sha256 "$dmg_sha256" \
            --argjson size "$dmg_size" \
            '{commit: $commit, publishedAt: $publishedAt, downloadURL: $downloadURL, sha256: $sha256, size: $size}' \
            >"$update_path"
        gh release upload "$tag" "$dmg_path" "$update_path" --repo "$repository"
    else
        mkdir -p "$work_dir/stable-compat"
        update_path="$work_dir/stable-compat/update.json"
        fetch_releases "$work_dir/stable-source-releases.json"
        source_autobuild_row=$(latest_published_autobuild "$work_dir/stable-source-releases.json")
        if [[ -n $source_autobuild_row ]]; then
            IFS=$'\t' read -r source_autobuild_id source_autobuild_tag <<<"$source_autobuild_row"
            download_autobuild_manifest "$source_autobuild_id" "$source_autobuild_tag" "$update_path"
        else
            update_path=''
        fi

        dmg_count=$(asset_count "$release_file" "$dmg_name")
        if [[ $dmg_count == 0 ]]; then
            gh release upload "$tag" "$dmg_path" --repo "$repository"
        elif [[ $dmg_count == 1 ]]; then
            validate_asset_metadata "$release_file" "$dmg_name" "$(asset_download_url "$tag" "$dmg_name")"
            existing_dmg_size=$(asset_metadata "$release_file" "$dmg_name" size)
            existing_dmg_digest=$(asset_metadata "$release_file" "$dmg_name" digest)
            [[ $existing_dmg_size == "$(file_size "$dmg_path")" &&
               $existing_dmg_digest == "sha256:$(file_sha256 "$dmg_path")" ]] || {
                echo "error: refusing to replace the existing stable DMG asset" >&2
                exit 1
            }
        else
            echo "error: stable draft $tag contains duplicate DMG assets" >&2
            exit 1
        fi

        while IFS= read -r asset_id; do
            [[ -n $asset_id ]] && gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
        done < <(jq -r '.assets[]? | select(.name == "update.json") | .id' "$release_file")
        if [[ -n $update_path ]]; then
            gh release upload "$tag" "$update_path" --repo "$repository"
        fi
    fi

    gh api "repos/$repository/releases/$release_id" >"$work_dir/uploaded.json"
    validate_uploaded_assets \
        "$work_dir/uploaded.json" "$tag" "$commit" "$channel" "$dmg_name" "$download_url" "$dmg_path" "$update_path"
    assert_tag_target "$tag" "$commit"

    if [[ $channel == autobuild ]] && ! is_current_default_head; then
        echo "Leaving draft $commit unpublished: $default_branch advanced during packaging."
        exit 0
    fi

    make_latest=false
    if [[ $channel == stable ]]; then
        fetch_releases "$work_dir/pre-publish-releases.json"
        previous_stable_row=$(highest_stable_release "$work_dir/pre-publish-releases.json")
        if [[ -z $previous_stable_row ]]; then
            make_latest=true
        else
            IFS=$'\t' read -r _ previous_stable_tag <<<"$previous_stable_row"
            previous_stable_version=${previous_stable_tag#v}
            if version_at_least "$version" "$previous_stable_version"; then
                make_latest=true
            fi
        fi
    fi
    if ! gh api --method PATCH "repos/$repository/releases/$release_id" \
        -F draft=false -f "make_latest=$make_latest" >"$work_dir/published.json"; then
        cat "$work_dir/published.json" >&2
        exit 1
    fi
    [[ $(jq -r '.draft' "$work_dir/published.json") == false ]] || {
        echo "error: GitHub did not publish release $tag" >&2
        exit 1
    }
    validate_release_identity "$work_dir/published.json" "$tag" "$commit"
    assert_tag_target "$tag" "$commit"
    gh api "repos/$repository/releases/$release_id" >"$release_file"
    validate_published_release \
        "$release_file" "$tag" "$commit" "$channel" "$dmg_name" "$download_url" \
        "$work_dir/published-assets"
    if [[ $channel == autobuild ]]; then
        legacy_manifest_path="$work_dir/published-assets/update.json"
    fi
    echo "Published $channel release $tag for $commit."
fi

if [[ $channel == stable ]]; then
    sync_latest_autobuild_to_latest_stable
    fetch_releases "$work_dir/stable-releases-final.json"
    reconcile_latest_stable "$work_dir/stable-releases-final.json"
    exit 0
fi

# Each successful release reconciles the latest published Autobuild on the highest stable release.
sync_latest_autobuild_to_latest_stable "$release_id" "$tag" "$legacy_manifest_path"
fetch_releases "$work_dir/auto-releases-final.json"
reconcile_latest_stable "$work_dir/auto-releases-final.json"

# Cleanup runs only for the published current default-branch Autobuild when it is still the newest Autobuild.
if ! is_current_default_head || ! is_current_latest_autobuild; then
    echo "Skipping old release cleanup: current branch head or latest Autobuild changed."
    exit 0
fi
if [[ $repository != "notCorwin/Motionpaper" ]]; then
    echo "Skipping obsolete release cleanup outside notCorwin/Motionpaper."
    exit 0
fi

gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq '.[] | [.id, .tag_name, .target_commitish, (.draft | tostring)] | @tsv' \
    >"$work_dir/release-rows.tsv"
while IFS=$'\t' read -r old_release_id old_tag old_target old_draft; do
    [[ -n $old_release_id ]] || continue
    [[ $old_release_id != "$release_id" && $old_tag != "$tag" ]] || continue
    [[ $old_tag =~ ^Autobuild-([0-9a-f]{40})$ ]] || continue
    old_commit=${BASH_REMATCH[1]}
    [[ $old_target == "$old_commit" ]] || continue
    if ! resolved_old_commit=$(resolve_tag_commit "$old_tag") || [[ $resolved_old_commit != "$old_commit" ]]; then
        continue
    fi

    if ! is_current_default_head || ! is_current_latest_autobuild; then
        echo "Stopping old release cleanup: current branch head or latest Autobuild changed."
        exit 0
    fi
    fetch_releases "$work_dir/pre-delete-releases.json"
    if ! jq -e --arg id "$old_release_id" --arg old_tag "$old_tag" --arg old_target "$old_target" \
        'any(.[]; ((.id | tostring) == $id) and .tag_name == $old_tag and .target_commitish == $old_target)' \
        "$work_dir/pre-delete-releases.json" >/dev/null; then
        continue
    fi
    # Remove only old Autobuild releases whose tag and target both identify the same commit.
    gh api --method DELETE "repos/$repository/releases/$old_release_id"
    if resolved_old_commit=$(resolve_tag_commit "$old_tag") && [[ $resolved_old_commit == "$old_commit" ]]; then
        gh api --method DELETE "repos/$repository/git/refs/tags/$old_tag"
    fi
done <"$work_dir/release-rows.tsv"

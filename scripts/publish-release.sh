#!/usr/bin/env bash
set -euo pipefail

repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
commit=${RELEASE_COMMIT:?RELEASE_COMMIT is required}
channel=${MOTIONPAPER_RELEASE_CHANNEL:-autobuild}
version=${MOTIONPAPER_VERSION:?MOTIONPAPER_VERSION is required}
: "${GH_TOKEN:?GH_TOKEN is required}"

[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "error: RELEASE_COMMIT must be a lowercase full git commit hash" >&2; exit 1; }
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${repository%%/*} != . && ${repository%%/*} != .. && ${repository#*/} != . && ${repository#*/} != .. ]] || {
    echo "error: GITHUB_REPOSITORY must be in owner/repository form" >&2; exit 1;
}
[[ $channel == stable || $channel == autobuild ]] || { echo "error: invalid release channel" >&2; exit 1; }
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo "error: MOTIONPAPER_VERSION must have three non-leading-zero numeric components" >&2; exit 1;
}

default_branch=${DEFAULT_BRANCH:-}
latest_release_url="https://github.com/$repository/releases/latest"
autobuild_body=$(printf '基于 %s 分支提交 `%s` 自动构建的版本。\n此版本可能存在 Bug，建议使用 [Latest](%s)。\n\nAutomatically built from commit `%s` on the %s branch.\nThis build may contain bugs. We recommend using [Latest](%s).\n' \
    "$default_branch" "${commit:0:7}" "$latest_release_url" "${commit:0:7}" "$default_branch" "$latest_release_url")
if [[ $channel == stable ]]; then
    tag="v$version"
    dmg_name="Motionpaper-$tag.dmg"
else
    [[ -n $default_branch ]] || { echo "error: DEFAULT_BRANCH is required for Autobuild releases" >&2; exit 1; }
    tag=Autobuild
    dmg_name="Motionpaper-${commit:0:12}.dmg"
fi
dmg_path="dist/$dmg_name"
download_url="https://github.com/$repository/releases/download/$tag/$dmg_name"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ $channel == autobuild ]]; then
    branch_path=$(jq -rn --arg branch "$default_branch" '$branch | @uri')
fi

# Return 1 for an advanced branch and 2 for an API/validation failure.
is_current_default_head() {
    local head
    head=$(gh api "repos/$repository/branches/$branch_path" --jq '.commit.sha') || return 2
    if [[ ! $head =~ ^[0-9a-f]{40}$ ]]; then
        echo "error: default branch has an invalid commit" >&2
        return 2
    fi
    [[ $head == "$commit" ]]
}

skip_if_branch_advanced() {
    local status
    if is_current_default_head; then
        return 0
    else
        status=$?
    fi
    if [[ $status == 1 ]]; then
        echo "Skipping Autobuild for $commit: $default_branch has advanced."
        exit 0
    fi
    exit 1
}

fetch_releases() {
    gh api --paginate "repos/$repository/releases?per_page=100" | jq -s 'add // []' >"$1"
}

highest_stable_release() {
    python3 - "$1" <<'PY'
import json
import re
import sys

pattern = re.compile(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
matches = []
for release in json.load(open(sys.argv[1], encoding='utf-8')):
    if release.get('draft') is not False or release.get('prerelease') is not False or not release.get('published_at'):
        continue
    match = pattern.fullmatch(release.get('tag_name', ''))
    if match:
        matches.append((tuple(map(int, match.groups())), int(release['id']), release['tag_name']))
if matches:
    _, release_id, tag = max(matches)
    print(f'{release_id}\t{tag}')
PY
}

version_at_least() {
    python3 - "$1" "$2" <<'PY'
import sys
raise SystemExit(0 if tuple(map(int, sys.argv[1].split('.'))) >= tuple(map(int, sys.argv[2].split('.'))) else 1)
PY
}

current_latest_tag() {
    local result error_file="$work_dir/latest-error.txt"
    if result=$(gh api "repos/$repository/releases/latest" --jq '.tag_name' 2>"$error_file"); then
        printf '%s\n' "$result"
    elif [[ $(cat "$error_file") == *'(HTTP 404)'* ]]; then
        printf '\n'
    else
        cat "$error_file" >&2
        return 1
    fi
}

reconcile_latest_stable() {
    local releases_file=$1 stable_row stable_id stable_tag attempt verified_file verified_row latest
    for attempt in 1 2 3; do
        stable_row=$(highest_stable_release "$releases_file")
        [[ -n $stable_row ]] || return 0
        IFS=$'\t' read -r stable_id stable_tag <<<"$stable_row"
        latest=$(current_latest_tag) || return 1
        if [[ $latest != "$stable_tag" ]]; then
            gh api --method PATCH "repos/$repository/releases/$stable_id" -f make_latest=true >"$work_dir/latest-release.json"
        fi
        verified_file="$work_dir/latest-stable-verified-$attempt.json"
        fetch_releases "$verified_file"
        verified_row=$(highest_stable_release "$verified_file")
        latest=$(current_latest_tag) || return 1
        [[ $verified_row == "$stable_row" && $latest == "$stable_tag" ]] && return 0
        releases_file=$verified_file
    done
    echo "error: latest stable release kept changing during reconciliation" >&2
    return 1
}

# A missing ref is distinct from an API failure; annotated tags are peeled to commits.
resolve_tag_commit() {
    local requested_tag=$1 ref_file="$work_dir/tag-ref.json" error_file="$work_dir/tag-error.txt"
    local object_type object_sha depth
    if gh api "repos/$repository/git/ref/tags/$requested_tag" >"$ref_file" 2>"$error_file"; then
        :
    elif [[ $(cat "$error_file") == *'(HTTP 404)'* ]]; then
        return 2
    else
        cat "$error_file" >&2
        return 1
    fi
    object_type=$(jq -r '.object.type // empty' "$ref_file")
    object_sha=$(jq -r '.object.sha // empty' "$ref_file")
    for ((depth = 0; depth < 10; depth++)); do
        [[ $object_sha =~ ^[0-9a-f]{40}$ ]] || break
        case "$object_type" in
            commit) printf '%s\n' "$object_sha"; return 0 ;;
            tag)
                gh api "repos/$repository/git/tags/$object_sha" >"$work_dir/tag-object.json" || return 1
                object_type=$(jq -r '.object.type // empty' "$work_dir/tag-object.json")
                object_sha=$(jq -r '.object.sha // empty' "$work_dir/tag-object.json")
                ;;
            *) break ;;
        esac
    done
    echo "error: release tag $requested_tag does not resolve to a full commit" >&2
    return 1
}

assert_tag_target() {
    local actual
    actual=$(resolve_tag_commit "$tag") || { echo "error: could not resolve release tag $tag" >&2; return 1; }
    [[ $actual == "$commit" ]] || { echo "error: release tag $tag resolves to $actual instead of $commit" >&2; return 1; }
}

validate_release_identity() {
    local json_file=$1 actual_tag prerelease
    actual_tag=$(jq -r '.tag_name // empty' "$json_file")
    prerelease=$(jq -r '.prerelease' "$json_file")
    [[ $actual_tag == "$tag" && $prerelease == false ]] || {
        echo "error: release $tag must have the expected tag and not be a prerelease" >&2; return 1;
    }
}

asset_count() {
    jq --arg name "$2" '[.assets[]? | select(.name == $name)] | length' "$1"
}

asset_metadata() {
    jq --arg name "$2" -r --arg field "$3" '[.assets[]? | select(.name == $name)][0][$field] // empty' "$1"
}

validate_stable_dmg_names() {
    local json_file=$1
    if ! jq -e --arg expected "$dmg_name" \
        '[.assets[]? | select((.name | type) == "string" and (.name | test("\\.dmg$"; "i")) and .name != $expected)] | length == 0' \
        "$json_file" >/dev/null; then
        echo "error: stable release $tag contains a non-standard DMG" >&2
        return 1
    fi
}

validate_asset_metadata() {
    local json_file=$1 asset_name=$2 expected_url=$3 count state size digest browser_url draft_prefix draft_target
    count=$(asset_count "$json_file" "$asset_name")
    [[ $count == 1 ]] || { echo "error: release must contain exactly one $asset_name asset" >&2; return 1; }
    state=$(asset_metadata "$json_file" "$asset_name" state)
    size=$(asset_metadata "$json_file" "$asset_name" size)
    digest=$(asset_metadata "$json_file" "$asset_name" digest)
    browser_url=$(asset_metadata "$json_file" "$asset_name" browser_download_url)
    [[ $state == uploaded && $size =~ ^[1-9][0-9]*$ && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo "error: release asset $asset_name has invalid state, size, or SHA-256" >&2; return 1;
    }
    # Draft assets may use a temporary untagged URL on the same repository.
    draft_prefix="https://github.com/$repository/releases/download/untagged-"
    draft_target=${browser_url#"$draft_prefix"}
    if [[ $browser_url != "$expected_url" ]] && ! {
        [[ $(jq -r '.draft' "$json_file") == true && $browser_url == "$draft_prefix"* &&
           $draft_target == */"$asset_name" && ${draft_target%/*} =~ ^[A-Za-z0-9._-]+$ ]];
    }; then
        echo "error: release asset $asset_name has an invalid browser_download_url" >&2
        return 1
    fi
}

validate_release_dmg() {
    local json_file=$1 expected_commit=${2:-$commit} expected_name expected_url
    validate_release_identity "$json_file" || return
    if [[ $channel == stable ]]; then
        validate_stable_dmg_names "$json_file" || return
        expected_name=$dmg_name
    else
        expected_name="Motionpaper-${expected_commit:0:12}.dmg"
    fi
    expected_url="https://github.com/$repository/releases/download/$tag/$expected_name"
    validate_asset_metadata "$json_file" "$expected_name" "$expected_url"
}

validate_published_release() {
    local json_file=$1
    validate_release_dmg "$json_file" || return
    [[ $(jq -r '.draft' "$json_file") == false && -n $(jq -r '.published_at // empty' "$json_file") ]] || {
        echo "error: release $tag is not a complete published release" >&2; return 1;
    }
    assert_tag_target
}

file_size() { wc -c <"$1" | tr -d '[:space:]'; }
file_sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

validate_dmg_contents() {
    local json_file=$1 expected_size=$2 expected_digest=$3
    [[ $(asset_metadata "$json_file" "$dmg_name" size) == "$expected_size" &&
       $(asset_metadata "$json_file" "$dmg_name" digest) == "$expected_digest" ]] || {
        echo "error: release asset $dmg_name size or SHA-256 does not match its bytes" >&2; return 1;
    }
}

if [[ $channel == autobuild ]]; then
    skip_if_branch_advanced
else
    assert_tag_target
fi

fetch_releases "$work_dir/releases.json"
release_file="$work_dir/release.json"
jq --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' "$work_dir/releases.json" >"$work_dir/matches.json"
count=$(jq 'length' "$work_dir/matches.json")
[[ $count -le 1 ]] || { echo "error: multiple releases use tag $tag" >&2; exit 1; }
release_exists=false
if [[ $count == 1 ]]; then
    release_exists=true
    jq '.[0]' "$work_dir/matches.json" >"$release_file"
    validate_release_identity "$release_file"
fi

if [[ $channel == autobuild ]]; then
    if tag_commit=$(resolve_tag_commit "$tag"); then
        tag_object=$(jq -r '.object.sha' "$work_dir/tag-ref.json")
    else
        status=$?
        [[ $status == 2 ]] || exit 1
        if [[ $release_exists == true && $(jq -r '.draft' "$release_file") == false ]]; then
            echo "error: published Autobuild release has no tag" >&2
            exit 1
        fi
        skip_if_branch_advanced
        gh api --method POST "repos/$repository/git/refs" -f "ref=refs/tags/$tag" -f "sha=$commit" >"$work_dir/created-tag.json"
        tag_commit=$commit
        tag_object=$commit
    fi
    if [[ $release_exists == true ]]; then
        if [[ $(jq -r '.draft' "$release_file") == false ]]; then
            validate_release_dmg "$release_file" "$tag_commit"
            [[ -n $(jq -r '.published_at // empty' "$release_file") ]] || { echo "error: Autobuild release has no publication time" >&2; exit 1; }
        fi
        if [[ $tag_commit != "$commit" && ${tag_commit:0:12} == ${commit:0:12} ]]; then
            echo "error: Autobuild commits collide on the DMG name" >&2
            exit 1
        fi
    fi
fi

if [[ $release_exists == false ]]; then
    if [[ $channel == stable ]]; then
        release_name="Motionpaper $version"
        release_notes="Support/ReleaseNotes/$version.md"
        if [[ -f $release_notes ]]; then
            cp "$release_notes" "$work_dir/release-body.md"
        else
            printf 'Motionpaper stable release %s.\n' "$version" >"$work_dir/release-body.md"
        fi
    else
        release_name=Autobuild
        printf '%s\n' "$autobuild_body" >"$work_dir/release-body.md"
    fi
    jq -n --arg tag_name "$tag" --arg target_commitish "$commit" --arg name "$release_name" \
        --rawfile body "$work_dir/release-body.md" \
        '{tag_name: $tag_name, target_commitish: $target_commitish, name: $name, body: $body, draft: true, prerelease: false, make_latest: "false"}' \
        >"$work_dir/release-request.json"
    gh api --method POST "repos/$repository/releases" --input "$work_dir/release-request.json" >"$release_file"
    validate_release_identity "$release_file"
fi

release_id=$(jq -r '.id' "$release_file")
[[ $release_id =~ ^[1-9][0-9]*$ ]] || { echo "error: release has an invalid id" >&2; exit 1; }
release_is_draft=$(jq -r '.draft' "$release_file")
[[ $release_is_draft == true || $release_is_draft == false ]] || { echo "error: invalid release draft state" >&2; exit 1; }
if [[ $channel == stable ]]; then
    validate_release_identity "$release_file"
    validate_stable_dmg_names "$release_file"
fi

reuse=false
if [[ $release_is_draft == false ]]; then
    if [[ $channel == stable || $tag_commit == "$commit" ]]; then
        validate_published_release "$release_file"
        if [[ $channel == autobuild && $(jq -r '.body // empty' "$release_file") != "$autobuild_body" ]]; then
            skip_if_branch_advanced
            printf '%s\n' "$autobuild_body" >"$work_dir/release-body.md"
            jq -n --rawfile body "$work_dir/release-body.md" \
                '{name: "Autobuild", body: $body, make_latest: "false"}' >"$work_dir/description-request.json"
            gh api --method PATCH "repos/$repository/releases/$release_id" \
                --input "$work_dir/description-request.json" >"$release_file"
            validate_published_release "$release_file"
            [[ $(jq -r '.body // empty' "$release_file") == "$autobuild_body" ]] || {
                echo "error: Autobuild description was not updated" >&2; exit 1;
            }
        fi
        reuse=true
    fi
fi

if [[ $reuse == false ]]; then
    dmg_count=$(asset_count "$release_file" "$dmg_name")
    if [[ $dmg_count == 0 ]]; then
        [[ -s $dmg_path ]] || { echo "error: release DMG not found: $dmg_path" >&2; exit 1; }
        verified_dmg_size=$(file_size "$dmg_path")
        verified_dmg_digest="sha256:$(file_sha256 "$dmg_path")"
        gh release upload "$tag" "$dmg_path" --repo "$repository"
    elif [[ $dmg_count == 1 ]]; then
        validate_asset_metadata "$release_file" "$dmg_name" "$download_url"
        mkdir -p "$work_dir/existing-dmg"
        gh release download "$tag" --repo "$repository" --pattern "$dmg_name" --dir "$work_dir/existing-dmg" --clobber
        verified_dmg_size=$(file_size "$work_dir/existing-dmg/$dmg_name")
        verified_dmg_digest="sha256:$(file_sha256 "$work_dir/existing-dmg/$dmg_name")"
        validate_dmg_contents "$release_file" "$verified_dmg_size" "$verified_dmg_digest"
    else
        echo "error: release $tag contains duplicate $dmg_name assets" >&2
        exit 1
    fi

    gh api "repos/$repository/releases/$release_id" >"$work_dir/uploaded.json"
    validate_release_identity "$work_dir/uploaded.json"
    if [[ $channel == stable ]]; then validate_stable_dmg_names "$work_dir/uploaded.json"; fi
    validate_asset_metadata "$work_dir/uploaded.json" "$dmg_name" "$download_url"
    validate_dmg_contents "$work_dir/uploaded.json" "$verified_dmg_size" "$verified_dmg_digest"

    if [[ $channel == autobuild ]]; then
        skip_if_branch_advanced
        current_tag_commit=$(resolve_tag_commit "$tag") || { echo "error: could not recheck Autobuild tag" >&2; exit 1; }
        current_tag_object=$(jq -r '.object.sha' "$work_dir/tag-ref.json")
        [[ $current_tag_commit == "$tag_commit" && $current_tag_object == "$tag_object" ]] || {
            echo "error: Autobuild tag changed during upload" >&2; exit 1;
        }
        tag_commit=$current_tag_commit
        skip_if_branch_advanced
        if [[ $tag_commit != "$commit" ]]; then
            gh api --method PATCH "repos/$repository/git/refs/tags/$tag" -f "sha=$commit" -F force=true >"$work_dir/moved-tag.json"
        fi
        assert_tag_target
        skip_if_branch_advanced
        printf '%s\n' "$autobuild_body" >"$work_dir/release-body.md"
        jq -n --rawfile body "$work_dir/release-body.md" \
            '{name: "Autobuild", body: $body, draft: false, make_latest: "false"}' \
            >"$work_dir/publish-request.json"
    else
        assert_tag_target
        python3 "$script_dir/publish-update-feed.py" --verified-release "$work_dir/uploaded.json" --result "$work_dir/feed-result.json"
        fetch_releases "$work_dir/pre-publish-releases.json"
        previous_stable_row=$(highest_stable_release "$work_dir/pre-publish-releases.json")
        make_latest=false
        if [[ -z $previous_stable_row ]]; then
            make_latest=true
        else
            IFS=$'\t' read -r _ previous_stable_tag <<<"$previous_stable_row"
            if version_at_least "$version" "${previous_stable_tag#v}"; then make_latest=true; fi
        fi
        jq -n --arg make_latest "$make_latest" '{draft: false, make_latest: $make_latest}' >"$work_dir/publish-request.json"
    fi
    gh api --method PATCH "repos/$repository/releases/$release_id" --input "$work_dir/publish-request.json" >"$work_dir/published.json"
    gh api "repos/$repository/releases/$release_id" >"$release_file"
    validate_published_release "$release_file"
    validate_dmg_contents "$release_file" "$verified_dmg_size" "$verified_dmg_digest"
    if [[ $channel == stable ]]; then
        python3 "$script_dir/publish-update-feed.py" --verified-release "$release_file" --result "$work_dir/feed-result.json" --verify-only
    fi
fi

if [[ $channel == autobuild || $reuse == true ]]; then
    python3 "$script_dir/publish-update-feed.py" --verified-release "$release_file" --result "$work_dir/feed-result.json"
fi

if [[ $channel == stable ]]; then
    fetch_releases "$work_dir/releases-final.json"
    reconcile_latest_stable "$work_dir/releases-final.json"
fi

if [[ $reuse == false ]]; then
    echo "Published $channel release $tag for $commit."
else
    echo "Reusing complete published $channel release $tag."
fi

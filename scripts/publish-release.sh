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

is_current_latest_release() {
    [[ $(current_latest_tag) == "$tag" ]]
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
    [[ $browser_url == "$expected_url" ]] || { echo "error: release asset $asset_name has an invalid browser_download_url" >&2; return 1; }
}

validate_update_manifest() {
    local manifest_path=$1 expected_commit=$2 expected_url=$3 dmg_size=$4 dmg_digest=$5
    jq -e \
        --arg commit "$expected_commit" \
        --arg url "$expected_url" \
        --arg sha256 "${dmg_digest#sha256:}" \
        --argjson size "$dmg_size" \
        'type == "object" and
         (keys | sort) == ["commit", "downloadURL", "publishedAt", "sha256", "size"] and
         .commit == $commit and
         .downloadURL == $url and
         (.publishedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
         .sha256 == $sha256 and
         .size == $size and
         (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
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
    else
        [[ $update_count == 0 ]] || { echo "error: stable release must not contain update.json" >&2; return 1; }
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

    if [[ $expected_channel == autobuild ]]; then
        uploaded_size=$(asset_metadata "$json_file" update.json size)
        uploaded_digest=$(asset_metadata "$json_file" update.json digest)
        local_size=$(file_size "$update_path")
        local_digest=$(file_sha256 "$update_path")
        [[ $uploaded_size == "$local_size" && $uploaded_digest == "sha256:$local_digest" ]] || {
            echo "error: uploaded update.json size or SHA-256 does not match the manifest" >&2
            return 1
        }
        validate_asset_metadata "$json_file" update.json "$(asset_download_url "$expected_tag" update.json)" || return
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
        [[ $update_count == 0 ]] || { echo "error: stable release $expected_tag unexpectedly contains update.json" >&2; return 1; }
    fi

    if [[ $expected_channel == autobuild ]]; then
        mkdir -p "$validation_dir"
        gh release download "$expected_tag" --repo "$repository" --pattern update.json --dir "$validation_dir" || return
        update_size=$(asset_metadata "$json_file" update.json size)
        update_digest=$(asset_metadata "$json_file" update.json digest)
        downloaded_size=$(file_size "$manifest")
        downloaded_digest=$(file_sha256 "$manifest")
        [[ $downloaded_size == "$update_size" && "sha256:$downloaded_digest" == "$update_digest" ]] || {
            echo "error: published update.json asset size or SHA-256 is invalid for $expected_tag" >&2
            return 1
        }
        validate_update_manifest "$manifest" "$expected_commit" "$expected_url" "$dmg_size" "$dmg_digest"
    fi
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

mark_release_latest() {
    gh api --method PATCH "repos/$repository/releases/$release_id" -f make_latest=true >"$work_dir/latest-release.json"
    is_current_latest_release || {
        echo "error: GitHub latest release is not $tag after publishing" >&2
        return 1
    }
}

if [[ $release_exists == true && $release_is_draft == false ]]; then
    validate_published_release \
        "$release_file" "$tag" "$commit" "$channel" "$dmg_name" "$download_url" \
        "$work_dir/reuse-assets"
    release_id=$(jq -r '.id' "$release_file")
    if [[ $channel == autobuild ]]; then
        mark_release_latest
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
    while IFS= read -r asset_id; do
        [[ -n $asset_id ]] && gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
    done < <(jq -r '.assets[]?.id' "$release_file")

    update_path=''
    if [[ $channel == autobuild ]]; then
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
        gh release upload "$tag" "$dmg_path" --repo "$repository"
    fi

    gh api "repos/$repository/releases/$release_id" >"$work_dir/uploaded.json"
    validate_uploaded_assets \
        "$work_dir/uploaded.json" "$tag" "$commit" "$channel" "$dmg_name" "$download_url" "$dmg_path" "$update_path"
    assert_tag_target "$tag" "$commit"

    if [[ $channel == autobuild ]] && ! is_current_default_head; then
        echo "Leaving draft $commit unpublished: $default_branch advanced during packaging."
        exit 0
    fi

    if [[ $channel == stable ]]; then
        make_latest=false
    else
        make_latest=true
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
        is_current_latest_release || {
            echo "error: GitHub latest release is not $tag after publishing" >&2
            exit 1
        }
    fi
    echo "Published $channel release $tag for $commit."
fi

if [[ $channel != autobuild ]]; then
    exit 0
fi

# Cleanup runs only for a current master/default-branch Autobuild that still owns GitHub latest.
if ! is_current_default_head || ! is_current_latest_release; then
    echo "Skipping old release cleanup: current branch head or latest release changed."
    exit 0
fi
if [[ $repository != "notCorwin/Motionpaper" ]]; then
    echo "Skipping obsolete release cleanup outside notCorwin/Motionpaper."
    exit 0
fi

gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq '.[] | [.id, .tag_name, .target_commitish, (.draft | tostring)] | @tsv' \
    >"$work_dir/release-rows.tsv"
: >"$work_dir/complete-autobuilds.tsv"
while IFS=$'\t' read -r old_release_id old_tag old_target old_draft; do
    [[ -n $old_release_id ]] || continue
    [[ $old_release_id != "$release_id" && $old_tag != "$tag" ]] || continue
    [[ $old_tag =~ ^Autobuild-([0-9a-f]{40})$ ]] || continue
    old_commit=${BASH_REMATCH[1]}
    [[ $old_draft == false && $old_target == "$old_commit" ]] || continue
    if ! resolved_old_commit=$(resolve_tag_commit "$old_tag") || [[ $resolved_old_commit != "$old_commit" ]]; then
        continue
    fi

    old_dmg_name="Motionpaper-${old_commit:0:12}.dmg"
    old_download_url="https://github.com/$repository/releases/download/$old_tag/$old_dmg_name"
    old_release_file="$work_dir/old-release-$old_release_id.json"
    if ! gh api "repos/$repository/releases/$old_release_id" >"$old_release_file" 2>/dev/null; then
        continue
    fi
    old_published_at=$(jq -r '.published_at // empty' "$old_release_file")
    if [[ -z $old_published_at ]] || ! validate_published_release \
        "$old_release_file" "$old_tag" "$old_commit" autobuild "$old_dmg_name" "$old_download_url" \
        "$work_dir/old-assets-$old_release_id" >/dev/null 2>&1; then
        echo "Retaining incomplete or invalid Autobuild release $old_tag."
        continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$old_published_at" "$old_release_id" "$old_tag" "$old_commit" \
        >>"$work_dir/complete-autobuilds.tsv"
done <"$work_dir/release-rows.tsv"

sort -r -t $'\t' -k1,1 "$work_dir/complete-autobuilds.tsv" >"$work_dir/sorted-autobuilds.tsv"
kept_count=1 # The already-validated current release is always one of the three retained releases.
while IFS=$'\t' read -r old_published_at old_release_id old_tag old_commit; do
    [[ -n $old_release_id ]] || continue
    [[ $old_release_id != "$release_id" && $old_tag != "$tag" ]] || continue
    if (( kept_count < 3 )); then
        ((kept_count += 1))
        continue
    fi
    if ! is_current_default_head || ! is_current_latest_release; then
        echo "Stopping old release cleanup: current branch head or latest release changed."
        exit 0
    fi
    # Only validated, complete Autobuild releases can reach this point.
    gh api --method DELETE "repos/$repository/releases/$old_release_id"
    if resolved_old_commit=$(resolve_tag_commit "$old_tag") && [[ $resolved_old_commit == "$old_commit" ]]; then
        gh api --method DELETE "repos/$repository/git/refs/tags/$old_tag"
    fi
done <"$work_dir/sorted-autobuilds.tsv"

#!/usr/bin/env bash
set -euo pipefail

repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
commit=${RELEASE_COMMIT:?RELEASE_COMMIT is required}
default_branch=${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}
: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: RELEASE_COMMIT must be a lowercase full git commit hash" >&2
    exit 1
fi
if [[ ! $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "error: GITHUB_REPOSITORY must be in owner/repository form" >&2
    exit 1
fi

# GitHub rejects tags consisting solely of a full hexadecimal object ID.
tag="Autobuild-$commit"
short_commit=${commit:0:12}
dmg_name="Motionpaper-$short_commit.dmg"
dmg_path="dist/$dmg_name"
download_url="https://github.com/$repository/releases/download/$tag/$dmg_name"
[[ -s $dmg_path ]] || { echo "error: release DMG not found: $dmg_path" >&2; exit 1; }

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

branch_path=$(jq -rn --arg branch "$default_branch" '$branch | @uri')
default_branch_head() {
    gh api "repos/$repository/branches/$branch_path" --jq '.commit.sha'
}

is_current_default_head() {
    local current_head
    current_head=$(default_branch_head)
    [[ $current_head == "$commit" ]]
}

if ! is_current_default_head; then
    echo "Skipping release for $commit: $default_branch has advanced."
    exit 0
fi

release_file="$work_dir/release.json"
release_exists=false
# The tag endpoint omits unpublished drafts; the authenticated list includes them.
gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$tag\")" >"$work_dir/matching-releases.json"
if [[ -s $work_dir/matching-releases.json ]]; then
    # A failed creation can leave a draft behind. Prefer an already published
    # release, otherwise resume one draft and remove duplicates after publishing.
    jq -s 'sort_by(.draft, .id) | first' "$work_dir/matching-releases.json" >"$release_file"
    release_exists=true
    release_tag=$(jq -r '.tag_name' "$release_file")
    release_target=$(jq -r '.target_commitish' "$release_file")
    [[ $release_tag == "$tag" && $release_target == "$commit" ]] || {
        echo "error: release tag $commit is not a commit-targeted Motionpaper release" >&2
        exit 1
    }
fi

release_is_draft=false
if [[ $release_exists == true ]]; then
    release_is_draft=$(jq -r '.draft' "$release_file")
fi

validate_published_release() {
    local json_file=$1
    local published
    local validation_dir="$work_dir/published-assets"
    local manifest="$validation_dir/update.json"
    local asset_size
    local asset_digest

    published=$(jq -r '.published_at // empty' "$json_file")
    [[ -n $published ]] || { echo "error: published release has no published_at timestamp" >&2; return 1; }

    local dmg_count update_count
    dmg_count=$(jq --arg name "$dmg_name" '[.assets[] | select(.name == $name and .size > 0)] | length' "$json_file")
    update_count=$(jq '[.assets[] | select(.name == "update.json" and .size > 0)] | length' "$json_file")
    [[ $dmg_count == 1 && $update_count == 1 ]] || {
        echo "error: published release is missing its complete DMG or update.json asset" >&2
        return 1
    }

    mkdir -p "$validation_dir"
    gh release download "$tag" --repo "$repository" --pattern update.json --dir "$validation_dir"
    jq -e \
        --arg commit "$commit" \
        --arg url "$download_url" \
        'type == "object" and
         .commit == $commit and
         .downloadURL == $url and
         (.publishedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
         (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
         (.size | type == "number" and . > 0 and floor == .)' \
        "$manifest" >/dev/null || {
        echo "error: published release update.json does not satisfy the updater contract" >&2
        return 1
    }

    asset_size=$(jq --arg name "$dmg_name" '[.assets[] | select(.name == $name)][0].size' "$json_file")
    [[ $(jq -r '.size' "$manifest") == "$asset_size" ]] || {
        echo "error: published release DMG size does not match update.json" >&2
        return 1
    }
    asset_digest=$(jq --arg name "$dmg_name" -r '[.assets[] | select(.name == $name)][0].digest // empty' "$json_file")
    [[ $asset_digest == "sha256:$(jq -r '.sha256' "$manifest")" ]] || {
        echo "error: published release DMG digest does not match update.json" >&2
        return 1
    }
}

mark_release_latest() {
    # GitHub documents make_latest as the string enum "true", "false", or "legacy".
    gh api --method PATCH "repos/$repository/releases/$release_id" -f make_latest=true >"$work_dir/latest-release.json"
    local latest_tag
    latest_tag=$(gh api "repos/$repository/releases/latest" --jq '.tag_name')
    [[ $latest_tag == "$tag" ]] || {
        echo "error: GitHub latest release is $latest_tag instead of $tag" >&2
        return 1
    }
}

if [[ $release_exists == true && $release_is_draft == false ]]; then
    validate_published_release "$release_file"
    release_id=$(jq -r '.id' "$release_file")
    mark_release_latest
    echo "Reusing complete published release $commit."
else
    # A commit-named tag must point directly at that commit before it can be used.
    if gh api "repos/$repository/git/ref/tags/$tag" >"$work_dir/tag.json" 2>/dev/null; then
        tag_type=$(jq -r '.object.type' "$work_dir/tag.json")
        tag_object=$(jq -r '.object.sha' "$work_dir/tag.json")
        [[ $tag_type == commit && $tag_object == "$commit" ]] || {
            echo "error: tag $commit exists but does not point directly at commit $commit" >&2
            exit 1
        }
    fi

    if [[ $release_exists == false ]]; then
        if ! gh api --method POST "repos/$repository/releases" \
            -f tag_name="$tag" \
            -f target_commitish="$commit" \
            -f name="Autobuild" \
            -f body="Automated release for $default_branch commit $commit." \
            -F draft=true >"$release_file"; then
            cat "$release_file" >&2
            exit 1
        fi
    fi

    release_id=$(jq -r '.id' "$release_file")
    while IFS= read -r asset_id; do
        [[ -n $asset_id ]] && gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
    done < <(jq -r '.assets[]?.id' "$release_file")

    dmg_size=$(stat -c '%s' "$dmg_path")
    dmg_sha256=$(sha256sum "$dmg_path" | cut -d ' ' -f 1)
    published_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -n -S \
        --arg commit "$commit" \
        --arg publishedAt "$published_at" \
        --arg downloadURL "$download_url" \
        --arg sha256 "$dmg_sha256" \
        --argjson size "$dmg_size" \
        '{commit: $commit, publishedAt: $publishedAt, downloadURL: $downloadURL, sha256: $sha256, size: $size}' \
        >"$work_dir/update.json"

    gh release upload "$tag" "$dmg_path" "$work_dir/update.json" \
        --repo "$repository" --clobber

    # Recheck immediately before making the draft visible through latest/download.
    if ! is_current_default_head; then
        echo "Leaving draft $commit unpublished: $default_branch advanced during packaging."
        exit 0
    fi

    # Keep draft boolean-typed while make_latest remains a string enum.
    if ! gh api --method PATCH "repos/$repository/releases/$release_id" -F draft=false -f make_latest=true >"$work_dir/published.json"; then
        cat "$work_dir/published.json" >&2
        exit 1
    fi
    [[ $(jq -r '.draft' "$work_dir/published.json") == false ]] || {
        echo "error: GitHub did not publish release $commit" >&2
        exit 1
    }
    latest_tag=$(gh api "repos/$repository/releases/latest" --jq '.tag_name')
    [[ $latest_tag == "$tag" ]] || {
        echo "error: GitHub latest release is $latest_tag instead of $tag" >&2
        exit 1
    }
    gh api "repos/$repository/releases/tags/$tag" >"$release_file"
    validate_published_release "$release_file"
    echo "Published release $commit."
fi

# A final check prevents an outdated queued run from cleaning up after the branch moved.
if ! is_current_default_head; then
    echo "Skipping old release cleanup: $default_branch advanced after publication."
    exit 0
fi

if [[ $repository != "notCorwin/Motionpaper" ]]; then
    echo "Skipping obsolete release cleanup outside notCorwin/Motionpaper."
    exit 0
fi

# Remove every obsolete release only after the current release is published and
# confirmed as latest. Tag deletion is separately restricted to direct commit refs.
gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq '.[] | [.id, .tag_name, .target_commitish] | @tsv' \
    >"$work_dir/release-rows.tsv"

while IFS=$'\t' read -r old_release_id old_tag old_target; do
    [[ -n $old_release_id ]] || continue
    [[ $old_release_id != "$release_id" ]] || continue

    gh api --method DELETE "repos/$repository/releases/$old_release_id"
    old_commit=${old_tag#Autobuild-}
    if [[ $old_tag != "$tag" && $old_commit =~ ^[0-9a-f]{40}$ && $old_target == "$old_commit" ]]; then
        if gh api "repos/$repository/git/ref/tags/$old_tag" >"$work_dir/old-tag.json" 2>/dev/null; then
            old_tag_type=$(jq -r '.object.type' "$work_dir/old-tag.json")
            old_tag_object=$(jq -r '.object.sha' "$work_dir/old-tag.json")
            if [[ $old_tag_type == commit && $old_tag_object == "$old_commit" ]]; then
                gh api --method DELETE "repos/$repository/git/refs/tags/$old_tag"
            fi
        fi
    fi
done <"$work_dir/release-rows.tsv"

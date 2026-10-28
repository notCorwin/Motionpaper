#!/usr/bin/env python3
"""Merge verified release metadata into the data-only updates branch."""

import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote


SHA = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
STABLE = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\Z")


class FeedError(Exception):
    pass


class GitHubError(FeedError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class GitHub:
    def __init__(self, repository):
        self.prefix = f"repos/{repository}/"

    def api(self, route, *, method="GET", payload=None, paginate=False, missing_ok=False):
        command = ["gh", "api", "--method", method, self.prefix + route]
        if paginate:
            command += ["--paginate", "--slurp"]
        if payload is not None:
            command += ["--input", "-"]
        result = subprocess.run(
            command, input=json.dumps(payload) if payload is not None else None,
            text=True, capture_output=True, check=False,
        )
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            status_match = re.search(r"\(HTTP (\d{3})\)", detail)
            status = int(status_match.group(1)) if status_match else None
            if missing_ok and status == 404:
                return None
            raise GitHubError(f"GitHub {method} {route}: {detail}", status)
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except json.JSONDecodeError as error:
            raise GitHubError(f"GitHub {method} {route} returned invalid JSON") from error

    def head(self):
        ref = self.api("git/ref/heads/updates", missing_ok=True)
        if ref is None:
            return None
        obj = ref.get("object", {})
        sha = obj.get("sha", "")
        if obj.get("type") != "commit" or not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise FeedError("updates branch does not point to a full commit hash")
        return sha

    def default_head(self, branch):
        response = self.api(f"branches/{quote(branch, safe='')}")
        sha = response.get("commit", {}).get("sha", "")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise FeedError("default branch has an invalid commit")
        return sha

    def releases(self):
        pages = self.api("releases?per_page=100", paginate=True)
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise FeedError("invalid paginated release catalog")
        return [release for page in pages for release in page]

    def tag_commit(self, tag):
        obj = self.api(f"git/ref/tags/{tag}").get("object", {})
        for _ in range(10):
            sha = obj.get("sha", "")
            if not isinstance(sha, str) or not SHA.fullmatch(sha):
                break
            if obj.get("type") == "commit":
                return sha
            if obj.get("type") != "tag":
                break
            obj = self.api(f"git/tags/{sha}").get("object", {})
        raise FeedError(f"release tag {tag} does not resolve to a full commit hash")

    def read_feed(self, head, repository):
        commit = self.api(f"git/commits/{head}")
        tree_sha = commit.get("tree", {}).get("sha", "")
        if not isinstance(tree_sha, str) or not SHA.fullmatch(tree_sha):
            raise FeedError("updates commit has an invalid tree")
        tree = self.api(f"git/trees/{tree_sha}")
        entries = tree.get("tree")
        if tree.get("truncated") or not isinstance(entries, list) or len(entries) != 1:
            raise FeedError("updates tree must contain only update.json")
        entry = entries[0]
        if (entry.get("path"), entry.get("mode"), entry.get("type")) != ("update.json", "100644", "blob"):
            raise FeedError("updates tree must contain only update.json")
        blob_sha = entry.get("sha", "")
        if not isinstance(blob_sha, str) or not SHA.fullmatch(blob_sha):
            raise FeedError("updates tree has an invalid blob")
        blob = self.api(f"git/blobs/{blob_sha}")
        if blob.get("encoding") != "base64" or not isinstance(blob.get("content"), str):
            raise FeedError("updates blob has an unsupported encoding")
        try:
            content = base64.b64decode("".join(blob["content"].split()), validate=True)
            if len(content) > 16384:
                raise ValueError("feed is too large")
            feed = json.loads(content, object_pairs_hook=unique_object)
        except (ValueError, UnicodeDecodeError) as error:
            raise FeedError("updates blob is not a valid feed") from error
        validate_feed(feed, repository)
        return feed


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate field {key}")
        result[key] = value
    return result


def published_time(value, name):
    if not isinstance(value, str) or not TIMESTAMP.fullmatch(value):
        raise FeedError(f"{name} has an invalid timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise FeedError(f"{name} has an invalid timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise FeedError(f"{name} timestamp is missing a timezone")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def version_key(version):
    match = STABLE.fullmatch("v" + version) if isinstance(version, str) else None
    if not match:
        raise FeedError("invalid stable version")
    return tuple(map(int, match.groups()))


def validate_feed(feed, repository):
    if not isinstance(feed, dict) or not feed or not set(feed) <= {"autobuild", "stable"}:
        raise FeedError("updates feed has invalid channels")
    for channel, entry in feed.items():
        fields = {"commit", "publishedAt", "downloadURL", "sha256", "size"}
        if channel == "stable":
            fields.add("version")
        if not isinstance(entry, dict) or set(entry) != fields:
            raise FeedError(f"updates feed has an invalid {channel} entry")
        commit = entry["commit"]
        digest = entry["sha256"]
        size = entry["size"]
        if (not isinstance(commit, str) or not SHA.fullmatch(commit)
                or not isinstance(digest, str) or not SHA256.fullmatch(digest)
                or type(size) is not int or not 0 < size <= (1 << 63) - 1):
            raise FeedError(f"updates feed has an invalid {channel} hash or size")
        published_time(entry["publishedAt"], channel)
        if channel == "stable":
            version_key(entry["version"])
            tag = "v" + entry["version"]
            name = f"Motionpaper-{tag}.dmg"
        else:
            tag = "Autobuild"
            name = f"Motionpaper-{commit[:12]}.dmg"
        if entry["downloadURL"] != f"https://github.com/{repository}/releases/download/{tag}/{name}":
            raise FeedError(f"updates feed has an invalid {channel} URL")


def feed_entry(github, repository, channel, release):
    if not isinstance(release, dict):
        raise FeedError("invalid release")
    tag = release.get("tag_name")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise FeedError(f"release {tag} is not published")
    published_time(release.get("published_at"), tag)
    if channel == "autobuild":
        if tag != "Autobuild":
            raise FeedError("invalid Autobuild tag")
    elif not isinstance(tag, str) or not STABLE.fullmatch(tag):
        raise FeedError("invalid stable tag")
    # target_commitish is a tag-creation input, not the current target of a moving tag.
    commit = github.tag_commit(tag)
    name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-{tag}.dmg"
    assets = release.get("assets")
    if not isinstance(assets, list) or any(not isinstance(asset, dict) for asset in assets):
        raise FeedError(f"release {tag} has invalid assets")
    dmgs = [asset for asset in assets if isinstance(asset.get("name"), str) and asset["name"].lower().endswith(".dmg")]
    matches = [asset for asset in dmgs if asset["name"] == name]
    if len(matches) != 1 or (channel == "stable" and len(dmgs) != 1):
        raise FeedError(f"release {tag} has an invalid DMG set")
    dmg = matches[0]
    if dmg.get("state") != "uploaded":
        raise FeedError(f"release {tag} DMG is not uploaded")
    digest = dmg.get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not SHA256.fullmatch(digest[7:]):
        raise FeedError(f"release {tag} DMG has an invalid SHA-256")
    # The fixed Autobuild release's published_at never changes; the asset is unique per commit.
    timestamp = dmg.get("created_at") if channel == "autobuild" else release.get("published_at")
    entry = {
        "commit": commit,
        "publishedAt": published_time(timestamp, tag),
        "downloadURL": dmg.get("browser_download_url"),
        "sha256": digest[7:],
        "size": dmg.get("size"),
    }
    if channel == "stable":
        entry["version"] = tag[1:]
    validate_feed({channel: entry}, repository)
    return entry


def select_other_release(releases, channel):
    candidates = []
    for release in releases:
        if not isinstance(release, dict):
            raise FeedError("invalid release catalog entry")
        if release.get("draft") is not False or release.get("prerelease") is not False:
            continue
        tag = release.get("tag_name")
        if channel == "autobuild" and tag == "Autobuild":
            candidates.append(release)
        elif channel == "stable" and isinstance(tag, str) and STABLE.fullmatch(tag):
            candidates.append(release)
    if channel == "autobuild":
        if len(candidates) > 1:
            raise FeedError("multiple published Autobuild releases")
        return candidates[0] if candidates else None
    return max(candidates, key=lambda item: version_key(item["tag_name"][1:]), default=None)


def checked_candidate(github, repository, channel, expected):
    release_id = expected.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise FeedError("verified release has an invalid id")
    current = github.api(f"releases/{release_id}")
    expected_entry = feed_entry(github, repository, channel, expected)
    current_entry = feed_entry(github, repository, channel, current)
    if current.get("id") != release_id or current_entry != expected_entry:
        raise FeedError("the verified release changed before the feed update")
    return expected_entry


def publish(github, repository, channel, commit, branch, expected):
    for attempt in range(3):
        if channel == "autobuild" and github.default_head(branch) != commit:
            raise FeedError("default branch advanced before the Autobuild feed update")
        head = github.head()
        candidate = checked_candidate(github, repository, channel, expected)
        if candidate["commit"] != commit:
            raise FeedError("verified release tag does not target RELEASE_COMMIT")
        if head:
            feed = github.read_feed(head, repository)
        else:
            feed = {}
            other = "stable" if channel == "autobuild" else "autobuild"
            releases = github.releases()
            release = select_other_release(releases, other)
            if release is not None:
                feed[other] = feed_entry(github, repository, other, release)
            # A backfill can be the first publisher even when a newer stable release exists.
            if channel == "stable":
                highest = select_other_release(releases, "stable")
                if highest is not None and version_key(highest["tag_name"][1:]) > version_key(candidate["version"]):
                    candidate = feed_entry(github, repository, "stable", highest)

        previous = feed.get(channel)
        if channel == "stable" and previous:
            old_version, new_version = version_key(previous["version"]), version_key(candidate["version"])
            if new_version < old_version:
                candidate = previous
            elif new_version == old_version and any(previous[field] != candidate[field]
                    for field in ("commit", "downloadURL", "sha256", "size")):
                raise FeedError("published stable version conflicts with the existing feed")
        changed = previous != candidate
        feed[channel] = candidate
        validate_feed(feed, repository)
        if head and not changed:
            if github.head() == head:
                return {"head": head, "feed": feed, "changed": False}
            continue

        content = json.dumps(feed, indent=2, ensure_ascii=False) + "\n"
        if len(content.encode("utf-8")) > 16384:
            raise FeedError("updates feed is too large")
        tree = github.api("git/trees", method="POST", payload={"tree": [{
            "path": "update.json", "mode": "100644", "type": "blob", "content": content,
        }]})
        tree_sha = tree.get("sha", "")
        if not isinstance(tree_sha, str) or not SHA.fullmatch(tree_sha):
            raise FeedError("GitHub returned an invalid updates tree hash")
        new_commit = github.api("git/commits", method="POST", payload={
            "message": "Update release index", "tree": tree_sha, "parents": [head] if head else [],
            "author": {"name": "github-actions[bot]", "email": "41898282+github-actions[bot]@users.noreply.github.com"},
        })
        new_head = new_commit.get("sha", "")
        if not isinstance(new_head, str) or not SHA.fullmatch(new_head):
            raise FeedError("GitHub returned an invalid updates commit hash")
        if channel == "autobuild":
            if github.default_head(branch) != commit:
                raise FeedError("default branch advanced before the Autobuild feed update")
            if checked_candidate(github, repository, channel, expected) != candidate:
                raise FeedError("Autobuild changed before the feed update")
        try:
            if head:
                github.api("git/refs/heads/updates", method="PATCH", payload={"sha": new_head, "force": False})
            else:
                github.api("git/refs", method="POST", payload={"ref": "refs/heads/updates", "sha": new_head})
        except GitHubError as error:
            if error.status not in (409, 422):
                raise
            actual_head = github.head()
            if actual_head == head:
                raise
            if attempt == 2:
                raise FeedError("updates branch changed during all three publishing attempts") from error
            continue
        return {"head": new_head, "feed": feed, "changed": True}
    raise FeedError("updates branch changed during all three publishing attempts")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verified-release", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    channel = os.environ.get("MOTIONPAPER_RELEASE_CHANNEL", "autobuild")
    commit = os.environ.get("RELEASE_COMMIT", "")
    branch = os.environ.get("DEFAULT_BRANCH", "")
    if (not REPOSITORY.fullmatch(repository) or any(part in (".", "..") for part in repository.split("/"))
            or not os.environ.get("GH_TOKEN") or not SHA.fullmatch(commit)
            or channel not in ("autobuild", "stable") or (channel == "autobuild" and not branch)):
        raise FeedError("invalid repository, token, commit, channel, or default branch")
    expected = json.loads(args.verified_release.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(expected, dict):
        raise FeedError("invalid verified release")
    if channel == "stable" and expected.get("tag_name") != "v" + os.environ.get("MOTIONPAPER_VERSION", ""):
        raise FeedError("verified stable tag does not match MOTIONPAPER_VERSION")
    result = publish(GitHub(repository), repository, channel, commit, branch, expected)
    args.result.write_text(json.dumps(result) + "\n", encoding="utf-8")
    print("Published updates branch index." if result["changed"] else "Updates branch index is unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (FeedError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

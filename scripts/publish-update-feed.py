#!/usr/bin/env python3
"""Publish a verified release's channel-specific update.json asset."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


SHA = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
STABLE = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\Z")


class FeedError(Exception):
    pass


class GitHub:
    def __init__(self, repository):
        self.repository = repository
        self.prefix = f"repos/{repository}/"

    def api(self, route):
        command = ["gh", "api", self.prefix + route]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise FeedError(f"GitHub GET {route}: {detail}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise FeedError(f"GitHub GET {route} returned invalid JSON") from error

    def default_head(self, branch):
        response = self.api(f"branches/{quote(branch, safe='')}")
        sha = response.get("commit", {}).get("sha", "")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise FeedError("default branch has an invalid commit")
        return sha

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

    def upload(self, tag, path):
        result = subprocess.run(
            ["gh", "release", "upload", tag, str(path), "--repo", self.repository, "--clobber"],
            text=True, capture_output=True, check=False,
        )
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise FeedError(f"GitHub upload update.json: {detail}")

    def delete_asset(self, asset_id):
        if type(asset_id) is not int or asset_id <= 0:
            raise FeedError("obsolete asset has an invalid id")
        result = subprocess.run(
            ["gh", "api", "--method", "DELETE", self.prefix + f"releases/assets/{asset_id}"],
            text=True, capture_output=True, check=False,
        )
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise FeedError(f"GitHub delete obsolete asset {asset_id}: {detail}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate field {key}")
        result[key] = value
    return result


def valid_repository(repository):
    return (isinstance(repository, str) and REPOSITORY.fullmatch(repository)
            and all(part not in (".", "..") for part in repository.split("/")))


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


def validate_feed(feed, repository):
    if not valid_repository(repository):
        raise FeedError("invalid repository")
    if not isinstance(feed, dict) or len(feed) != 1 or not set(feed) <= {"autobuild", "stable"}:
        raise FeedError("update feed has invalid channels")
    channel, entry = next(iter(feed.items()))
    fields = {"commit", "publishedAt", "downloadURL", "sha256", "size"}
    if channel == "stable":
        fields.add("version")
    if not isinstance(entry, dict) or set(entry) != fields:
        raise FeedError(f"update feed has an invalid {channel} entry")
    commit, digest, size = entry["commit"], entry["sha256"], entry["size"]
    if (not isinstance(commit, str) or not SHA.fullmatch(commit)
            or not isinstance(digest, str) or not SHA256.fullmatch(digest)
            or type(size) is not int or not 0 < size <= (1 << 63) - 1):
        raise FeedError(f"update feed has an invalid {channel} hash or size")
    published_time(entry["publishedAt"], channel)
    if channel == "stable":
        version = entry["version"]
        if not isinstance(version, str) or not STABLE.fullmatch("v" + version):
            raise FeedError("invalid stable version")
        tag = "v" + version
        name = f"Motionpaper-{tag}.dmg"
    else:
        tag = "Autobuild"
        name = f"Motionpaper-{commit[:12]}.dmg"
    if entry["downloadURL"] != f"https://github.com/{repository}/releases/download/{tag}/{name}":
        raise FeedError(f"update feed has an invalid {channel} URL")


def asset_url_valid(repository, tag, name, draft, url):
    base = f"https://github.com/{repository}/releases/download/"
    if url == f"{base}{tag}/{name}":
        return True
    return bool(draft and isinstance(url, str) and re.fullmatch(
        re.escape(base) + r"untagged-[A-Za-z0-9._-]+/" + re.escape(name), url
    ))


def validate_asset(asset, repository, tag, draft, name):
    if not isinstance(asset, dict) or asset.get("state") != "uploaded":
        raise FeedError(f"release {tag} asset {name} is not uploaded")
    size, digest = asset.get("size"), asset.get("digest")
    if (type(size) is not int or not 0 < size <= (1 << 63) - 1
            or not isinstance(digest, str) or not digest.startswith("sha256:")
            or not SHA256.fullmatch(digest[7:])):
        raise FeedError(f"release {tag} asset {name} has invalid size or SHA-256")
    if not asset_url_valid(repository, tag, name, draft, asset.get("browser_download_url")):
        raise FeedError(f"release {tag} asset {name} has an invalid browser_download_url")


def feed_entry(github, repository, channel, release):
    if not valid_repository(repository) or channel not in ("autobuild", "stable"):
        raise FeedError("invalid repository or channel")
    if not isinstance(release, dict):
        raise FeedError("invalid release")
    tag, draft = release.get("tag_name"), release.get("draft")
    if type(draft) is not bool or release.get("prerelease") is not False:
        raise FeedError(f"release {tag} has an invalid draft or prerelease state")
    if not draft:
        published_time(release.get("published_at"), tag)
    if channel == "autobuild":
        if tag != "Autobuild":
            raise FeedError("invalid Autobuild tag")
    elif not isinstance(tag, str) or not STABLE.fullmatch(tag):
        raise FeedError("invalid stable tag")
    # A release's target_commitish is ignored by GitHub if its tag already exists.
    commit = github.tag_commit(tag)
    name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-{tag}.dmg"
    assets = release.get("assets")
    if not isinstance(assets, list) or any(not isinstance(asset, dict) for asset in assets):
        raise FeedError(f"release {tag} has invalid assets")
    dmgs = [asset for asset in assets if isinstance(asset.get("name"), str) and asset["name"].lower().endswith(".dmg")]
    matches = [asset for asset in dmgs if asset["name"] == name]
    legacy_name = f"Motionpaper-{tag[1:]}-{commit[:12]}.dmg" if channel == "stable" else None
    legacy = [asset for asset in dmgs if asset["name"] == legacy_name]
    if len(matches) != 1 or (channel == "stable" and (len(legacy) > 1 or len(dmgs) != 1 + len(legacy))):
        raise FeedError(f"release {tag} has an invalid DMG set")
    dmg = matches[0]
    validate_asset(dmg, repository, tag, draft, name)
    if legacy:
        validate_asset(legacy[0], repository, tag, draft, legacy_name)
        if legacy[0]["size"] != dmg["size"] or legacy[0]["digest"] != dmg["digest"]:
            raise FeedError(f"release {tag} legacy DMG differs from the standard DMG")
    entry = {
        "commit": commit,
        "publishedAt": published_time(dmg.get("created_at"), tag),
        "downloadURL": f"https://github.com/{repository}/releases/download/{tag}/{name}",
        "sha256": dmg["digest"][7:],
        "size": dmg["size"],
    }
    if channel == "stable":
        entry["version"] = tag[1:]
    validate_feed({channel: entry}, repository)
    return entry


def checked_candidate(github, repository, channel, expected, commit):
    release_id = expected.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise FeedError("verified release has an invalid id")
    expected_entry = feed_entry(github, repository, channel, expected)
    current = github.api(f"releases/{release_id}")
    current_entry = feed_entry(github, repository, channel, current)
    if (current.get("id") != release_id or current.get("tag_name") != expected.get("tag_name")
            or current.get("draft") is not expected.get("draft") or current_entry != expected_entry):
        raise FeedError("the verified release changed before the feed update")
    if current_entry["commit"] != commit:
        raise FeedError("verified release tag does not target RELEASE_COMMIT")
    return current_entry, current


def manifest_asset(release):
    assets = [asset for asset in release["assets"] if asset.get("name") == "update.json"]
    if len(assets) > 1:
        raise FeedError("release contains duplicate update.json assets")
    return assets[0] if assets else None


def verify_manifest(release, repository, content):
    asset = manifest_asset(release)
    if asset is None:
        raise FeedError("release is missing update.json")
    tag = release["tag_name"]
    validate_asset(asset, repository, tag, release["draft"], "update.json")
    if asset["size"] != len(content) or asset["digest"] != "sha256:" + hashlib.sha256(content).hexdigest():
        raise FeedError("release update.json size or SHA-256 does not match generated content")


def publish(github, repository, channel, commit, branch, expected, *, verify_only=False):
    if (not valid_repository(repository) or channel not in ("autobuild", "stable")
            or not isinstance(commit, str) or not SHA.fullmatch(commit)
            or (channel == "autobuild" and not branch) or not isinstance(expected, dict)):
        raise FeedError("invalid repository, channel, commit, branch, or verified release")

    def check_branch():
        if channel == "autobuild" and github.default_head(branch) != commit:
            raise FeedError("default branch advanced before the Autobuild feed update")

    check_branch()
    entry, current = checked_candidate(github, repository, channel, expected, commit)
    document = {channel: entry}
    content = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    digest = "sha256:" + hashlib.sha256(content).hexdigest()
    asset = manifest_asset(current)
    same = asset is not None and asset.get("size") == len(content) and asset.get("digest") == digest
    changed = not verify_only and not same
    if changed:
        check_branch()
        checked_candidate(github, repository, channel, expected, commit)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update.json"
            path.write_bytes(content)
            github.upload(current["tag_name"], path)
        check_branch()
        final_entry, current = checked_candidate(github, repository, channel, expected, commit)
        if final_entry != entry:
            raise FeedError("the verified release changed during the feed update")
    verify_manifest(current, repository, content)

    removed = []
    if channel == "autobuild" and not verify_only:
        keep = {entry["downloadURL"].rsplit("/", 1)[-1], "update.json"}
        obsolete = [asset for asset in current["assets"] if asset.get("name") not in keep]

        def verified_current():
            check_branch()
            latest_entry, latest = checked_candidate(github, repository, channel, expected, commit)
            if latest_entry != entry:
                raise FeedError("the verified release changed during asset cleanup")
            verify_manifest(latest, repository, content)
            return latest

        for asset in obsolete:
            latest = verified_current()
            asset_id = asset.get("id")
            if type(asset_id) is not int or asset_id <= 0:
                raise FeedError("obsolete asset has an invalid id")
            # Asset IDs stay unique across uploads; never delete a currently referenced file.
            if any(item.get("id") == asset_id and item.get("name") in keep for item in latest["assets"]):
                raise FeedError("obsolete asset id conflicts with a current asset")
            stale = next((item for item in latest["assets"]
                          if item.get("id") == asset_id and item.get("name") not in keep), None)
            if stale is not None:
                github.delete_asset(asset_id)
                removed.append(stale["name"])
        if obsolete:
            final = verified_current()
            if {asset.get("name") for asset in final["assets"]} != keep:
                raise FeedError("Autobuild still contains obsolete assets after cleanup")
    return {"feed": document, "changed": changed, "removed": removed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verified-release", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    channel = os.environ.get("MOTIONPAPER_RELEASE_CHANNEL", "autobuild")
    commit = os.environ.get("RELEASE_COMMIT", "")
    branch = os.environ.get("DEFAULT_BRANCH", "")
    if (not valid_repository(repository) or not os.environ.get("GH_TOKEN") or not SHA.fullmatch(commit)
            or channel not in ("autobuild", "stable") or (channel == "autobuild" and not branch)):
        raise FeedError("invalid repository, token, commit, channel, or default branch")
    expected = json.loads(args.verified_release.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(expected, dict):
        raise FeedError("invalid verified release")
    if channel == "stable" and expected.get("tag_name") != "v" + os.environ.get("MOTIONPAPER_VERSION", ""):
        raise FeedError("verified stable tag does not match MOTIONPAPER_VERSION")
    result = publish(GitHub(repository), repository, channel, commit, branch, expected, verify_only=args.verify_only)
    args.result.write_text(json.dumps(result) + "\n", encoding="utf-8")
    print("Published release update.json." if result["changed"] else "Release update.json is verified and unchanged.")
    if result["removed"]:
        print("Removed obsolete assets: " + ", ".join(result["removed"]))


if __name__ == "__main__":
    try:
        main()
    except (FeedError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

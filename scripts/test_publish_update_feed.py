"""Contract tests for channel-specific release assets, with an in-memory GitHub API."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("publish_update_feed", Path(__file__).with_name("publish-update-feed.py"))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)

REPOSITORY = "owner/repo"
DATE = "2026-01-02T03:04:05Z"
BASE = f"https://github.com/{REPOSITORY}/releases/download"


def release(channel, commit, release_id=1, version="1.0.0", draft=False):
    tag = "Autobuild" if channel == "autobuild" else "v" + version
    name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-{tag}.dmg"
    url_tag = "untagged-draft" if draft else tag
    return {
        "id": release_id, "tag_name": tag, "target_commitish": commit,
        "draft": draft, "prerelease": False, "published_at": None if draft else DATE,
        "assets": [{"id": release_id * 10, "name": name, "state": "uploaded", "size": 7,
                    "digest": "sha256:" + "a" * 64, "created_at": DATE,
                    "browser_download_url": f"{BASE}/{url_tag}/{name}"}],
    }


class FakeGitHub(feed.GitHub):
    def __init__(self):
        super().__init__(REPOSITORY)
        self.default = "a" * 40
        self.tags = {}
        self.tag_objects = {}
        self.catalog = {}
        self.calls = []
        self.upload_hook = None

    def add_release(self, item):
        self.catalog[item["id"]] = copy.deepcopy(item)
        self.tags[item["tag_name"]] = {"type": "commit", "sha": item["target_commitish"]}

    def api(self, route):
        self.calls.append(("GET", route))
        if route.startswith("branches/"):
            return {"commit": {"sha": self.default}}
        if route.startswith("git/ref/tags/"):
            return {"object": copy.deepcopy(self.tags[route.removeprefix("git/ref/tags/")])}
        if route.startswith("git/tags/"):
            return {"object": copy.deepcopy(self.tag_objects[route.removeprefix("git/tags/")])}
        if route.startswith("releases/"):
            return copy.deepcopy(self.catalog[int(route.removeprefix("releases/"))])
        raise AssertionError(route)

    def upload(self, tag, path):
        self.calls.append(("UPLOAD", tag))
        item = next(item for item in self.catalog.values() if item["tag_name"] == tag)
        content = path.read_bytes()
        url_tag = "untagged-draft" if item["draft"] else tag
        asset = {"name": "update.json", "state": "uploaded", "size": len(content),
                 "digest": "sha256:" + hashlib.sha256(content).hexdigest(),
                 "browser_download_url": f"{BASE}/{url_tag}/update.json", "content": content.decode()}
        item["assets"] = [old for old in item["assets"] if old["name"] != "update.json"] + [asset]
        if self.upload_hook:
            self.upload_hook(self, item, asset)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.auto = release("autobuild", "a" * 40)
        self.stable = release("stable", "b" * 40, 2, "1.2.3")
        self.github.add_release(self.auto)
        self.github.add_release(self.stable)

    def publish(self, channel="autobuild", item=None, commit=None, **kwargs):
        item = item or (self.auto if channel == "autobuild" else self.stable)
        return feed.publish(self.github, REPOSITORY, channel, commit or item["target_commitish"], "main", item, **kwargs)

    def manifest(self, release_id=1):
        return next(item for item in self.github.catalog[release_id]["assets"] if item["name"] == "update.json")

    def test_only_current_channel_is_published_and_same_content_is_reused(self):
        result = self.publish()
        self.assertEqual(set(result["feed"]), {"autobuild"})
        self.assertEqual(json.loads(self.manifest()["content"]), result["feed"])
        self.assertNotIn("update.json", [asset["name"] for asset in self.github.catalog[2]["assets"]])
        self.github.calls.clear()
        result = self.publish()
        self.assertFalse(result["changed"])
        self.assertFalse(any(method == "UPLOAD" for method, _ in self.github.calls))
        self.assertFalse(any(route == "releases/2" for _, route in self.github.calls))
        self.assertFalse(any("git/trees" in route or "git/commits" in route or "refs/heads" in route
                             for _, route in self.github.calls))

    def test_moving_tag_uses_actual_full_commit_not_release_target(self):
        new = "c" * 40
        current = release("autobuild", new)
        current["target_commitish"] = self.auto["target_commitish"]
        self.github.catalog[1] = copy.deepcopy(current)
        self.github.tags["Autobuild"] = {"type": "commit", "sha": new}
        self.github.default = new
        entry = self.publish(item=current, commit=new)["feed"]["autobuild"]
        self.assertEqual(entry["commit"], new)
        self.assertEqual(entry["downloadURL"], f"{BASE}/Autobuild/Motionpaper-{new[:12]}.dmg")

    def test_annotated_tag_is_peeled_to_commit(self):
        tag_sha = "c" * 40
        self.github.tags["v1.2.3"] = {"type": "tag", "sha": tag_sha}
        self.github.tag_objects[tag_sha] = {"type": "commit", "sha": "b" * 40}
        self.assertEqual(self.publish("stable")["feed"]["stable"]["commit"], "b" * 40)
        self.assertIn(("GET", f"git/tags/{tag_sha}"), self.github.calls)

    def test_stable_draft_uses_final_tag_bound_url_and_asset_time(self):
        draft = release("stable", "b" * 40, 2, "1.2.3", draft=True)
        draft["assets"][0]["created_at"] = "2026-02-03T04:05:06+00:00"
        self.github.catalog[2] = copy.deepcopy(draft)
        entry = self.publish("stable", draft)["feed"]["stable"]
        self.assertEqual(entry["downloadURL"], f"{BASE}/v1.2.3/Motionpaper-v1.2.3.dmg")
        self.assertEqual(entry["publishedAt"], "2026-02-03T04:05:06Z")
        self.assertEqual(entry["version"], "1.2.3")
        self.assertTrue(self.manifest(2)["browser_download_url"].startswith(f"{BASE}/untagged-"))

    def test_existing_published_stable_can_replace_old_manifest_without_touching_dmg(self):
        old_dmg = copy.deepcopy(self.github.catalog[2]["assets"][0])
        self.github.catalog[2]["assets"].append({"name": "update.json", "size": 1, "digest": "sha256:" + "0" * 64})
        result = self.publish("stable")
        self.assertTrue(result["changed"])
        self.assertEqual(self.github.catalog[2]["assets"][0], old_dmg)
        self.assertEqual(set(json.loads(self.manifest(2)["content"])), {"stable"})

    def test_verify_only_never_uploads_and_rejects_missing_or_wrong_manifest(self):
        with self.assertRaisesRegex(feed.FeedError, "missing update.json"):
            self.publish(verify_only=True)
        self.publish()
        self.github.catalog[1]["assets"][-1]["size"] += 1
        self.github.calls.clear()
        with self.assertRaisesRegex(feed.FeedError, "does not match"):
            self.publish(verify_only=True)
        self.assertFalse(any(method == "UPLOAD" for method, _ in self.github.calls))

    def test_wrong_uploaded_manifest_metadata_is_rejected(self):
        for field, value in (("size", 1), ("digest", "sha256:" + "b" * 64),
                             ("state", "starter"), ("browser_download_url", "https://example.com/update.json")):
            with self.subTest(field=field):
                self.setUp()
                self.github.upload_hook = lambda _, item, asset: asset.__setitem__(field, value)
                with self.assertRaises(feed.FeedError):
                    self.publish()
                self.assertEqual(len([call for call in self.github.calls if call[0] == "UPLOAD"]), 1)

    def test_same_content_with_invalid_state_or_url_is_not_silently_replaced(self):
        for field, value in (("state", "starter"), ("browser_download_url", "https://example.com/update.json")):
            with self.subTest(field=field):
                self.setUp()
                self.publish()
                self.manifest()[field] = value
                self.github.calls.clear()
                with self.assertRaises(feed.FeedError):
                    self.publish()
                self.assertFalse(any(method == "UPLOAD" for method, _ in self.github.calls))

    def test_invalid_dmg_metadata_and_draft_urls_are_rejected(self):
        for field, value in (("digest", "sha256:" + "A" * 64), ("browser_download_url", "https://example.com/a"),
                             ("state", "starter"), ("size", 0), ("size", True), ("created_at", "invalid")):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.auto)
                bad["assets"][0][field] = value
                with self.assertRaises(feed.FeedError):
                    feed.feed_entry(self.github, REPOSITORY, "autobuild", bad)
        draft = release("stable", "b" * 40, 2, "1.2.3", draft=True)
        draft["assets"][0]["browser_download_url"] = f"{BASE}/untagged-draft/Motionpaper-other.dmg"
        with self.assertRaisesRegex(feed.FeedError, "browser_download_url"):
            feed.feed_entry(self.github, REPOSITORY, "stable", draft)

    def test_strict_channel_repository_version_and_schema_validation(self):
        entry = feed.feed_entry(self.github, REPOSITORY, "stable", self.stable)
        for document in ({}, {"stable": entry, "autobuild": {}}, {"wrong": entry},
                         {"stable": {**entry, "version": "01.2.3"}},
                         {"stable": {**entry, "commit": "A" * 40}},
                         {"stable": {**entry, "sha256": "0" * 63}},
                         {"stable": {**entry, "size": True}},
                         {"stable": {**entry, "downloadURL": "https://example.com/file"}},
                         {"stable": {**entry, "publishedAt": "invalid"}}):
            with self.subTest(document=document):
                with self.assertRaises(feed.FeedError):
                    feed.validate_feed(document, REPOSITORY)
        with self.assertRaises(feed.FeedError):
            feed.validate_feed({"stable": entry}, "../repo")
        with self.assertRaises(feed.FeedError):
            feed.feed_entry(self.github, REPOSITORY, "other", self.stable)

    def test_multiple_autobuild_dmgs_are_allowed_but_stable_and_manifest_are_unique(self):
        auto = copy.deepcopy(self.auto)
        auto["assets"].append(release("autobuild", "c" * 40)["assets"][0])
        feed.feed_entry(self.github, REPOSITORY, "autobuild", auto)
        stable = copy.deepcopy(self.stable)
        stable["assets"].append(auto["assets"][1])
        with self.assertRaisesRegex(feed.FeedError, "DMG set"):
            feed.feed_entry(self.github, REPOSITORY, "stable", stable)
        self.github.catalog[1]["assets"] += [{"name": "update.json"}, {"name": "update.json"}]
        with self.assertRaisesRegex(feed.FeedError, "duplicate"):
            self.publish()

    def test_changed_release_or_advanced_branch_is_rejected(self):
        self.github.catalog[1]["assets"][0]["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(feed.FeedError, "changed"):
            self.publish()
        self.github.catalog[1] = copy.deepcopy(self.auto)
        self.github.default = "f" * 40
        with self.assertRaisesRegex(feed.FeedError, "branch advanced"):
            self.publish()
        self.github.default = "a" * 40
        self.github.upload_hook = lambda github, _, __: setattr(github, "default", "f" * 40)
        with self.assertRaisesRegex(feed.FeedError, "branch advanced"):
            self.publish()


if __name__ == "__main__":
    unittest.main()

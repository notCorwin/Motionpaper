"""Contract tests for the updates branch publisher, with an in-memory GitHub API."""

import base64
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


def release(channel, commit, release_id=1, version="1.0.0"):
    tag = "Autobuild" if channel == "autobuild" else "v" + version
    name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-{tag}.dmg"
    return {
        "id": release_id, "tag_name": tag, "target_commitish": commit,
        "draft": False, "prerelease": False, "published_at": DATE,
        "assets": [{"id": release_id * 10, "name": name, "state": "uploaded", "size": 7,
                    "digest": "sha256:" + "a" * 64, "created_at": DATE,
                    "browser_download_url": f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"}],
    }


class FakeGitHub(feed.GitHub):
    def __init__(self):
        super().__init__(REPOSITORY)
        self.updates = None
        self.default = "a" * 40
        self.tags = {}
        self.catalog = []
        self.trees = {}
        self.blobs = {}
        self.commits = {}
        self.calls = []
        self.serial = 0
        self.conflicts = []
        self.write_error = None

    def sha(self):
        self.serial += 1
        return hashlib.sha1(str(self.serial).encode()).hexdigest()

    def add_release(self, item):
        self.catalog.append(copy.deepcopy(item))
        self.tags[item["tag_name"]] = item["target_commitish"]

    def add_commit(self, document, parent=None):
        tree = self.api("git/trees", method="POST", payload={"tree": [{
            "path": "update.json", "mode": "100644", "type": "blob", "content": json.dumps(document),
        }]})["sha"]
        return self.api("git/commits", method="POST", payload={"tree": tree, "parents": [parent] if parent else []})["sha"]

    def install_feed(self, document):
        self.updates = self.add_commit(document, self.updates)
        return self.updates

    def api(self, route, *, method="GET", payload=None, paginate=False, missing_ok=False):
        self.calls.append((method, route, copy.deepcopy(payload)))
        if method == "GET":
            if route == "git/ref/heads/updates":
                return {"object": {"type": "commit", "sha": self.updates}} if self.updates else None
            if route.startswith("branches/"):
                return {"commit": {"sha": self.default}}
            if route == "releases?per_page=100":
                return [copy.deepcopy(self.catalog)]
            if route.startswith("git/ref/tags/"):
                tag = route.removeprefix("git/ref/tags/")
                return {"object": {"type": "commit", "sha": self.tags[tag]}}
            if route.startswith("releases/"):
                release_id = int(route.removeprefix("releases/"))
                return copy.deepcopy(next(item for item in self.catalog if item["id"] == release_id))
            if route.startswith("git/commits/"):
                return copy.deepcopy(self.commits[route.removeprefix("git/commits/")])
            if route.startswith("git/trees/"):
                return copy.deepcopy(self.trees[route.removeprefix("git/trees/")])
            if route.startswith("git/blobs/"):
                return copy.deepcopy(self.blobs[route.removeprefix("git/blobs/")])
        if route == "git/trees" and method == "POST":
            entry = payload["tree"][0]
            blob_sha, tree_sha = self.sha(), self.sha()
            self.blobs[blob_sha] = {"encoding": "base64", "content": base64.b64encode(entry["content"].encode()).decode()}
            self.trees[tree_sha] = {"truncated": False, "tree": [{**{key: entry[key] for key in ("path", "mode", "type")}, "sha": blob_sha}]}
            return {"sha": tree_sha}
        if route == "git/commits" and method == "POST":
            sha = self.sha()
            self.commits[sha] = {"tree": {"sha": payload["tree"]}, "parents": payload["parents"]}
            return {"sha": sha}
        if (route == "git/refs/heads/updates" and method == "PATCH") or (route == "git/refs" and method == "POST"):
            if self.write_error:
                raise feed.GitHubError("injected API error", self.write_error)
            if self.conflicts:
                conflict = self.conflicts.pop(0)
                conflict(self)
                raise feed.GitHubError("concurrent update", 422)
            if method == "PATCH":
                assert payload["force"] is False
                assert self.commits[payload["sha"]]["parents"] == [self.updates]
            else:
                assert self.updates is None and payload["ref"] == "refs/heads/updates"
            self.updates = payload["sha"]
            return {"object": {"sha": self.updates}}
        raise AssertionError((method, route, payload))


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.auto = release("autobuild", "a" * 40, 1)
        self.stable = release("stable", "b" * 40, 2, "1.2.3")
        self.github.add_release(self.auto)
        self.github.add_release(self.stable)
        self.auto_entry = feed.feed_entry(self.github, REPOSITORY, "autobuild", self.auto)
        self.stable_entry = feed.feed_entry(self.github, REPOSITORY, "stable", self.stable)
        self.github.calls.clear()

    def publish(self, channel="autobuild", item=None):
        item = item or (self.auto if channel == "autobuild" else self.stable)
        return feed.publish(self.github, REPOSITORY, channel, item["target_commitish"], "main", item)

    def test_initial_branch_bootstraps_other_channel_and_ignores_hash_tags(self):
        legacy = release("autobuild", "c" * 40, 3)
        legacy["tag_name"] = "Autobuild-" + "c" * 40
        self.github.catalog.append(legacy)
        result = self.publish()
        self.assertEqual(result["feed"], {"stable": self.stable_entry, "autobuild": self.auto_entry})
        self.assertEqual(self.github.commits[result["head"]]["parents"], [])
        self.assertEqual(self.github.read_feed(result["head"], REPOSITORY), result["feed"])

    def test_repeat_is_noop_and_does_not_recompute_catalog_or_make_a_commit(self):
        first = self.publish()
        self.github.calls.clear()
        second = self.publish()
        self.assertFalse(second["changed"])
        self.assertEqual(second["head"], first["head"])
        self.assertFalse(any(method == "POST" or route == "releases?per_page=100" for method, route, _ in self.github.calls))

    def test_existing_feed_merges_without_reading_other_release_metadata(self):
        self.github.install_feed({"stable": self.stable_entry})
        self.github.tags["v1.2.3"] = "e" * 40  # Other release is temporarily inconsistent.
        result = self.publish()
        self.assertEqual(result["feed"]["stable"], self.stable_entry)
        self.assertEqual(result["feed"]["autobuild"], self.auto_entry)
        self.assertFalse(any(route == "releases?per_page=100" for _, route, _ in self.github.calls))

    def test_conflicting_update_is_reloaded_and_preserves_the_other_channel(self):
        self.github.install_feed({"autobuild": self.auto_entry})
        newer = release("stable", "c" * 40, 3, "2.0.0")
        self.github.add_release(newer)
        newer_entry = feed.feed_entry(self.github, REPOSITORY, "stable", newer)
        self.github.conflicts.append(lambda github: github.install_feed({"autobuild": self.auto_entry, "stable": newer_entry}))
        result = self.publish("stable", self.stable)
        self.assertEqual(result["feed"]["stable"], newer_entry)
        self.assertEqual(result["feed"]["autobuild"], self.auto_entry)
        self.assertFalse(result["changed"])

    def test_conflict_then_changed_autobuild_preserves_new_stable(self):
        old = copy.deepcopy(self.auto_entry)
        old["commit"] = "d" * 40
        old["downloadURL"] = f"https://github.com/{REPOSITORY}/releases/download/Autobuild/Motionpaper-{'d' * 12}.dmg"
        self.github.install_feed({"autobuild": old})
        self.github.conflicts.append(lambda github: github.install_feed({"autobuild": old, "stable": self.stable_entry}))
        result = self.publish()
        self.assertEqual(result["feed"], {"autobuild": self.auto_entry, "stable": self.stable_entry})
        self.assertEqual(self.github.read_feed(self.github.updates, REPOSITORY), result["feed"])

    def test_initial_branch_creation_conflict_merges_the_winner(self):
        self.github.conflicts.append(lambda github: github.install_feed({"stable": self.stable_entry}))
        result = self.publish()
        self.assertEqual(result["feed"], {"stable": self.stable_entry, "autobuild": self.auto_entry})
        self.assertEqual(self.github.read_feed(self.github.updates, REPOSITORY), result["feed"])

    def test_conflict_does_not_retry_stale_default_branch(self):
        self.github.install_feed({"stable": self.stable_entry})
        def advance(github):
            github.install_feed({"stable": self.stable_entry})
            github.default = "f" * 40
        self.github.conflicts.append(advance)
        with self.assertRaisesRegex(feed.FeedError, "default branch advanced"):
            self.publish()
        self.assertEqual(self.github.read_feed(self.github.updates, REPOSITORY), {"stable": self.stable_entry})

    def test_three_conflicts_stop_immediately(self):
        self.github.install_feed({"stable": self.stable_entry})
        self.github.conflicts = [lambda github: github.install_feed({"stable": self.stable_entry}) for _ in range(3)]
        with self.assertRaisesRegex(feed.FeedError, "all three"):
            self.publish()
        attempts = [call for call in self.github.calls if call[0] == "PATCH" and call[1] == "git/refs/heads/updates"]
        self.assertEqual(len(attempts), 3)

    def test_api_failures_are_not_treated_as_conflicts(self):
        self.github.install_feed({"stable": self.stable_entry})
        self.github.write_error = 500
        with self.assertRaisesRegex(feed.GitHubError, "injected API error"):
            self.publish()
        self.assertEqual(len([call for call in self.github.calls if call[0] == "PATCH"]), 1)

    def test_stable_highest_semantic_version_and_immutable_same_version(self):
        high = release("stable", "c" * 40, 3, "1.10.0")
        self.github.add_release(high)
        high_entry = feed.feed_entry(self.github, REPOSITORY, "stable", high)
        self.github.install_feed({"stable": high_entry})
        result = self.publish("stable", self.stable)
        self.assertEqual(result["feed"]["stable"]["version"], "1.10.0")
        self.assertFalse(result["changed"])
        changed = copy.deepcopy(high)
        changed["target_commitish"] = "d" * 40
        self.github.catalog[-1] = changed
        self.github.tags["v1.10.0"] = "d" * 40
        with self.assertRaisesRegex(feed.FeedError, "conflicts"):
            self.publish("stable", changed)

    def test_bootstrap_selects_highest_stable_not_newest_date(self):
        high = release("stable", "c" * 40, 3, "1.10.0")
        high["published_at"] = "2020-01-01T00:00:00Z"
        self.github.add_release(high)
        self.assertEqual(self.publish()["feed"]["stable"]["version"], "1.10.0")

    def test_stable_backfill_bootstraps_with_the_highest_existing_stable(self):
        high = release("stable", "c" * 40, 3, "1.10.0")
        self.github.add_release(high)
        result = self.publish("stable", self.stable)
        self.assertEqual(result["feed"]["stable"]["version"], "1.10.0")
        self.assertEqual(result["feed"]["autobuild"], self.auto_entry)

    def test_autobuild_timestamp_is_the_unique_asset_upload_time(self):
        item = copy.deepcopy(self.auto)
        item["assets"][0]["created_at"] = "2026-02-03T04:05:06Z"
        self.assertEqual(feed.feed_entry(self.github, REPOSITORY, "autobuild", item)["publishedAt"], "2026-02-03T04:05:06Z")

    def test_invalid_existing_feed_hash_url_schema_or_time_is_rejected(self):
        for field, value in (("commit", "A" * 40), ("sha256", "0" * 63),
                             ("downloadURL", self.auto_entry["downloadURL"].replace("/Autobuild/", "/Autobuild-abc/")),
                             ("size", True), ("publishedAt", "invalid")):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.auto_entry)
                bad[field] = value
                self.github.install_feed({"autobuild": bad})
                with self.assertRaises(feed.FeedError):
                    self.publish("stable")
        self.github.install_feed({"autobuild": self.auto_entry, "unexpected": {}})
        with self.assertRaises(feed.FeedError):
            self.publish("stable")

    def test_invalid_candidate_digest_url_state_or_tag_is_rejected(self):
        for field, value in (("digest", "sha256:" + "A" * 64), ("browser_download_url", "https://example.com/a"),
                             ("state", "starter"), ("size", 0)):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.auto)
                bad["assets"][0][field] = value
                with self.assertRaises(feed.FeedError):
                    feed.feed_entry(self.github, REPOSITORY, "autobuild", bad)
        self.github.tags["Autobuild"] = "e" * 40
        with self.assertRaises(feed.FeedError):
            self.publish()

    def test_tag_change_to_a_retained_asset_cannot_publish_a_stale_candidate(self):
        other = "c" * 40
        self.auto["assets"].append(release("autobuild", other)["assets"][0])
        self.github.catalog[0] = copy.deepcopy(self.auto)
        self.github.install_feed({"stable": self.stable_entry})
        head = self.github.updates
        original_api = self.github.api

        def move_tag_after_commit(route, **kwargs):
            result = original_api(route, **kwargs)
            if route == "git/commits" and kwargs.get("method") == "POST":
                self.github.tags["Autobuild"] = other
            return result

        self.github.api = move_tag_after_commit
        with self.assertRaisesRegex(feed.FeedError, "Autobuild changed"):
            self.publish()
        self.assertEqual(self.github.updates, head)

    def test_moving_tag_uses_actual_commit_while_release_target_stays_old(self):
        new = "c" * 40
        current = release("autobuild", new)
        current["target_commitish"] = self.auto["target_commitish"]
        self.github.catalog[0] = current
        self.github.tags["Autobuild"] = new
        self.github.default = new
        result = feed.publish(self.github, REPOSITORY, "autobuild", new, "main", current)
        self.assertEqual(result["feed"]["autobuild"]["commit"], new)
        self.assertEqual(result["feed"]["autobuild"]["downloadURL"],
                         f"https://github.com/{REPOSITORY}/releases/download/Autobuild/Motionpaper-{new[:12]}.dmg")

    def test_multiple_autobuild_dmgs_are_allowed_but_stable_is_strict(self):
        old_asset = release("autobuild", "c" * 40)["assets"][0]
        auto = copy.deepcopy(self.auto)
        auto["assets"].append(old_asset)
        self.assertEqual(feed.feed_entry(self.github, REPOSITORY, "autobuild", auto), self.auto_entry)
        stable = copy.deepcopy(self.stable)
        stable["assets"].append(old_asset)
        with self.assertRaisesRegex(feed.FeedError, "DMG set"):
            feed.feed_entry(self.github, REPOSITORY, "stable", stable)

    def test_changed_verified_release_is_rejected(self):
        self.github.catalog[0]["assets"][0]["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(feed.FeedError, "changed"):
            self.publish()

    def test_updates_tree_with_extra_files_is_rejected(self):
        head = self.github.install_feed({"autobuild": self.auto_entry})
        tree = self.github.trees[self.github.commits[head]["tree"]["sha"]]
        tree["tree"].append({"path": "extra"})
        with self.assertRaisesRegex(feed.FeedError, "only update.json"):
            self.publish()


if __name__ == "__main__":
    unittest.main()

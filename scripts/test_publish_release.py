"""Mocked contract tests for stable and Autobuild release publishing."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PUBLISHER = Path(__file__).with_name("publish-release.sh")
REPOSITORY = "notCorwin/Motionpaper"
RELEASE_BASE = f"https://github.com/{REPOSITORY}/releases/download"


MOCK_GH = r'''#!/usr/bin/env python3
import base64
import datetime
import json
import os
import re
import sys
from pathlib import Path

state_path = Path(os.environ["MOCK_GH_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
state.setdefault("calls", []).append(args)

def save():
    state_path.write_text(json.dumps(state, sort_keys=True))

def fail(message):
    save()
    print("mock gh: " + message, file=sys.stderr)
    raise SystemExit(2)

def emit(value):
    if isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value))

def api_arguments(values):
    method = "GET"
    jq = None
    path = None
    forms = {}
    index = 0
    while index < len(values):
        value = values[index]
        if value == "--method":
            index += 1
            method = values[index]
        elif value == "--jq":
            index += 1
            jq = values[index]
        elif value in ("-f", "-F"):
            index += 1
            key, form_value = values[index].split("=", 1)
            forms[key] = form_value
        elif value == "--input":
            index += 1
            body = json.loads(Path(values[index]).read_text())
            for key, form_value in body.items():
                forms[key] = str(form_value).lower() if isinstance(form_value, bool) else form_value
        elif value == "--paginate":
            pass
        elif value.startswith("-"):
            fail("unexpected API option " + value)
        elif path is None:
            path = value
        else:
            fail("unexpected API argument " + value)
        index += 1
    return method, path, jq, forms

def find_release(tag=None, release_id=None):
    for release in state["releases"]:
        if tag is not None and release["tag_name"] == tag:
            return release
        if release_id is not None and str(release["id"]) == str(release_id):
            return release
    return None

def api():
    method, path, jq, forms = api_arguments(args[1:])
    prefix = "repos/" + state["repository"] + "/"
    if not path or not path.startswith(prefix):
        fail("unexpected API path " + str(path))
    route = path[len(prefix):]

    if method == "GET" and route.startswith("branches/"):
        branch = route[len("branches/"):]
        value = state["branches"].get(branch)
        if value is None:
            fail("missing branch " + branch)
        emit(value if jq == ".commit.sha" else {"commit": {"sha": value}})
    elif method == "GET" and route == "releases/latest":
        tag = state.get("latest")
        if not tag:
            fail("no latest release")
        emit(tag if jq == ".tag_name" else {"tag_name": tag})
    elif method == "GET" and route.startswith("git/ref/tags/"):
        tag = route[len("git/ref/tags/"):]
        ref = state["tags"].get(tag)
        if ref is None:
            fail("missing tag " + tag)
        emit({"object": ref})
    elif method == "GET" and route.startswith("git/tags/"):
        tag_object = route[len("git/tags/"):]
        obj = state.get("tag_objects", {}).get(tag_object)
        if obj is None:
            fail("missing annotated tag object " + tag_object)
        emit({"object": obj})
    elif method == "POST" and route == "git/refs":
        ref = forms["ref"]
        if not ref.startswith("refs/tags/"):
            fail("expected a tag reference")
        tag = ref[len("refs/tags/"):]
        if tag in state["tags"]:
            fail("tag already exists")
        state["tags"][tag] = {"type": "commit", "sha": forms["sha"]}
        save()
        emit({"object": state["tags"][tag]})
    elif method == "GET" and route == "releases?per_page=100":
        releases = state["releases"]
        if jq and "@tsv" in jq:
            for release in releases:
                print("\t".join([
                    str(release["id"]), release["tag_name"],
                    release.get("target_commitish", ""), str(release.get("draft", False)).lower(),
                ]))
        elif jq and "select(.tag_name ==" in jq:
            match = re.search(r'select\(\.tag_name == "([^"]+)"\)', jq)
            wanted = match.group(1) if match else ""
            for release in releases:
                if release["tag_name"] == wanted:
                    emit(release)
        elif state.get("paginate_releases") and jq is None:
            midpoint = max(1, len(releases) // 2)
            emit(releases[:midpoint])
            emit(releases[midpoint:])
        else:
            emit(releases)
    elif method == "POST" and route == "releases":
        tag = forms["tag_name"]
        commit = forms["target_commitish"]
        state["last_release_request"] = forms
        release_id = max([int(r["id"]) for r in state["releases"]] + [0]) + 1
        release = {
            "id": release_id,
            "tag_name": tag,
            "target_commitish": commit,
            "name": forms.get("name", ""),
            "body": forms.get("body", ""),
            "draft": forms.get("draft") == "true",
            "published_at": None,
            "assets": [],
        }
        state["releases"].append(release)
        if forms.get("make_latest") == "true":
            state["latest"] = tag
        save()
        emit(release)
    elif method == "GET" and route.startswith("releases/tags/"):
        tag = route[len("releases/tags/"):]
        release = find_release(tag=tag)
        if release is None:
            fail("missing release tag " + tag)
        emit(release)
    elif route.startswith("releases/") and "/assets/" not in route:
        release_id = route[len("releases/"):]
        release = find_release(release_id=release_id)
        if release is None:
            fail("missing release " + release_id)
        if method == "GET":
            emit(release)
        elif method == "PATCH":
            if "draft" in forms:
                release["draft"] = forms["draft"] == "true"
                if not release["draft"] and not release.get("published_at"):
                    release["published_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                if not release["draft"]:
                    for item in release["assets"]:
                        item["browser_download_url"] = f"https://github.com/{state['repository']}/releases/download/{release['tag_name']}/{item['name']}"
            if forms.get("make_latest") == "true":
                state["latest"] = release["tag_name"]
            hook = state.get("stable_publish_hook")
            if "draft" in forms and hook and release["tag_name"] == hook["stable_publish_tag"]:
                stable_before_hook = next(
                    (a for a in release["assets"] if a["name"] == "update.json"), None,
                )
                if stable_before_hook is not None:
                    state["stable_publish_hook_result"] = {
                        "stable_update_before_hook": stable_before_hook["content"],
                    }
                state["releases"] = [
                    item for item in state["releases"]
                    if item["tag_name"] != hook["remove_autobuild_tag"]
                ]
                state["tags"].pop(hook["remove_autobuild_tag"], None)
                autobuild = hook["autobuild_release"]
                state["releases"].append(autobuild)
                state["tags"][autobuild["tag_name"]] = {
                    "type": "commit", "sha": autobuild["target_commitish"],
                }
                stable_target = next(
                    item for item in state["releases"]
                    if item["tag_name"] == hook["sync_stable_tag"]
                )
                auto_update = next(a for a in autobuild["assets"] if a["name"] == "update.json")
                stable_update = dict(auto_update)
                stable_update["id"] = max(
                    [int(a["id"]) for item in state["releases"] for a in item["assets"]] + [0]
                ) + 1
                stable_update["browser_download_url"] = (
                    f"https://github.com/{state['repository']}/releases/download/"
                    f"{hook['sync_stable_tag']}/update.json"
                )
                stable_target["assets"] = [
                    a for a in stable_target["assets"] if a["name"] != "update.json"
                ] + [stable_update]
            save()
            emit(release)
        elif method == "DELETE":
            state["releases"] = [r for r in state["releases"] if str(r["id"]) != release_id]
            save()
        else:
            fail("unsupported release method " + method)
    elif method == "DELETE" and route.startswith("releases/assets/"):
        asset_id = route[len("releases/assets/"):]
        for release in state["releases"]:
            release["assets"] = [a for a in release["assets"] if str(a["id"]) != asset_id]
        save()
    elif method == "DELETE" and route.startswith("git/refs/tags/"):
        tag = route[len("git/refs/tags/"):]
        state["tags"].pop(tag, None)
        save()
    else:
        fail("unsupported API request " + method + " " + route)

    save()

if not args:
    fail("missing command")
if args[0] == "api":
    api()
elif args[0] == "release" and len(args) > 1 and args[1] == "upload":
    tag = args[2]
    release = find_release(tag=tag)
    if release is None:
        fail("upload to missing release " + tag)
    paths = []
    index = 3
    while index < len(args):
        value = args[index]
        if value in ("--repo", "--pattern", "--dir"):
            index += 2
        elif value == "--clobber":
            index += 1
        else:
            paths.append(Path(value))
            index += 1
    for path in paths:
        content = path.read_bytes()
        download_tag = "untagged-draft-fixture" if release["draft"] else tag
        release["assets"] = [a for a in release["assets"] if a["name"] != path.name]
        release["assets"].append({
            "id": max([int(a["id"]) for r in state["releases"] for a in r["assets"]] + [0]) + 1,
            "name": path.name,
            "size": len(content),
            "digest": "sha256:" + __import__("hashlib").sha256(content).hexdigest(),
            "state": "uploaded",
            "browser_download_url": f"https://github.com/{state['repository']}/releases/download/{download_tag}/{path.name}",
            "content": base64.b64encode(content).decode("ascii"),
        })
    save()
elif args[0] == "release" and len(args) > 1 and args[1] == "download":
    tag = args[2]
    options = args[3:]
    pattern = options[options.index("--pattern") + 1]
    destination = Path(options[options.index("--dir") + 1])
    release = find_release(tag=tag)
    if release is None:
        fail("download from missing release " + tag)
    asset = next((a for a in release["assets"] if a["name"] == pattern), None)
    if asset is None:
        fail("missing download asset " + pattern)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / pattern).write_bytes(base64.b64decode(asset["content"]))
    save()
else:
    fail("unsupported command " + " ".join(args))
'''


def asset(tag, name, content):
    digest = hashlib.sha256(content).hexdigest()
    return {
        "id": 1,
        "name": name,
        "size": len(content),
        "digest": f"sha256:{digest}",
        "state": "uploaded",
        "browser_download_url": f"{RELEASE_BASE}/{tag}/{name}",
        "content": base64.b64encode(content).decode("ascii"),
    }


def released(tag, commit, release_id, date, channel, version=None):
    if channel == "stable":
        dmg_name = f"Motionpaper-{version}-{commit[:12]}.dmg"
    else:
        dmg_name = f"Motionpaper-{commit[:12]}.dmg"
    dmg_content = f"fixture DMG for {tag}".encode()
    release_assets = [asset(tag, dmg_name, dmg_content)]
    if channel == "autobuild":
        manifest = {
            "commit": commit,
            "publishedAt": date,
            "downloadURL": f"{RELEASE_BASE}/{tag}/{dmg_name}",
            "sha256": hashlib.sha256(dmg_content).hexdigest(),
            "size": len(dmg_content),
        }
        release_assets.append(asset(tag, "update.json", json.dumps(manifest, sort_keys=True).encode()))
    for index, release_asset in enumerate(release_assets, start=1):
        release_asset["id"] = release_id * 10 + index
    return {
        "id": release_id,
        "tag_name": tag,
        "target_commitish": commit,
        "draft": False,
        "prerelease": False,
        "published_at": date,
        "assets": release_assets,
    }


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "gh"
        mock.write_text(MOCK_GH, encoding="utf-8")
        mock.chmod(0o755)
        self.state_path = self.root / "state.json"

    def run_publish(self, state, commit, channel, version, dmg_content=b"package DMG fixture"):
        if channel == "stable":
            dmg_name = f"Motionpaper-{version}-{commit[:12]}.dmg"
        else:
            dmg_name = f"Motionpaper-{commit[:12]}.dmg"
        (self.dist / dmg_name).write_bytes(dmg_content)
        state["repository"] = REPOSITORY
        state.setdefault("calls", [])
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            "MOCK_GH_STATE": str(self.state_path),
            "GH_TOKEN": "mock-token",
            "GITHUB_REPOSITORY": REPOSITORY,
            "RELEASE_COMMIT": commit,
            "DEFAULT_BRANCH": "master",
            "MOTIONPAPER_RELEASE_CHANNEL": channel,
            "MOTIONPAPER_VERSION": version,
        })
        result = subprocess.run(
            ["bash", str(PUBLISHER)], cwd=self.root, env=environment,
            text=True, capture_output=True, check=False,
        )
        return result, json.loads(self.state_path.read_text(encoding="utf-8"))

    def test_first_stable_release_becomes_latest_and_binds_tag_and_commit(self):
        commit = "a" * 40
        default_head = "b" * 40
        stable_tag = "v1.2.3"
        previous_latest = "Autobuild-" + "f" * 40
        state = {
            "branches": {"master": default_head},
            "tags": {stable_tag: {"type": "commit", "sha": commit}},
            "releases": [],
            "latest": previous_latest,
        }
        release_notes = "Motionpaper 1.2.3 release notes.\n\n- Stable channel update.\n- Universal macOS app.\n"
        notes_path = self.root / "Support" / "ReleaseNotes"
        notes_path.mkdir(parents=True)
        (notes_path / "1.2.3.md").write_text(release_notes, encoding="utf-8")

        result, published = self.run_publish(state, commit, "stable", "1.2.3")

        self.assertEqual(result.returncode, 0, result.stderr)
        release = next(r for r in published["releases"] if r["tag_name"] == stable_tag)
        self.assertEqual(release["target_commitish"], commit)
        self.assertEqual(published["latest"], stable_tag)
        self.assertEqual(published["last_release_request"]["body"], release_notes)
        self.assertEqual(published["last_release_request"]["make_latest"], "false")
        self.assertEqual([a["name"] for a in release["assets"]], [f"Motionpaper-1.2.3-{commit[:12]}.dmg"])
        self.assertTrue(all(call[0] != "release" or call[1] != "download" for call in published["calls"]))
        self.assertFalse(any("branches/" in " ".join(call) for call in published["calls"]))
        post = next(call for call in published["calls"] if "--method" in call and call[call.index("--method") + 1] == "POST")
        self.assertIn("--input", post)
        self.assertEqual(published["last_release_request"]["target_commitish"], commit)
        self.assertEqual(published["last_release_request"]["tag_name"], stable_tag)
        publish_patch = next(
            call for call in published["calls"]
            if "--method" in call and call[call.index("--method") + 1] == "PATCH"
        )
        self.assertIn("make_latest=true", publish_patch)

    def test_stable_release_attaches_latest_autobuild_manifest_without_stealing_latest(self):
        commit = "a" * 40
        stable_commit = "b" * 40
        auto_commit = "c" * 40
        old_stable = released("v2.0.0", stable_commit, 20, "2026-02-01T00:00:00Z", "stable", "2.0.0")
        current_auto = released(
            "Autobuild-" + auto_commit, auto_commit, 30, "2026-03-01T00:00:00Z", "autobuild"
        )
        previous_latest = "v2.0.0"
        state = {
            "branches": {"master": "d" * 40},
            "tags": {
                "v2.0.0": {"type": "commit", "sha": stable_commit},
                current_auto["tag_name"]: {"type": "commit", "sha": auto_commit},
                "v1.2.3": {"type": "commit", "sha": commit},
            },
            "releases": [old_stable, current_auto],
            "latest": previous_latest,
        }

        result, published = self.run_publish(state, commit, "stable", "1.2.3")

        self.assertEqual(result.returncode, 0, result.stderr)
        new_stable = next(r for r in published["releases"] if r["tag_name"] == "v1.2.3")
        update_asset = next(a for a in new_stable["assets"] if a["name"] == "update.json")
        auto_update = next(a for a in current_auto["assets"] if a["name"] == "update.json")
        self.assertEqual(update_asset["content"], auto_update["content"])
        self.assertEqual(published["latest"], previous_latest)
        self.assertEqual([a["name"] for a in new_stable["assets"]], [
            "Motionpaper-1.2.3-" + commit[:12] + ".dmg", "update.json",
        ])
        self.assertFalse(any("make_latest=true" in call for call in published["calls"]))

        calls_before_retry = len(published["calls"])
        retry_result, retried = self.run_publish(published, commit, "stable", "1.2.3")
        self.assertEqual(retry_result.returncode, 0, retry_result.stderr)
        self.assertIn("Reusing complete published stable release", retry_result.stdout)
        self.assertEqual(retried["latest"], previous_latest)
        self.assertEqual(
            next(r for r in retried["releases"] if r["tag_name"] == "v1.2.3")["assets"],
            new_stable["assets"],
        )
        self.assertFalse(any(
            call[:2] == ["release", "upload"] for call in retried["calls"][calls_before_retry:]
        ))

    def test_stable_publish_refreshes_manifest_when_latest_autobuild_changes_during_draft(self):
        stable_commit = "a" * 40
        old_stable_commit = "b" * 40
        autobuild_m1_commit = "c" * 40
        autobuild_m2_commit = "d" * 40
        stable_tag = "v1.2.3"
        old_stable_tag = "v1.0.0"
        autobuild_m1_tag = "Autobuild-" + autobuild_m1_commit
        autobuild_m2_tag = "Autobuild-" + autobuild_m2_commit
        old_stable = released(
            old_stable_tag, old_stable_commit, 100, "2026-01-01T00:00:00Z", "stable", "1.0.0"
        )
        autobuild_m1 = released(
            autobuild_m1_tag, autobuild_m1_commit, 200, "2026-02-01T00:00:00Z", "autobuild"
        )
        autobuild_m2 = released(
            autobuild_m2_tag, autobuild_m2_commit, 300, "2026-04-01T00:00:00Z", "autobuild"
        )
        state = {
            "branches": {"master": "e" * 40},
            "tags": {
                old_stable_tag: {"type": "commit", "sha": old_stable_commit},
                stable_tag: {"type": "commit", "sha": stable_commit},
                autobuild_m1_tag: {"type": "commit", "sha": autobuild_m1_commit},
            },
            "releases": [old_stable, autobuild_m1],
            "latest": old_stable_tag,
            "stable_publish_hook": {
                "stable_publish_tag": stable_tag,
                "remove_autobuild_tag": autobuild_m1_tag,
                "autobuild_release": autobuild_m2,
                "sync_stable_tag": old_stable_tag,
            },
        }
        m1_content = next(a for a in autobuild_m1["assets"] if a["name"] == "update.json")["content"]
        m2_content = next(a for a in autobuild_m2["assets"] if a["name"] == "update.json")["content"]

        result, after = self.run_publish(state, stable_commit, "stable", "1.2.3")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(after["stable_publish_hook_result"]["stable_update_before_hook"], m1_content)
        self.assertNotIn(autobuild_m1_tag, {r["tag_name"] for r in after["releases"]})
        self.assertIn(autobuild_m2_tag, {r["tag_name"] for r in after["releases"]})
        latest_stable = next(r for r in after["releases"] if r["tag_name"] == stable_tag)
        latest_update = next(a for a in latest_stable["assets"] if a["name"] == "update.json")
        self.assertEqual(latest_update["content"], m2_content)
        self.assertEqual(after["latest"], stable_tag)

    def test_stable_latest_uses_numeric_version_order_and_backfill_does_not_take_it(self):
        commit = "1" * 40
        stable_19 = released("v1.9.0", "9" * 40, 19, "2026-02-01T00:00:00Z", "stable", "1.9.0")
        preview_99 = released("v99.0.0", "8" * 40, 18, "2026-02-02T00:00:00Z", "stable", "99.0.0")
        preview_99["prerelease"] = True
        state = {
            "branches": {"master": "2" * 40},
            "tags": {
                "v1.9.0": {"type": "commit", "sha": "9" * 40},
                "v99.0.0": {"type": "commit", "sha": "8" * 40},
                "v1.10.0": {"type": "commit", "sha": commit},
            },
            "releases": [stable_19, preview_99],
            "latest": "v1.9.0",
        }

        result, after = self.run_publish(state, commit, "stable", "1.10.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(after["latest"], "v1.10.0")
        stable_110 = next(r for r in after["releases"] if r["tag_name"] == "v1.10.0")
        self.assertEqual(stable_110["assets"][0]["name"], f"Motionpaper-1.10.0-{commit[:12]}.dmg")

        backfill_commit = "3" * 40
        after["branches"]["master"] = "4" * 40
        after["tags"]["v1.8.0"] = {"type": "commit", "sha": backfill_commit}
        backfill_result, backfilled = self.run_publish(after, backfill_commit, "stable", "1.8.0")

        self.assertEqual(backfill_result.returncode, 0, backfill_result.stderr)
        self.assertEqual(backfilled["latest"], "v1.10.0")
        backfill_patch = next(
            call for call in backfilled["calls"]
            if "make_latest=false" in call and "releases/" in " ".join(call)
        )
        self.assertIn("make_latest=false", backfill_patch)

    def test_stable_tag_must_resolve_to_the_requested_full_commit(self):
        commit = "a" * 40
        wrong_commit = "b" * 40
        state = {
            "branches": {"master": "c" * 40},
            "tags": {"v1.2.3": {"type": "commit", "sha": wrong_commit}},
            "releases": [],
            "latest": "Autobuild-" + "f" * 40,
        }

        result, after = self.run_publish(state, commit, "stable", "1.2.3")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("instead of", result.stderr)
        self.assertEqual(after["releases"], [])
        self.assertFalse(any("--method" in call and call[call.index("--method") + 1] in ("POST", "PATCH") for call in after["calls"]))

    def test_autobuild_without_a_stable_release_never_marks_itself_latest(self):
        commit = "5" * 40
        state = {
            "branches": {"master": commit},
            "tags": {},
            "releases": [],
        }

        result, after = self.run_publish(state, commit, "autobuild", "1.0.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("make_latest=true" in call for call in after["calls"]))
        self.assertNotIn("latest", after)

    def test_autobuild_sync_reuses_identical_stable_compatibility_asset(self):
        commit = "e" * 40
        stable_commit = "f" * 40
        stable = released("v1.0.0", stable_commit, 101, "2026-01-01T00:00:00Z", "stable", "1.0.0")
        autobuild = released(
            "Autobuild-" + commit, commit, 102, "2026-02-01T00:00:00Z", "autobuild"
        )
        preview_commit = "9" * 40
        preview = released(
            "Autobuild-" + preview_commit, preview_commit, 103, "2027-02-01T00:00:00Z", "autobuild"
        )
        preview["prerelease"] = True
        auto_update = next(a for a in autobuild["assets"] if a["name"] == "update.json")
        stable_update = asset("v1.0.0", "update.json", base64.b64decode(auto_update["content"]))
        stable_update["id"] = stable["id"] * 10 + 2
        stable["assets"].append(stable_update)
        stable_update_id = stable_update["id"]
        state = {
            "branches": {"master": commit},
            "tags": {
                "v1.0.0": {"type": "commit", "sha": stable_commit},
                autobuild["tag_name"]: {"type": "commit", "sha": commit},
                preview["tag_name"]: {"type": "commit", "sha": preview_commit},
            },
            "releases": [stable, autobuild, preview],
            "latest": "v1.0.0",
        }

        result, after = self.run_publish(state, commit, "autobuild", "1.0.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        latest_stable = next(r for r in after["releases"] if r["tag_name"] == "v1.0.0")
        self.assertEqual(
            next(a for a in latest_stable["assets"] if a["name"] == "update.json")["id"],
            stable_update_id,
        )
        self.assertNotIn(preview["tag_name"], {r["tag_name"] for r in after["releases"]})
        self.assertFalse(any(call[:2] == ["release", "upload"] for call in after["calls"]))
        self.assertFalse(any(
            "--method" in call and call[call.index("--method") + 1] == "DELETE"
            and "/releases/assets/" in " ".join(call)
            for call in after["calls"]
        ))

    def test_stable_release_without_notes_file_uses_short_default_body(self):
        commit = "2" * 40
        state = {
            "branches": {"master": "3" * 40},
            "tags": {"v1.0.1": {"type": "commit", "sha": commit}},
            "releases": [],
            "latest": "Autobuild-" + "4" * 40,
        }

        result, published = self.run_publish(state, commit, "stable", "1.0.1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            published["last_release_request"]["body"],
            "Motionpaper stable release 1.0.1.\n",
        )

    def test_published_stable_retry_reuses_release_and_repairs_latest_to_highest_stable(self):
        commit = "9" * 40
        tag = "v1.0.0"
        stable_release = released(tag, commit, 51, "2026-03-01T00:00:00Z", "stable", "1.0.0")
        newer_commit = "8" * 40
        newer_tag = "v1.10.0"
        newer_release = released(newer_tag, newer_commit, 52, "2026-03-02T00:00:00Z", "stable", "1.10.0")
        state = {
            "branches": {"master": "8" * 40},
            "tags": {
                tag: {"type": "commit", "sha": commit},
                newer_tag: {"type": "commit", "sha": newer_commit},
            },
            "releases": [stable_release, newer_release],
            "latest": "Autobuild-" + "7" * 40,
        }

        result, after = self.run_publish(state, commit, "stable", "1.0.0", b"different rebuilt DMG bytes")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Reusing complete published stable release", result.stdout)
        self.assertEqual(after["latest"], newer_tag)
        self.assertEqual(after["releases"], state["releases"])
        self.assertFalse(any(
            ("--method" in call and call[call.index("--method") + 1] in ("POST", "DELETE"))
            or (call[:2] == ["release", "upload"])
            for call in after["calls"]
        ))
        self.assertTrue(any(
            "--method" in call and call[call.index("--method") + 1] == "PATCH"
            and "releases/52" in " ".join(call) and "make_latest=true" in call
            for call in after["calls"]
        ))

    def test_published_asset_must_be_uploaded_and_have_the_expected_browser_url(self):
        commit = "6" * 40
        tag = "v1.0.0"
        for field, invalid_value in (
            ("state", "uploading"),
            ("browser_download_url", f"{RELEASE_BASE}/{tag}/wrong.dmg"),
        ):
            with self.subTest(field=field):
                stable_release = released(tag, commit, 61, "2026-03-01T00:00:00Z", "stable", "1.0.0")
                stable_release["assets"][0][field] = invalid_value
                state = {
                    "branches": {"master": "5" * 40},
                    "tags": {tag: {"type": "commit", "sha": commit}},
                    "releases": [stable_release],
                    "latest": "Autobuild-" + "7" * 40,
                }

                result, after = self.run_publish(state, commit, "stable", "1.0.0")

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release asset", result.stderr)
                self.assertEqual(after["latest"], state["latest"])

    def test_autobuild_uses_legacy_manifest_and_cleanup_preserves_stable_releases(self):
        commit = "c" * 40
        stable_commits = ["e" * 40, "f" * 40]
        stable_releases = [
            released("v1.0.0", stable_commits[0], 101, "2025-01-01T00:00:00Z", "stable", "1.0.0"),
            released("v2.0.0", stable_commits[1], 102, "2025-02-01T00:00:00Z", "stable", "2.0.0"),
        ]
        tags = {
            "v1.0.0": {"type": "commit", "sha": stable_commits[0]},
            "v2.0.0": {"type": "commit", "sha": stable_commits[1]},
        }
        autobuilds = []
        for index, day in enumerate((1, 2, 3, 4), start=1):
            old_commit = str(index) * 40
            old_tag = "Autobuild-" + old_commit
            old_date = f"2025-04-0{day}T00:00:00Z"
            autobuilds.append(released(old_tag, old_commit, 300 + index, old_date, "autobuild"))
            tags[old_tag] = {"type": "commit", "sha": old_commit}
        invalid_commit = "5" * 40
        invalid_tag = "Autobuild-" + invalid_commit
        invalid_release = released(invalid_tag, invalid_commit, 305, "2024-01-01T00:00:00Z", "autobuild")
        invalid_release["assets"][0]["state"] = "new"
        invalid_release["draft"] = True
        invalid_release["published_at"] = None
        tags[invalid_tag] = {"type": "commit", "sha": invalid_commit}
        wrong_target_commit = "6" * 40
        wrong_target_tag = "Autobuild-" + wrong_target_commit
        wrong_target_release = released(
            wrong_target_tag, wrong_target_commit, 306, "2025-04-05T00:00:00Z", "autobuild"
        )
        wrong_target_release["target_commitish"] = "7" * 40
        tags[wrong_target_tag] = {"type": "commit", "sha": wrong_target_commit}
        wrong_ref_commit = "8" * 40
        wrong_ref_tag = "Autobuild-" + wrong_ref_commit
        wrong_ref_release = released(
            wrong_ref_tag, wrong_ref_commit, 307, "2025-04-06T00:00:00Z", "autobuild"
        )
        tags[wrong_ref_tag] = {"type": "commit", "sha": "9" * 40}
        other_release = {
            "id": 200,
            "tag_name": "maintenance-notes",
            "target_commitish": "d" * 40,
            "draft": False,
            "published_at": "2024-01-01T00:00:00Z",
            "assets": [],
        }
        state = {
            "branches": {"master": commit},
            "tags": tags,
            "releases": stable_releases + [
                other_release, invalid_release, wrong_target_release, wrong_ref_release,
            ] + autobuilds,
            "paginate_releases": True,
            "latest": autobuilds[-1]["tag_name"],
        }
        local_dmg = b"small local DMG fixture bytes"
        stable_dmg_before = {
            release["tag_name"]: next(a for a in release["assets"] if a["name"].endswith(".dmg"))
            for release in stable_releases
        }

        result, after = self.run_publish(state, commit, "autobuild", "1.0.0", local_dmg)

        self.assertEqual(result.returncode, 0, result.stderr)
        current_tag = "Autobuild-" + commit
        current = next(r for r in after["releases"] if r["tag_name"] == current_tag)
        self.assertEqual(current["target_commitish"], commit)
        self.assertEqual(after["latest"], "v2.0.0")
        manifest_asset = next(a for a in current["assets"] if a["name"] == "update.json")
        manifest = json.loads(base64.b64decode(manifest_asset["content"]))
        self.assertEqual(set(manifest), {"commit", "publishedAt", "downloadURL", "sha256", "size"})
        self.assertEqual(manifest["commit"], commit)
        self.assertEqual(manifest["downloadURL"], f"{RELEASE_BASE}/{current_tag}/Motionpaper-{commit[:12]}.dmg")
        self.assertEqual(manifest["sha256"], hashlib.sha256(local_dmg).hexdigest())
        self.assertEqual(manifest["size"], len(local_dmg))
        self.assertNotEqual(manifest_asset["size"], len(local_dmg))

        surviving = {release["tag_name"] for release in after["releases"]}
        self.assertIn("v1.0.0", surviving)
        self.assertIn("v2.0.0", surviving)
        self.assertIn("maintenance-notes", surviving)
        self.assertEqual(
            {tag for tag in surviving if tag.startswith("Autobuild-")},
            {current_tag, wrong_target_tag, wrong_ref_tag},
        )
        self.assertEqual(
            {tag for tag in after["tags"] if tag.startswith("Autobuild-")},
            {current_tag, wrong_target_tag, wrong_ref_tag},
        )
        self.assertIn("v1.0.0", after["tags"])
        self.assertIn("v2.0.0", after["tags"])

        highest_stable = next(r for r in after["releases"] if r["tag_name"] == "v2.0.0")
        stable_compat = next(a for a in highest_stable["assets"] if a["name"] == "update.json")
        self.assertEqual(stable_compat["content"], manifest_asset["content"])
        for stable_release in after["releases"]:
            if stable_release["tag_name"] in stable_dmg_before:
                stable_dmg_after = next(a for a in stable_release["assets"] if a["name"].endswith(".dmg"))
                self.assertEqual(stable_dmg_after, stable_dmg_before[stable_release["tag_name"]])

        release_deletes = [
            index for index, call in enumerate(after["calls"])
            if "--method" in call and call[call.index("--method") + 1] == "DELETE"
            and any("/releases/" in value and "/assets/" not in value for value in call)
        ]
        stable_compat_upload = next(
            index for index, call in enumerate(after["calls"])
            if call[:3] == ["release", "upload", "v2.0.0"]
        )
        self.assertTrue(release_deletes)
        self.assertLess(stable_compat_upload, min(release_deletes))
        latest_true_calls = [call for call in after["calls"] if "make_latest=true" in call]
        self.assertTrue(latest_true_calls)
        self.assertTrue(all("releases/102" in " ".join(call) for call in latest_true_calls))

        downloads = [call for call in after["calls"] if call[:2] == ["release", "download"]]
        self.assertTrue(downloads)
        self.assertTrue(all(call[call.index("--pattern") + 1] == "update.json" for call in downloads))


if __name__ == "__main__":
    unittest.main()

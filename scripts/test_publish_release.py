"""End-to-end publisher contract tests; all GitHub operations use a local mock."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PUBLISHER = Path(__file__).with_name("publish-release.sh")
REPOSITORY = "owner/repo"
BASE = f"https://github.com/{REPOSITORY}/releases/download"
DATE = "2026-01-02T03:04:05Z"

MOCK_GH = r'''#!/usr/bin/env python3
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.parse import unquote

path = Path(os.environ['MOCK_GH_STATE'])
s = json.loads(path.read_text())
a = sys.argv[1:]
s.setdefault('calls', []).append(a)

def save():
    path.write_text(json.dumps(s))

def fail(message, status=400):
    save()
    print(f'gh: {message} (HTTP {status})', file=sys.stderr)
    raise SystemExit(1)

def out(value):
    print(value if isinstance(value, str) else json.dumps(value))

def find_release(tag=None, release_id=None):
    return next((r for r in s['releases'] if (tag is not None and r['tag_name'] == tag) or
                 (release_id is not None and str(r['id']) == str(release_id))), None)

def api_args(values):
    method, route, jq, payload = 'GET', None, None, {}
    i = 0
    while i < len(values):
        value = values[i]
        if value == '--method':
            i += 1; method = values[i]
        elif value == '--jq':
            i += 1; jq = values[i]
        elif value in ('-f', '-F'):
            i += 1
            key, v = values[i].split('=', 1)
            payload[key] = (v == 'true') if value == '-F' and v in ('true', 'false') else v
        elif value == '--input':
            i += 1
            payload.update(json.loads(Path(values[i]).read_text()))
        elif value == '--paginate':
            pass
        elif value.startswith('-'):
            fail('unexpected option ' + value)
        elif route is None:
            route = value
        else:
            fail('unexpected API argument ' + value)
        i += 1
    prefix = 'repos/' + s['repository'] + '/'
    if not route or not route.startswith(prefix):
        fail('unexpected route ' + str(route))
    return method, route[len(prefix):], jq, payload

def api():
    method, route, jq, p = api_args(a[1:])
    if method == 'GET' and route.startswith('branches/'):
        if s.get('fail_branch'): fail('injected branch API failure', 500)
        sha = s['branches'].get(unquote(route[len('branches/'):]))
        if sha is None: fail('missing branch', 404)
        out(sha if jq == '.commit.sha' else {'commit': {'sha': sha}})
    elif method == 'GET' and route == 'releases?per_page=100':
        out(s['releases'])
    elif method == 'GET' and route == 'releases/latest':
        if not s.get('latest'): fail('no latest release', 404)
        out(s['latest'] if jq == '.tag_name' else {'tag_name': s['latest']})
    elif method == 'GET' and route.startswith('git/ref/tags/'):
        tag = route[len('git/ref/tags/'):]
        if s.get('fail_tag_read'): fail('injected tag API failure', 500)
        obj = s['tags'].get(tag)
        if not obj: fail('missing tag', 404)
        out({'object': obj})
    elif method == 'GET' and route.startswith('git/tags/'):
        obj = s.get('tag_objects', {}).get(route[len('git/tags/'):])
        if not obj: fail('missing tag object', 404)
        out({'object': obj})
    elif method == 'POST' and route == 'git/refs':
        ref = p['ref']
        if not ref.startswith('refs/tags/'): fail('only tag refs may be created')
        tag = ref[len('refs/tags/'):]
        if tag in s['tags']: fail('tag exists', 422)
        s['tags'][tag] = {'type': 'commit', 'sha': p['sha']}
        out({'object': {'type': 'commit', 'sha': p['sha']}})
    elif method == 'PATCH' and route.startswith('git/refs/tags/'):
        tag = route[len('git/refs/tags/'):]
        if tag not in s['tags'] or p.get('force') is not True: fail('bad tag update')
        s['tags'][tag] = {'type': 'commit', 'sha': p['sha']}
        if s.get('branch_after_tag_move'): s['branches']['main'] = s.pop('branch_after_tag_move')
        out({'object': s['tags'][tag]})
    elif method == 'POST' and route == 'releases':
        if find_release(tag=p['tag_name']): fail('release exists', 422)
        release_id = max([r['id'] for r in s['releases']] + [0]) + 1
        release = {'id': release_id, 'tag_name': p['tag_name'], 'target_commitish': p['target_commitish'],
                   'name': p['name'], 'body': p['body'], 'draft': p['draft'], 'prerelease': p['prerelease'],
                   'published_at': None, 'assets': []}
        s['releases'].append(release)
        out(release)
    elif method == 'DELETE' and route.startswith('releases/assets/'):
        asset_id = route[len('releases/assets/'):]
        release = next((r for r in s['releases'] if any(str(item['id']) == asset_id for item in r['assets'])), None)
        if release is None: fail('missing asset', 404)
        s.setdefault('delete_snapshots', []).append(copy.deepcopy(release))
        if s.pop('fail_delete', False): fail('injected asset deletion failure', 500)
        release['assets'] = [item for item in release['assets'] if str(item['id']) != asset_id]
    elif route.startswith('releases/') and '/assets/' not in route:
        release = find_release(release_id=route[len('releases/'):])
        if not release: fail('missing release', 404)
        if method == 'GET':
            out(release)
        elif method == 'PATCH':
            if release['tag_name'] == 'Autobuild' and 'body' in p and s.get('fail_auto_patch'):
                s['fail_auto_patch'] = False
                fail('injected Autobuild metadata failure', 500)
            if release['draft'] and p.get('draft') is False:
                s.setdefault('publish_snapshots', []).append(copy.deepcopy(release))
            # GitHub ignores target_commitish when the tag already exists.
            for key in ('name', 'body', 'draft'):
                if key in p: release[key] = p[key]
            if release['draft'] is False and not release['published_at']:
                release['published_at'] = '2026-01-02T03:04:05Z'
            if release['draft'] is False:
                for asset in release['assets']:
                    asset['browser_download_url'] = f"https://github.com/{s['repository']}/releases/download/{release['tag_name']}/{asset['name']}"
                corrupt = s.get('corrupt_json_after_publish')
                if corrupt and 'draft' in p:
                    target = next((x for x in release['assets'] if x['name'] == 'update.json'), None)
                    if target:
                        target[corrupt] = {'size': 1, 'digest': 'sha256:' + 'f' * 64,
                                           'state': 'starter', 'browser_download_url': 'https://example.com/bad'}[corrupt]
            if p.get('make_latest') == 'true': s['latest'] = release['tag_name']
            out(release)
        else: fail('unsupported release method')
    else:
        fail('unexpected API request ' + method + ' ' + route)
    save()

if a[0] == 'api':
    api()
elif a[:2] == ['release', 'upload']:
    release = find_release(tag=a[2])
    if release is None: fail('missing release', 404)
    item_path = Path(a[3])
    kind = 'json' if item_path.name == 'update.json' else 'dmg'
    existing = [item for item in release['assets'] if item['name'] == item_path.name]
    if existing and '--clobber' not in a: fail('asset exists', 422)
    if kind == 'dmg' and '--clobber' in a: fail('DMG must not be clobbered')
    if kind == 'json' and '--clobber' not in a: fail('manifest upload must use --clobber')
    failure = s.get('upload_fail') or {}
    if failure.get('kind') == kind and failure.get('when') == 'before':
        s.pop('upload_fail')
        fail('injected upload failure', 500)
    if existing:
        release['assets'] = [item for item in release['assets'] if item['name'] != item_path.name]
    if failure.get('kind') == kind and failure.get('when') == 'after_delete':
        s.pop('upload_fail')
        fail('injected upload failure after clobber', 500)
    content = item_path.read_bytes()
    tag = 'untagged-draft' if release['draft'] else release['tag_name']
    asset = {'id': max([item['id'] for r in s['releases'] for item in r['assets']] + [0]) + 1,
             'name': item_path.name, 'state': 'uploaded', 'size': len(content),
             'digest': 'sha256:' + hashlib.sha256(content).hexdigest(), 'created_at': '2026-01-02T03:04:05Z',
             'content': base64.b64encode(content).decode(),
             'browser_download_url': f"https://github.com/{s['repository']}/releases/download/{tag}/{item_path.name}"}
    if kind == 'dmg' and s.get('wrong_dmg_size'): asset['size'] += 1
    corrupt = s.get('wrong_json_metadata') if kind == 'json' else None
    if corrupt:
        asset[corrupt] = {'size': 1, 'digest': 'sha256:' + 'f' * 64,
                          'state': 'starter', 'browser_download_url': 'https://example.com/bad'}[corrupt]
    release['assets'].append(asset)
    if kind == 'dmg' and s.get('branch_after_upload'): s['branches']['main'] = s.pop('branch_after_upload')
    if kind == 'dmg' and s.get('tag_after_upload'): s['tags']['Autobuild']['sha'] = s.pop('tag_after_upload')
    if failure.get('kind') == kind and failure.get('when') == 'after':
        s.pop('upload_fail')
        fail('injected upload failure', 500)
    save()
elif a[:2] == ['release', 'download']:
    release = find_release(tag=a[2])
    name = a[a.index('--pattern') + 1]
    dest = Path(a[a.index('--dir') + 1])
    asset = next((item for item in release['assets'] if item['name'] == name), None)
    if asset is None: fail('missing asset', 404)
    content = base64.b64decode(asset['content'])
    if s.get('tamper_download'): content += b'tampered'
    dest.mkdir(parents=True, exist_ok=True)
    (dest / name).write_bytes(content)
    save()
else:
    fail('unsupported command ' + ' '.join(a))
'''


def asset(tag, name, content=b"fixture DMG"):
    return {
        "id": 1, "name": name, "state": "uploaded", "size": len(content),
        "digest": "sha256:" + hashlib.sha256(content).hexdigest(), "created_at": DATE,
        "content": base64.b64encode(content).decode(), "browser_download_url": f"{BASE}/{tag}/{name}",
    }


def released(channel, commit, release_id=1, version="1.0.0", draft=False):
    tag = "Autobuild" if channel == "autobuild" else "v" + version
    name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-{tag}.dmg"
    item = asset("untagged-draft" if draft else tag, name)
    item["id"] = release_id * 10
    return {"id": release_id, "tag_name": tag, "target_commitish": commit, "name": tag, "body": "body",
            "draft": draft, "prerelease": False, "published_at": None if draft else DATE, "assets": [item]}


def state_for(commit):
    return {"repository": REPOSITORY, "branches": {"main": commit}, "tags": {}, "releases": [],
            "latest": None, "calls": []}


def add_release(state, item):
    state["releases"].append(item)
    state["tags"][item["tag_name"]] = {"type": "commit", "sha": item["target_commitish"]}


def read_feed(state, tag="Autobuild"):
    release = next(item for item in state["releases"] if item["tag_name"] == tag)
    manifest = next((item for item in release["assets"] if item["name"] == "update.json"), None)
    return json.loads(base64.b64decode(manifest["content"])) if manifest else None


def uploads(calls, name=None):
    return [call for call in calls if call[:2] == ["release", "upload"]
            and (name is None or Path(call[3]).name == name)]


def deletions(calls):
    prefix = f"repos/{REPOSITORY}/releases/assets/"
    return [call for call in calls if call[:1] == ["api"] and "DELETE" in call
            and any(part.startswith(prefix) for part in call)]


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "dist").mkdir()
        (self.root / "bin").mkdir()
        gh = self.root / "bin" / "gh"
        gh.write_text(MOCK_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.state_path = self.root / "state.json"

    def publish(self, state, commit, channel="autobuild", version="1.0.0", content=b"new package", branch="main"):
        name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-v{version}.dmg"
        (self.root / "dist" / name).write_bytes(content)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        env = os.environ.copy()
        env.update({"PATH": f"{self.root / 'bin'}:{env['PATH']}", "MOCK_GH_STATE": str(self.state_path),
                    "GH_TOKEN": "mock", "GITHUB_REPOSITORY": REPOSITORY, "RELEASE_COMMIT": commit,
                    "DEFAULT_BRANCH": branch, "MOTIONPAPER_RELEASE_CHANNEL": channel, "MOTIONPAPER_VERSION": version,
                    "PYTHONDONTWRITEBYTECODE": "1"})
        result = subprocess.run(["bash", str(PUBLISHER)], cwd=self.root, env=env, text=True, capture_output=True)
        state = json.loads(self.state_path.read_text())
        # The mock only accepts POST /git/refs for tag refs and rejects all other Git writes.
        for call in state["calls"]:
            self.assertFalse(any(part.startswith(f"repos/{REPOSITORY}/git/trees") or
                                 part.startswith(f"repos/{REPOSITORY}/git/commits") or
                                 part.startswith(f"repos/{REPOSITORY}/git/refs/heads/") or
                                 part.startswith(f"repos/{REPOSITORY}/git/ref/heads/") for part in call), call)
        return result, state

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_autobuild_body_uses_default_branch_and_seven_character_commit_on_reuse(self):
        commit = "d4e5f67" + "a" * 33
        branch = "feature/preview"
        state = state_for(commit)
        state["branches"][branch] = commit
        result, state = self.publish(state, commit, branch=branch)
        self.assert_success(result)
        expected = (
            f"基于 {branch} 分支提交 [`{commit[:7]}`](https://github.com/{REPOSITORY}/commit/{commit}) 自动构建的版本。\n"
            f"此版本可能存在 Bug，建议使用 [Latest](https://github.com/{REPOSITORY}/releases/latest)。\n\n"
            f"Automatically built from commit [`{commit[:7]}`](https://github.com/{REPOSITORY}/commit/{commit}) on the {branch} branch.\n"
            f"This build may contain bugs. We recommend using [Latest](https://github.com/{REPOSITORY}/releases/latest)."
        )
        self.assertEqual(state["releases"][0]["body"].rstrip("\n"), expected)
        offset = len(state["calls"])
        result, state = self.publish(state, commit, branch=branch)
        self.assert_success(result)
        self.assertIn("Reusing complete", result.stdout)
        self.assertEqual(state["releases"][0]["body"].rstrip("\n"), expected)
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertFalse(any("PATCH" in call and f"repos/{REPOSITORY}/releases/1" in call
                             for call in state["calls"][offset:]))

    def test_outdated_autobuild_body_is_updated_without_replacing_assets(self):
        commit = "d4e5f67" + "a" * 33
        result, state = self.publish(state_for(commit), commit)
        self.assert_success(result)
        old_assets = copy.deepcopy(state["releases"][0]["assets"])
        state["releases"][0]["body"] = "old release description"
        offset = len(state["calls"])
        result, state = self.publish(state, commit)
        self.assert_success(result)
        self.assertIn(f"提交 [`{commit[:7]}`](https://github.com/{REPOSITORY}/commit/{commit})", state["releases"][0]["body"])
        self.assertEqual(state["releases"][0]["assets"], old_assets)
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertFalse(any(call[:2] == ["release", "download"] for call in state["calls"][offset:]))
        self.assertTrue(any("PATCH" in call and f"repos/{REPOSITORY}/releases/1" in call
                            for call in state["calls"][offset:]))

    def test_first_and_repeated_autobuild_reuses_dmg_and_manifest(self):
        commit = "a" * 40
        first, state = self.publish(state_for(commit), commit)
        self.assert_success(first)
        self.assertEqual([r["tag_name"] for r in state["releases"]], ["Autobuild"])
        self.assertEqual(list(state["tags"]), ["Autobuild"])
        document = read_feed(state)
        self.assertEqual(set(document), {"autobuild"})
        self.assertEqual(document["autobuild"]["commit"], commit)
        self.assertEqual(document["autobuild"]["downloadURL"], f"{BASE}/Autobuild/Motionpaper-{'a' * 12}.dmg")
        offset = len(state["calls"])
        second, state = self.publish(state, commit, content=b"different rebuild bytes")
        self.assert_success(second)
        self.assertIn("Reusing complete", second.stdout)
        self.assertEqual(read_feed(state), document)
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertFalse(deletions(state["calls"][offset:]))
        self.assertFalse(any(call[:2] == ["release", "download"] for call in state["calls"][offset:]))

    def test_two_commits_publish_in_order_and_remove_old_assets(self):
        first_commit, second_commit = "a" * 40, "b" * 40
        first, state = self.publish(state_for(first_commit), first_commit)
        self.assert_success(first)
        notes = asset("Autobuild", "old-notes.txt", b"old notes")
        notes["id"] = max(item["id"] for item in state["releases"][0]["assets"]) + 1
        state["releases"][0]["assets"].append(notes)
        state["branches"]["main"] = second_commit
        offset = len(state["calls"])
        result, state = self.publish(state, second_commit)
        self.assert_success(result)
        self.assertEqual(list(state["tags"]), ["Autobuild"])
        self.assertEqual(state["tags"]["Autobuild"]["sha"], second_commit)
        self.assertEqual(len(state["releases"]), 1)
        release = state["releases"][0]
        self.assertEqual(release["target_commitish"], first_commit)
        self.assertIn(f"commit [`{second_commit[:7]}`](https://github.com/{REPOSITORY}/commit/{second_commit}) on the main branch", release["body"])
        self.assertEqual({item["name"] for item in release["assets"]},
                         {f"Motionpaper-{second_commit[:12]}.dmg", "update.json"})
        self.assertEqual(len(release["assets"]), 2)
        self.assertEqual(read_feed(state)["autobuild"]["commit"], second_commit)
        calls = state["calls"][offset:]
        dmg_upload = next(i for i, call in enumerate(calls) if call in uploads(calls, f"Motionpaper-{second_commit[:12]}.dmg"))
        tag_move = next(i for i, call in enumerate(calls) if f"repos/{REPOSITORY}/git/refs/tags/Autobuild" in call and "PATCH" in call)
        release_update = next(i for i, call in enumerate(calls) if f"repos/{REPOSITORY}/releases/1" in call and "PATCH" in call)
        json_upload = next(i for i, call in enumerate(calls) if call in uploads(calls, "update.json"))
        first_delete = next(i for i, call in enumerate(calls) if call in deletions(calls))
        self.assertLess(dmg_upload, tag_move)
        self.assertLess(tag_move, release_update)
        self.assertLess(release_update, json_upload)
        self.assertLess(json_upload, first_delete)
        self.assertIn("--clobber", calls[json_upload])
        self.assertEqual(len(deletions(calls)), 2)
        for snapshot in state["delete_snapshots"]:
            manifest = next(item for item in snapshot["assets"] if item["name"] == "update.json")
            content = base64.b64decode(manifest["content"])
            self.assertEqual(json.loads(content)["autobuild"]["commit"], second_commit)
            self.assertEqual(manifest["size"], len(content))
            self.assertEqual(manifest["digest"], "sha256:" + hashlib.sha256(content).hexdigest())
            self.assertEqual(manifest["state"], "uploaded")

        offset = len(state["calls"])
        result, state = self.publish(state, second_commit)
        self.assert_success(result)
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertFalse(deletions(state["calls"][offset:]))

    def test_failed_dmg_upload_keeps_old_feed_tag_and_resumes(self):
        for when in ("before", "after"):
            with self.subTest(when=when):
                old, new = "a" * 40, "b" * 40
                result, state = self.publish(state_for(old), old)
                self.assert_success(result)
                old_feed = read_feed(state)
                state["branches"]["main"] = new
                state["upload_fail"] = {"kind": "dmg", "when": when}
                offset = len(state["calls"])
                result, state = self.publish(state, new)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Published autobuild release", result.stdout)
                self.assertEqual(read_feed(state), old_feed)
                self.assertEqual(state["tags"]["Autobuild"]["sha"], old)
                self.assertIn(f"Motionpaper-{old[:12]}.dmg", [item["name"] for item in state["releases"][0]["assets"]])
                self.assertFalse(deletions(state["calls"][offset:]))
                result, state = self.publish(state, new, content=b"different retry")
                self.assert_success(result)
                self.assertEqual(read_feed(state)["autobuild"]["commit"], new)
                self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                                 {f"Motionpaper-{new[:12]}.dmg", "update.json"})
                if when == "after":
                    self.assertEqual(read_feed(state)["autobuild"]["sha256"], hashlib.sha256(b"new package").hexdigest())

    def test_failed_manifest_upload_after_tag_move_can_resume(self):
        for when in ("before", "after_delete", "after"):
            with self.subTest(when=when):
                old, new = "a" * 40, "b" * 40
                result, state = self.publish(state_for(old), old)
                self.assert_success(result)
                old_feed = read_feed(state)
                state["branches"]["main"] = new
                state["upload_fail"] = {"kind": "json", "when": when}
                offset = len(state["calls"])
                result, state = self.publish(state, new)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["tags"]["Autobuild"]["sha"], new)
                self.assertIn(f"Motionpaper-{old[:12]}.dmg", [item["name"] for item in state["releases"][0]["assets"]])
                self.assertFalse(deletions(state["calls"][offset:]))
                if when == "before": self.assertEqual(read_feed(state), old_feed)
                if when == "after_delete": self.assertIsNone(read_feed(state))
                if when == "after": self.assertEqual(read_feed(state)["autobuild"]["commit"], new)
                offset = len(state["calls"])
                result, state = self.publish(state, new, content=b"different retry")
                self.assert_success(result)
                self.assertEqual(read_feed(state)["autobuild"]["commit"], new)
                self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                                 {f"Motionpaper-{new[:12]}.dmg", "update.json"})
                self.assertFalse(uploads(state["calls"][offset:], f"Motionpaper-{new[:12]}.dmg"))
                if when == "after": self.assertFalse(uploads(state["calls"][offset:], "update.json"))

    def test_failed_asset_delete_keeps_current_feed_and_retries_without_upload(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        state["branches"]["main"] = new
        state["fail_delete"] = True
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected asset deletion failure", result.stderr)
        self.assertEqual(read_feed(state)["autobuild"]["commit"], new)
        self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                         {f"Motionpaper-{old[:12]}.dmg", f"Motionpaper-{new[:12]}.dmg", "update.json"})

        offset = len(state["calls"])
        result, state = self.publish(state, new)
        self.assert_success(result)
        self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                         {f"Motionpaper-{new[:12]}.dmg", "update.json"})
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertEqual(len(deletions(state["calls"][offset:])), 1)

    def test_first_autobuild_draft_resumes_an_interrupted_upload(self):
        commit = "a" * 40
        state = state_for(commit)
        state["upload_fail"] = {"kind": "dmg", "when": "after"}
        result, state = self.publish(state, commit, content=b"verified on retry")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["releases"][0]["draft"])
        self.assertIsNone(read_feed(state))
        result, state = self.publish(state, commit, content=b"a different rebuild")
        self.assert_success(result)
        self.assertFalse(state["releases"][0]["draft"])
        self.assertEqual(read_feed(state)["autobuild"]["sha256"], hashlib.sha256(b"verified on retry").hexdigest())
        self.assertTrue(any(call[:2] == ["release", "download"] for call in state["calls"]))

    def test_invalid_dmg_upload_metadata_never_moves_tag_or_manifest(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        old_feed = read_feed(state)
        state["branches"]["main"] = new
        state["wrong_dmg_size"] = True
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertEqual(read_feed(state), old_feed)
        self.assertEqual(state["tags"]["Autobuild"]["sha"], old)

    def test_advanced_branch_is_skipped_before_and_after_upload(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(new), old)
        self.assert_success(result)
        self.assertEqual(state["releases"], [])
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        old_feed = read_feed(state)
        state["branches"]["main"] = new
        state["branch_after_upload"] = "c" * 40
        result, state = self.publish(state, new)
        self.assert_success(result)
        self.assertEqual(state["tags"]["Autobuild"]["sha"], old)
        self.assertEqual(read_feed(state), old_feed)

    def test_api_failure_is_not_mistaken_for_missing_tag_or_old_branch(self):
        commit = "a" * 40
        for failure in ("fail_tag_read", "fail_branch"):
            with self.subTest(failure=failure):
                state = state_for(commit)
                state[failure] = True
                result, state = self.publish(state, commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["releases"], [])
                self.assertEqual(state["tags"], {})

    def test_stable_draft_has_verified_manifest_before_latest_and_final_urls(self):
        commit = "a" * 40
        state = state_for(commit)
        draft = released("stable", commit, version="1.2.3", draft=True)
        extra = asset("untagged-draft", "notes.txt", b"notes")
        extra["id"] = 11
        draft["assets"].append(extra)
        add_release(state, draft)
        result, state = self.publish(state, commit, "stable", "1.2.3", content=b"different rebuild")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.2.3")
        snapshot = state["publish_snapshots"][0]
        manifest = next(item for item in snapshot["assets"] if item["name"] == "update.json")
        document = json.loads(base64.b64decode(manifest["content"]))
        self.assertEqual(set(document), {"stable"})
        self.assertEqual(document["stable"]["commit"], commit)
        self.assertEqual(document["stable"]["publishedAt"], DATE)
        self.assertEqual(document["stable"]["downloadURL"], f"{BASE}/v1.2.3/Motionpaper-v1.2.3.dmg")
        self.assertEqual(manifest["browser_download_url"], f"{BASE}/untagged-draft/update.json")
        for item in state["releases"][0]["assets"]:
            self.assertEqual(item["browser_download_url"], f"{BASE}/v1.2.3/{item['name']}")
        self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                         {"Motionpaper-v1.2.3.dmg", f"Motionpaper-1.2.3-{commit[:12]}.dmg", "notes.txt", "update.json"})
        self.assertTrue(any(call[:2] == ["release", "download"] for call in state["calls"]))
        self.assertEqual(len(uploads(state["calls"])), 2)
        self.assertFalse(deletions(state["calls"]))

    def test_stable_legacy_asset_matches_standard_and_mismatch_is_rejected(self):
        commit = "a" * 40
        state = state_for(commit)
        state["tags"]["v1.2.3"] = {"type": "commit", "sha": commit}
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assert_success(result)
        release = state["releases"][0]
        standard = next(a for a in release["assets"] if a["name"] == "Motionpaper-v1.2.3.dmg")
        legacy = next(a for a in release["assets"] if a["name"] == f"Motionpaper-1.2.3-{commit[:12]}.dmg")
        self.assertEqual((legacy["size"], legacy["digest"]), (standard["size"], standard["digest"]))
        legacy["digest"] = "sha256:" + "f" * 64
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("legacy DMG differs", result.stderr)

    def test_stable_draft_manifest_failure_does_not_publish_and_can_resume(self):
        commit = "a" * 40
        for when in ("before", "after"):
            with self.subTest(when=when):
                state = state_for(commit)
                state["tags"]["v1.2.3"] = {"type": "commit", "sha": commit}
                state["upload_fail"] = {"kind": "json", "when": when}
                result, state = self.publish(state, commit, "stable", "1.2.3")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(state["releases"][0]["draft"])
                self.assertIsNone(state["latest"])
                offset = len(state["calls"])
                result, state = self.publish(state, commit, "stable", "1.2.3", content=b"different retry")
                self.assert_success(result)
                self.assertEqual(state["latest"], "v1.2.3")
                self.assertFalse(uploads(state["calls"][offset:], "Motionpaper-v1.2.3.dmg"))
                if when == "after": self.assertFalse(uploads(state["calls"][offset:], "update.json"))

    def test_stable_rejects_mismatched_target_commitish_for_legacy_clients(self):
        commit, tag_object = "a" * 40, "c" * 40
        state = state_for(commit)
        draft = released("stable", commit, version="1.2.3", draft=True)
        draft["target_commitish"] = "b" * 40
        add_release(state, draft)
        state["tags"]["v1.2.3"] = {"type": "tag", "sha": tag_object}
        state["tag_objects"] = {tag_object: {"type": "commit", "sha": commit}}
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("target_commitish", result.stderr)
        self.assertTrue(state["releases"][0]["draft"])

    def test_tampered_existing_draft_dmg_is_not_published(self):
        commit = "a" * 40
        state = state_for(commit)
        add_release(state, released("stable", commit, version="1.2.3", draft=True))
        state["tamper_download"] = True
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["releases"][0]["draft"])
        self.assertIsNone(read_feed(state, "v1.2.3"))

    def test_stable_backfill_keeps_highest_latest_and_updates_only_own_release(self):
        old, high = "a" * 40, "b" * 40
        state = state_for(old)
        high_release = released("stable", high, 3, "1.10.0")
        add_release(state, high_release)
        state["latest"] = "v1.10.0"
        state["tags"]["v1.2.3"] = {"type": "commit", "sha": old}
        result, state = self.publish(state, old, "stable", "1.2.3")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.10.0")
        self.assertEqual(read_feed(state, "v1.2.3")["stable"]["version"], "1.2.3")
        self.assertIsNone(read_feed(state, "v1.10.0"))
        self.assertEqual(state["releases"][0], high_release)

    def test_missing_latest_is_repaired_to_highest_stable(self):
        commit = "a" * 40
        state = state_for(commit)
        add_release(state, released("stable", commit, version="1.2.3"))
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.2.3")
        self.assertEqual(read_feed(state, "v1.2.3")["stable"]["version"], "1.2.3")

    def test_autobuild_does_not_modify_other_channel_or_reconcile_latest(self):
        commit = "a" * 40
        state = state_for(commit)
        stable = released("stable", "b" * 40, 2, "1.2.3")
        add_release(state, stable)
        result, state = self.publish(state, commit)
        self.assert_success(result)
        self.assertIsNone(state["latest"])
        self.assertEqual(state["releases"][0], stable)
        self.assertIsNone(read_feed(state, "v1.2.3"))
        self.assertEqual(set(read_feed(state)), {"autobuild"})

    def test_colliding_short_commit_does_not_replace_an_existing_dmg(self):
        old = "a" * 12 + "0" * 28
        new = "a" * 12 + "1" * 28
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        state["branches"]["main"] = new
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("collide", result.stderr)
        self.assertEqual(state["tags"]["Autobuild"]["sha"], old)
        self.assertEqual(read_feed(state)["autobuild"]["commit"], old)

    def test_published_stable_only_replaces_manifest_and_reuses_it_on_retry(self):
        commit = "a" * 40
        state = state_for(commit)
        stable = released("stable", commit, version="1.2.3")
        extra = asset("v1.2.3", "notes.txt", b"release notes")
        extra["id"] = 11
        old_manifest = asset("v1.2.3", "update.json", b'{"obsolete":true}')
        old_manifest["id"] = 12
        stable["assets"] += [extra, old_manifest]
        before = copy.deepcopy(stable)
        add_release(state, stable)
        state["latest"] = "v1.2.3"
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assert_success(result)
        after = state["releases"][0]
        self.assertEqual({key: value for key, value in after.items() if key != "assets"},
                         {key: value for key, value in before.items() if key != "assets"})
        self.assertEqual(after["assets"][:2], before["assets"][:2])
        self.assertEqual(set(read_feed(state, "v1.2.3")), {"stable"})
        self.assertEqual(len(uploads(state["calls"])), 2)
        self.assertEqual(Path(uploads(state["calls"])[-1][3]).name, "update.json")
        offset = len(state["calls"])
        result, state = self.publish(state, commit, "stable", "1.2.3", content=b"another build")
        self.assert_success(result)
        self.assertEqual(state["releases"][0], after)
        self.assertFalse(uploads(state["calls"][offset:]))
        self.assertFalse(any("DELETE" in call for call in state["calls"]))

    def test_wrong_manifest_upload_metadata_is_a_failure(self):
        for field in ("size", "digest", "state", "browser_download_url"):
            with self.subTest(field=field):
                commit = "a" * 40
                state = state_for(commit)
                state["tags"]["v1.2.3"] = {"type": "commit", "sha": commit}
                state["wrong_json_metadata"] = field
                result, state = self.publish(state, commit, "stable", "1.2.3")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("update.json", result.stderr)
                self.assertNotIn("Published stable release", result.stdout)
                self.assertTrue(state["releases"][0]["draft"])
                self.assertIsNone(state["latest"])
                self.assertEqual(len(uploads(state["calls"], "update.json")), 1)

    def test_corrupt_manifest_after_stable_publish_fails_verification_without_reupload(self):
        for field in ("size", "digest", "state", "browser_download_url"):
            with self.subTest(field=field):
                commit = "a" * 40
                state = state_for(commit)
                state["tags"]["v1.2.3"] = {"type": "commit", "sha": commit}
                state["corrupt_json_after_publish"] = field
                result, state = self.publish(state, commit, "stable", "1.2.3")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("update.json", result.stderr)
                self.assertFalse(state["releases"][0]["draft"])
                self.assertEqual(len(uploads(state["calls"], "update.json")), 1)

    def test_published_stable_wrong_tag_extra_dmg_and_invalid_url_are_rejected(self):
        commit = "a" * 40
        for fault in ("tag", "extra", "url", "digest"):
            with self.subTest(fault=fault):
                state = state_for(commit)
                stable = released("stable", commit, version="1.2.3")
                add_release(state, stable)
                state["latest"] = "v1.2.3"
                if fault == "tag": state["tags"]["v1.2.3"]["sha"] = "b" * 40
                if fault == "extra": stable["assets"].append(asset("v1.2.3", "extra.dmg"))
                if fault == "url": stable["assets"][0]["browser_download_url"] = "https://example.com/evil"
                if fault == "digest": stable["assets"][0]["digest"] = "sha256:" + "A" * 64
                result, state = self.publish(state, commit, "stable", "1.2.3")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIsNone(read_feed(state, "v1.2.3"))
                self.assertFalse(uploads(state["calls"]))

    def test_interrupted_transition_after_tag_move_can_resume(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        state["branches"]["main"] = new
        item = asset("Autobuild", f"Motionpaper-{new[:12]}.dmg", b"already uploaded")
        item["id"] = 20
        state["releases"][0]["assets"].append(item)
        state["tags"]["Autobuild"]["sha"] = new
        result, state = self.publish(state, new)
        self.assert_success(result)
        self.assertEqual(state["releases"][0]["target_commitish"], old)
        self.assertEqual(read_feed(state)["autobuild"]["commit"], new)

    def test_newer_commit_recovers_after_tag_moved_but_metadata_not_patched(self):
        for interrupted_by in ("branch_advanced", "patch_failed"):
            with self.subTest(interrupted_by=interrupted_by):
                c0, c1, c2 = "a" * 40, "b" * 40, "c" * 40
                result, state = self.publish(state_for(c0), c0)
                self.assert_success(result)
                old_feed = read_feed(state)
                state["branches"]["main"] = c1
                if interrupted_by == "branch_advanced": state["branch_after_tag_move"] = c2
                else: state["fail_auto_patch"] = True
                result, state = self.publish(state, c1)
                if interrupted_by == "branch_advanced": self.assert_success(result)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    state["branches"]["main"] = c2
                self.assertEqual(state["tags"]["Autobuild"]["sha"], c1)
                self.assertEqual(state["releases"][0]["target_commitish"], c0)
                self.assertEqual(read_feed(state), old_feed)
                result, state = self.publish(state, c2)
                self.assert_success(result)
                self.assertEqual(state["tags"]["Autobuild"]["sha"], c2)
                self.assertEqual(read_feed(state)["autobuild"]["commit"], c2)
                self.assertEqual({item["name"] for item in state["releases"][0]["assets"]},
                                 {f"Motionpaper-{c2[:12]}.dmg", "update.json"})

    def test_tag_changed_during_upload_is_rejected_even_if_it_is_new_commit(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        old_feed = read_feed(state)
        state["branches"]["main"] = new
        state["tag_after_upload"] = new
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag changed during upload", result.stderr)
        self.assertEqual(state["releases"][0]["target_commitish"], old)
        self.assertEqual(read_feed(state), old_feed)


if __name__ == "__main__":
    unittest.main()

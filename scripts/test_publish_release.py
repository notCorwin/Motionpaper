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

def new_sha():
    s['serial'] = s.get('serial', 0) + 1
    return hashlib.sha1(str(s['serial']).encode()).hexdigest()

def new_tree(content):
    blob, tree = new_sha(), new_sha()
    s['blobs'][blob] = {'encoding': 'base64', 'content': base64.b64encode(content.encode()).decode()}
    s['trees'][tree] = {'truncated': False, 'tree': [{'path': 'update.json', 'mode': '100644', 'type': 'blob', 'sha': blob}]}
    return tree

def find_release(tag=None, release_id=None):
    return next((r for r in s['releases'] if (tag is not None and r['tag_name'] == tag) or
                 (release_id is not None and str(r['id']) == str(release_id))), None)

def api_args(values):
    method, route, jq, payload, slurp = 'GET', None, None, {}, False
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
            payload.update(json.loads(sys.stdin.read() if values[i] == '-' else Path(values[i]).read_text()))
        elif value == '--slurp':
            slurp = True
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
    return method, route[len(prefix):], jq, payload, slurp

def api():
    method, route, jq, p, slurp = api_args(a[1:])
    if method == 'GET' and route.startswith('branches/'):
        if s.get('fail_branch'):
            fail('injected branch API failure', 500)
        sha = s['branches'].get(unquote(route[len('branches/'):]))
        if sha is None: fail('missing branch', 404)
        out(sha if jq == '.commit.sha' else {'commit': {'sha': sha}})
    elif method == 'GET' and route == 'releases?per_page=100':
        out([s['releases']] if slurp else s['releases'])
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
    elif method == 'GET' and route == 'git/ref/heads/updates':
        if not s.get('updates'): fail('missing updates branch', 404)
        obj = {'type': 'commit', 'sha': s['updates']}
        out(s['updates'] if jq == '.object.sha' else {'object': obj})
    elif method == 'POST' and route == 'git/refs':
        ref = p['ref']
        if ref.startswith('refs/tags/'):
            tag = ref[len('refs/tags/'):]
            if tag in s['tags']: fail('tag exists', 422)
            s['tags'][tag] = {'type': 'commit', 'sha': p['sha']}
        elif ref == 'refs/heads/updates':
            if s.get('updates'): fail('branch exists', 422)
            s['updates'] = p['sha']
        else: fail('unknown ref')
        out({'object': {'type': 'commit', 'sha': p['sha']}})
    elif method == 'PATCH' and route.startswith('git/refs/tags/'):
        tag = route[len('git/refs/tags/'):]
        if tag not in s['tags'] or p.get('force') is not True: fail('bad tag update')
        s['tags'][tag] = {'type': 'commit', 'sha': p['sha']}
        if s.get('branch_after_tag_move'): s['branches']['main'] = s.pop('branch_after_tag_move')
        out({'object': s['tags'][tag]})
    elif method == 'PATCH' and route == 'git/refs/heads/updates':
        if p.get('force') is not False: fail('updates write must be non-force')
        if s['commits'][p['sha']]['parents'] != [s.get('updates')]: fail('non-fast-forward', 422)
        s['updates'] = p['sha']
        out({'object': {'type': 'commit', 'sha': p['sha']}})
    elif method == 'POST' and route == 'git/trees':
        entries = p['tree']
        if len(entries) != 1 or (entries[0]['path'], entries[0]['mode'], entries[0]['type']) != ('update.json', '100644', 'blob'):
            fail('invalid data tree')
        out({'sha': new_tree(entries[0]['content'])})
    elif method == 'POST' and route == 'git/commits':
        sha = new_sha()
        s['commits'][sha] = {'tree': {'sha': p['tree']}, 'parents': p['parents']}
        out({'sha': sha})
    elif method == 'GET' and route.startswith('git/commits/'):
        out(s['commits'][route[len('git/commits/'):]])
    elif method == 'GET' and route.startswith('git/trees/'):
        out(s['trees'][route[len('git/trees/'):]])
    elif method == 'GET' and route.startswith('git/blobs/'):
        out(s['blobs'][route[len('git/blobs/'):]])
    elif method == 'POST' and route == 'releases':
        if find_release(tag=p['tag_name']): fail('release exists', 422)
        release_id = max([r['id'] for r in s['releases']] + [0]) + 1
        release = {'id': release_id, 'tag_name': p['tag_name'], 'target_commitish': p['target_commitish'],
                   'name': p['name'], 'body': p['body'], 'draft': p['draft'], 'prerelease': p['prerelease'],
                   'published_at': None, 'assets': []}
        s['releases'].append(release)
        out(release)
    elif route.startswith('releases/') and '/assets/' not in route:
        release = find_release(release_id=route[len('releases/'):])
        if not release: fail('missing release', 404)
        if method == 'GET':
            out(release)
        elif method == 'PATCH':
            if release['tag_name'] == 'Autobuild' and 'body' in p and s.get('fail_auto_patch'):
                s['fail_auto_patch'] = False
                fail('injected Autobuild metadata failure', 500)
            # GitHub ignores target_commitish when the tag already exists.
            for key in ('name', 'body', 'draft'):
                if key in p: release[key] = p[key]
            if release['draft'] is False and not release['published_at']:
                release['published_at'] = '2026-01-02T03:04:05Z'
            if release['draft'] is False:
                for asset in release['assets']:
                    asset['browser_download_url'] = f"https://github.com/{s['repository']}/releases/download/{release['tag_name']}/{asset['name']}"
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
    if any(item['name'] == item_path.name for item in release['assets']): fail('asset exists', 422)
    if s.get('upload_fail') == 'before':
        s['upload_fail'] = None
        fail('injected upload failure', 500)
    content = item_path.read_bytes()
    tag = 'untagged-draft' if release['draft'] else release['tag_name']
    asset = {'id': max([item['id'] for r in s['releases'] for item in r['assets']] + [0]) + 1,
             'name': item_path.name, 'state': 'uploaded', 'size': len(content),
             'digest': 'sha256:' + hashlib.sha256(content).hexdigest(), 'created_at': '2026-01-02T03:04:05Z',
             'content': base64.b64encode(content).decode(),
             'browser_download_url': f"https://github.com/{s['repository']}/releases/download/{tag}/{item_path.name}"}
    if s.get('wrong_upload_size'): asset['size'] += 1
    release['assets'].append(asset)
    if s.get('branch_after_upload'): s['branches']['main'] = s.pop('branch_after_upload')
    if s.get('tag_after_upload'): s['tags']['Autobuild']['sha'] = s.pop('tag_after_upload')
    if s.get('upload_fail') == 'after':
        s['upload_fail'] = None
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
    item = asset(tag, name)
    item["id"] = release_id * 10
    if draft:
        item["browser_download_url"] = f"{BASE}/untagged-draft/{name}"
    return {"id": release_id, "tag_name": tag, "target_commitish": commit, "name": tag, "body": "body",
            "draft": draft, "prerelease": False, "published_at": None if draft else DATE, "assets": [item]}


def state_for(commit):
    return {"repository": REPOSITORY, "branches": {"main": commit}, "tags": {}, "releases": [],
            "latest": None, "updates": None, "commits": {}, "trees": {}, "blobs": {}, "calls": []}


def add_release(state, item):
    state["releases"].append(item)
    state["tags"][item["tag_name"]] = {"type": "commit", "sha": item["target_commitish"]}


def read_feed(state):
    commit = state["commits"][state["updates"]]
    tree = state["trees"][commit["tree"]["sha"]]
    blob = state["blobs"][tree["tree"][0]["sha"]]
    return json.loads(base64.b64decode(blob["content"]))


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

    def publish(self, state, commit, channel="autobuild", version="1.0.0", content=b"new package"):
        name = f"Motionpaper-{commit[:12]}.dmg" if channel == "autobuild" else f"Motionpaper-v{version}.dmg"
        (self.root / "dist" / name).write_bytes(content)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        env = os.environ.copy()
        env.update({"PATH": f"{self.root / 'bin'}:{env['PATH']}", "MOCK_GH_STATE": str(self.state_path),
                    "GH_TOKEN": "mock", "GITHUB_REPOSITORY": REPOSITORY, "RELEASE_COMMIT": commit,
                    "DEFAULT_BRANCH": "main", "MOTIONPAPER_RELEASE_CHANNEL": channel, "MOTIONPAPER_VERSION": version,
                    "PYTHONDONTWRITEBYTECODE": "1"})
        result = subprocess.run(["bash", str(PUBLISHER)], cwd=self.root, env=env, text=True, capture_output=True)
        return result, json.loads(self.state_path.read_text())

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_and_repeated_autobuild_reuses_release_asset_and_feed(self):
        commit = "a" * 40
        first, state = self.publish(state_for(commit), commit)
        self.assert_success(first)
        self.assertEqual([r["tag_name"] for r in state["releases"]], ["Autobuild"])
        self.assertEqual(list(state["tags"]), ["Autobuild"])
        self.assertEqual(read_feed(state)["autobuild"]["commit"], commit)
        self.assertEqual(read_feed(state)["autobuild"]["downloadURL"], f"{BASE}/Autobuild/Motionpaper-{'a' * 12}.dmg")
        calls, head = len(state["calls"]), state["updates"]
        second, state = self.publish(state, commit, content=b"different rebuild bytes")
        self.assert_success(second)
        self.assertIn("Reusing complete", second.stdout)
        self.assertEqual(state["updates"], head)
        self.assertFalse(any(call[:2] in (["release", "upload"], ["release", "download"]) for call in state["calls"][calls:]))
        self.assertFalse(any("git/trees" in call for call in state["calls"][calls:]))

    def test_two_commits_keep_one_release_and_old_dmg_and_publish_in_order(self):
        first_commit, second_commit = "a" * 40, "b" * 40
        first, state = self.publish(state_for(first_commit), first_commit)
        self.assert_success(first)
        old_feed = read_feed(state)
        state["branches"]["main"] = second_commit
        offset = len(state["calls"])
        result, state = self.publish(state, second_commit)
        self.assert_success(result)
        self.assertEqual(list(state["tags"]), ["Autobuild"])
        self.assertEqual(state["tags"]["Autobuild"]["sha"], second_commit)
        self.assertEqual(len(state["releases"]), 1)
        release = state["releases"][0]
        self.assertEqual(release["target_commitish"], first_commit)
        self.assertEqual({item["name"] for item in release["assets"]},
                         {f"Motionpaper-{first_commit[:12]}.dmg", f"Motionpaper-{second_commit[:12]}.dmg"})
        self.assertEqual(read_feed(state)["autobuild"]["commit"], second_commit)
        self.assertTrue(any(item["browser_download_url"] == old_feed["autobuild"]["downloadURL"] for item in release["assets"]))
        calls = state["calls"][offset:]
        upload = next(i for i, c in enumerate(calls) if c[:2] == ["release", "upload"])
        tag_move = next(i for i, c in enumerate(calls) if "repos/owner/repo/git/refs/tags/Autobuild" in c and "PATCH" in c)
        release_update = next(i for i, c in enumerate(calls) if "repos/owner/repo/releases/1" in c and "PATCH" in c)
        feed_update = next(i for i, c in enumerate(calls) if "repos/owner/repo/git/refs/heads/updates" in c and "PATCH" in c)
        self.assertLess(upload, tag_move)
        self.assertLess(tag_move, release_update)
        self.assertLess(release_update, feed_update)
        self.assertFalse(any("DELETE" in call for call in calls))

    def test_failed_upload_preserves_old_feed_tag_and_dmg_and_retry_resumes(self):
        for when in ("before", "after"):
            with self.subTest(when=when):
                old, new = "a" * 40, "b" * 40
                result, state = self.publish(state_for(old), old)
                self.assert_success(result)
                head, old_feed = state["updates"], read_feed(state)
                state["branches"]["main"] = new
                state["upload_fail"] = when
                result, state = self.publish(state, new)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["updates"], head)
                self.assertEqual(read_feed(state), old_feed)
                self.assertEqual(state["tags"]["Autobuild"]["sha"], old)
                self.assertEqual(state["releases"][0]["target_commitish"], old)
                self.assertIn(f"Motionpaper-{old[:12]}.dmg", [item["name"] for item in state["releases"][0]["assets"]])
                result, state = self.publish(state, new, content=b"different retry")
                self.assert_success(result)
                self.assertEqual(read_feed(state)["autobuild"]["commit"], new)

    def test_first_autobuild_draft_resumes_an_interrupted_upload(self):
        commit = "a" * 40
        state = state_for(commit)
        state["upload_fail"] = "after"
        result, state = self.publish(state, commit, content=b"verified on retry")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["releases"][0]["draft"])
        self.assertIsNone(state["updates"])
        result, state = self.publish(state, commit, content=b"a different rebuild")
        self.assert_success(result)
        self.assertFalse(state["releases"][0]["draft"])
        self.assertEqual(read_feed(state)["autobuild"]["sha256"], hashlib.sha256(b"verified on retry").hexdigest())
        self.assertTrue(any(call[:2] == ["release", "download"] for call in state["calls"]))

    def test_invalid_upload_metadata_never_moves_tag_or_feed(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        old_head = state["updates"]
        state["branches"]["main"] = new
        state["wrong_upload_size"] = True
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertEqual(state["updates"], old_head)
        self.assertEqual(state["tags"]["Autobuild"]["sha"], old)

    def test_advanced_branch_is_skipped_before_and_after_upload(self):
        old, new = "a" * 40, "b" * 40
        state = state_for(new)
        result, state = self.publish(state, old)
        self.assert_success(result)
        self.assertEqual(state["releases"], [])
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        head = state["updates"]
        state["branches"]["main"] = new
        state["branch_after_upload"] = "c" * 40
        result, state = self.publish(state, new)
        self.assert_success(result)
        self.assertEqual(state["tags"]["Autobuild"]["sha"], old)
        self.assertEqual(state["updates"], head)

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

    def test_stable_draft_retry_reuses_verified_bytes_without_deleting_other_assets(self):
        commit = "a" * 40
        state = state_for(commit)
        draft = released("stable", commit, version="1.2.3", draft=True)
        extra = asset("v1.2.3", "notes.txt", b"notes")
        extra["id"] = 11
        draft["assets"].append(extra)
        add_release(state, draft)
        result, state = self.publish(state, commit, "stable", "1.2.3", content=b"different rebuild")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.2.3")
        self.assertEqual(read_feed(state)["stable"]["commit"], commit)
        self.assertEqual({item["name"] for item in state["releases"][0]["assets"]}, {"Motionpaper-v1.2.3.dmg", "notes.txt"})
        self.assertTrue(any(call[:2] == ["release", "download"] for call in state["calls"]))
        self.assertFalse(any(call[:2] == ["release", "upload"] or "DELETE" in call for call in state["calls"]))

    def test_tampered_existing_draft_dmg_is_not_published(self):
        commit = "a" * 40
        state = state_for(commit)
        add_release(state, released("stable", commit, version="1.2.3", draft=True))
        state["tamper_download"] = True
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["releases"][0]["draft"])
        self.assertIsNone(state["updates"])

    def test_stable_highest_version_remains_latest_and_feed_uses_highest_on_bootstrap(self):
        old, high = "a" * 40, "b" * 40
        state = state_for(old)
        add_release(state, released("stable", high, 3, "1.10.0"))
        state["latest"] = "v1.10.0"
        state["tags"]["v1.2.3"] = {"type": "commit", "sha": old}
        result, state = self.publish(state, old, "stable", "1.2.3")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.10.0")
        self.assertEqual(read_feed(state)["stable"]["version"], "1.10.0")
        self.assertEqual(len(state["releases"]), 2)

    def test_missing_latest_is_repaired_to_highest_stable(self):
        commit = "a" * 40
        state = state_for(commit)
        add_release(state, released("stable", commit, version="1.2.3"))
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assert_success(result)
        self.assertEqual(state["latest"], "v1.2.3")

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

    def test_published_stable_is_reused_and_never_has_assets_deleted(self):
        commit = "a" * 40
        state = state_for(commit)
        stable = released("stable", commit, version="1.2.3")
        extra = asset("v1.2.3", "notes.txt", b"release notes")
        extra["id"] = 11
        stable["assets"].append(extra)
        add_release(state, stable)
        state["latest"] = "v1.2.3"
        result, state = self.publish(state, commit, "stable", "1.2.3")
        self.assert_success(result)
        self.assertEqual(state["releases"][0]["assets"], stable["assets"])
        self.assertFalse(any("DELETE" in call or call[:2] == ["release", "upload"] for call in state["calls"]))

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
                self.assertIsNone(state["updates"])
                self.assertFalse(any("DELETE" in call for call in state["calls"]))

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
                feed_head = state["updates"]
                state["branches"]["main"] = c1
                if interrupted_by == "branch_advanced":
                    state["branch_after_tag_move"] = c2
                else:
                    state["fail_auto_patch"] = True
                result, state = self.publish(state, c1)
                if interrupted_by == "branch_advanced":
                    self.assert_success(result)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    state["branches"]["main"] = c2
                self.assertEqual(state["tags"]["Autobuild"]["sha"], c1)
                self.assertEqual(state["releases"][0]["target_commitish"], c0)
                self.assertEqual(state["updates"], feed_head)
                result, state = self.publish(state, c2)
                self.assert_success(result)
                self.assertEqual(state["tags"]["Autobuild"]["sha"], c2)
                self.assertEqual(state["releases"][0]["target_commitish"], c0)
                self.assertEqual(read_feed(state)["autobuild"]["commit"], c2)
                self.assertEqual({asset["name"] for asset in state["releases"][0]["assets"]},
                                 {f"Motionpaper-{c[:12]}.dmg" for c in (c0, c1, c2)})

    def test_tag_changed_during_upload_is_rejected_even_if_it_is_the_new_commit(self):
        old, new = "a" * 40, "b" * 40
        result, state = self.publish(state_for(old), old)
        self.assert_success(result)
        head = state["updates"]
        state["branches"]["main"] = new
        state["tag_after_upload"] = new
        result, state = self.publish(state, new)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag changed during upload", result.stderr)
        self.assertEqual(state["releases"][0]["target_commitish"], old)
        self.assertEqual(state["updates"], head)


if __name__ == "__main__":
    unittest.main()

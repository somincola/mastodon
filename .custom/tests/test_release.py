import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CUSTOM = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_plan', CUSTOM / 'release_plan.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseSelectionTests(unittest.TestCase):
    tags = ['v4.6.7', 'v4.7.1', 'v4.7.2', 'v4.7.10', 'v4.7.99-rc.1', 'v4.8.0']

    def test_schedule_stays_in_reviewed_series_and_sorts_numerically(self):
        result = release.plan('v4.7.1', 'v4.7.1', self.tags)
        self.assertEqual(result['version'], 'v4.7.10')
        self.assertTrue(result['build_images'] and result['publish_latest'] and result['deploy'])

    def test_unchanged_release_does_not_rebuild_or_restart(self):
        result = release.plan('v4.7.10', 'v4.7.10', self.tags)
        self.assertFalse(result['should_run'])

    def test_build_only_publication_is_deployed_on_next_schedule_without_rebuilding(self):
        result = release.plan('v4.7.1', 'v4.7.10', self.tags)
        self.assertTrue(result['deploy'])
        self.assertFalse(result['build_images'])

    def test_bootstrap_reuses_verified_471_images_to_repair_old_latest(self):
        result = release.plan('v4.7.1', 'v4.6.7', self.tags, requested='v4.7.1', reuse=True, deploy=False)
        self.assertTrue(result['publish_latest'])
        self.assertFalse(result['build_images'] or result['deploy'])

    def test_historical_build_cannot_move_latest_backwards(self):
        with self.assertRaises(ValueError):
            release.plan('v4.7.1', 'v4.7.1', self.tags, requested='v4.6.7')
        result = release.plan('v4.7.1', 'v4.7.1', self.tags, requested='v4.6.7', publish=False, deploy=False)
        self.assertTrue(result['build_images'])
        self.assertFalse(result['publish_latest'] or result['deploy'])

    def test_cross_minor_release_is_available_only_as_versioned_build(self):
        with self.assertRaises(ValueError):
            release.plan('v4.7.1', 'v4.7.1', self.tags, requested='v4.8.0')
        result = release.plan('v4.7.1', 'v4.7.1', self.tags, requested='v4.8.0', publish=False, deploy=False)
        self.assertTrue(result['build_images'])

    def test_branch_cannot_publish_latest_or_deploy(self):
        result = release.plan('v4.7.1', 'v4.7.1', self.tags, force=True, main=False)
        self.assertTrue(result['build_images'])
        self.assertFalse(result['publish_latest'] or result['deploy'])

    def test_deploy_cannot_bypass_promotion(self):
        with self.assertRaises(ValueError):
            release.plan('v4.7.1', 'v4.7.1', self.tags, publish=False)

    def test_untrusted_or_prerelease_inputs_are_rejected(self):
        for value in ['v4.7.1;id', 'v4.7.99-rc.1', 'v4.7.12', 'main']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.plan('v4.7.1', 'v4.7.1', self.tags, requested=value)


class PublicationFailureTests(unittest.TestCase):
    def run_publication(self, fail_streaming=False, invalid=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state.json'
            old = {'bailongctui/mastodon:latest': 'sha256:'+'a'*64,
                   'bailongctui/mastodon-streaming:latest': 'sha256:'+'b'*64}
            state.write_text(json.dumps(old))
            docker = root / 'docker'
            docker.write_text('#!' + sys.executable + '\n' + r'''
import json,os,pathlib,sys
p=pathlib.Path(os.environ['FAKE_REGISTRY']); values=json.loads(p.read_text()); args=sys.argv[1:]
if args[:3]==['buildx','imagetools','inspect']:
    print(json.dumps({'digest':values[args[3]]})); sys.exit(0)
assert args[:3]==['buildx','imagetools','create'], args
tag=args[args.index('--tag')+1]; digest=args[-1].split('@')[1]
marker=p.with_suffix('.failed')
if os.environ.get('FAIL_STREAMING')=='1' and tag.endswith('streaming:latest') and digest=='sha256:'+'d'*64 and not marker.exists():
    marker.touch(); sys.exit(1)
values[tag]=digest; p.write_text(json.dumps(values))
''')
            docker.chmod(0o755)
            env = {**os.environ, 'PATH': str(root)+os.pathsep+os.environ['PATH'], 'FAKE_REGISTRY': str(state), 'FAIL_STREAMING': str(int(fail_streaming))}
            result = subprocess.run(['bash', str(CUSTOM/'promote-latest.sh'), 'invalid' if invalid else 'sha256:'+'c'*64, 'sha256:'+'d'*64], env=env, capture_output=True, text=True)
            return result, old, json.loads(state.read_text())

    def test_both_tags_publish_only_the_verified_digests(self):
        result, _, state = self.run_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['bailongctui/mastodon:latest'], 'sha256:'+'c'*64)
        self.assertEqual(state['bailongctui/mastodon-streaming:latest'], 'sha256:'+'d'*64)

    def test_second_tag_failure_restores_the_original_pair(self):
        result, old, state = self.run_publication(fail_streaming=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state, old)

    def test_invalid_digest_does_not_touch_the_registry(self):
        result, old, state = self.run_publication(invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state, old)

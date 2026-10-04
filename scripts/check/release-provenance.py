#!/usr/bin/env python3
"""Check immutable publication using temporary dummy artifacts, never real release files."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_provenance', Path(__file__).resolve().parents[1] / 'release/provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.before = {'commit': 'synthetic', 'dirty': False, 'sourceTreeSHA256': 'synthetic-tree', 'version': 'test', 'build': 1}
        self.source = patch.object(provenance, 'source', return_value=self.before)
        self.source.start()
        self.addCleanup(self.source.stop)
        self.snapshot = self.root / 'source.json'
        self.snapshot.write_text(json.dumps(self.before))
        self.original = self.root / 'original.bin'
        self.original.write_bytes(b'synthetic artifact')
        self.output = self.root / 'build-1/artifact.bin'
        self.sidecar = self.output.with_name(self.output.name + '.build.json')

    def publish(self):
        provenance.publish(self.snapshot, self.original, self.output)

    def testDigestIsOfPublishedBytesAndRepeatNeverReplacesMetadata(self):
        self.publish()
        value = json.loads(self.sidecar.read_text())
        self.assertEqual(value['sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(value['validation']['deviceAcceptance'], 'not_performed')
        self.assertEqual(value['validation']['hostedCI'], 'not_checked')
        inode = self.sidecar.stat().st_ino
        self.publish()
        self.assertEqual(inode, self.sidecar.stat().st_ino)

    def testDifferentBytesLeaveExistingArtifactAndProvenanceUntouched(self):
        self.publish()
        before = self.output.read_bytes(), self.sidecar.read_bytes()
        self.original.write_bytes(b'changed artifact')
        with self.assertRaises(SystemExit):
            self.publish()
        self.assertEqual(before, (self.output.read_bytes(), self.sidecar.read_bytes()))

    def testOrphanedProvenanceCannotBeOverwritten(self):
        self.output.parent.mkdir()
        self.sidecar.write_text('{"existing": true}\n')
        with self.assertRaises(SystemExit):
            self.publish()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.sidecar.read_text(), '{"existing": true}\n')

    def testConcurrentIdenticalPublicationHasOneIntactMetadataClaim(self):
        with ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(self.publish) for _ in range(16)]
            for future in futures:
                future.result()
        self.assertEqual(json.loads(self.sidecar.read_text())['sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(set(self.output.parent.iterdir()), {self.output, self.sidecar})

    def testChangedSourceBeforeClaimPublishesNothing(self):
        with patch.object(provenance, 'source', side_effect=[self.before, dict(self.before, dirty=True)]):
            with self.assertRaises(SystemExit):
                self.publish()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.sidecar.exists())

    def testChangingStagingFileCannotPublishATornCopy(self):
        original = self.original.stat()
        changed = SimpleNamespace(st_dev=original.st_dev, st_ino=original.st_ino, st_size=original.st_size,
                                  st_mtime_ns=original.st_mtime_ns + 1, st_ctime_ns=original.st_ctime_ns + 1)
        with patch.object(provenance.os, 'fstat', side_effect=[original, changed]):
            with self.assertRaises(SystemExit):
                self.publish()
        self.assertFalse(self.output.exists())

    def testExistingSymlinkIsNotFollowedOrReplaced(self):
        self.output.parent.mkdir()
        self.sidecar.symlink_to(self.snapshot)
        snapshot = self.snapshot.read_bytes()
        with self.assertRaises(SystemExit):
            self.publish()
        self.assertEqual(snapshot, self.snapshot.read_bytes())
        self.assertTrue(self.sidecar.is_symlink())


if __name__ == '__main__':
    unittest.main()

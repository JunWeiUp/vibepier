#!/usr/bin/env python3
"""Temporary fixtures only: no real applications, LaunchAgents, keys or permissions."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("vibepier_macos_installer", Path(__file__).with_name("macos.py"))
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)


class FakeBackend:
    def __init__(self, source, target):
        self.source, self.target = source, target
        self.old = installer.Signature(installer.BUNDLE_ID, "synthetic-team", "A" * 40, "identifier synthetic-app", {"audio": True}, 0)
        self.helper = installer.Signature("VibePierFileServer", "synthetic-team", "A" * 40, "identifier synthetic-helper", {}, 0)
        self.candidate = installer.Signature(installer.BUNDLE_ID, "", None, 'cdhash H"synthetic"', {}, 2)
        self.candidate_helper = installer.Signature("VibePierFileServer", "", None, 'cdhash H"synthetic-helper"', {}, 2)
        self.sign_calls = []
        self.stop_calls = self.resume_calls = 0
        self.available = True
        self.loaded = True
        self.fail_new_verification = False
        self.fail_resume = False
        self.fail_stop = False
        self.manual_running = False
        self.fail_runtime = False
        self.runtime_checks = 0

    def inspect(self, path):
        if path == self.source:
            return self.candidate
        if path == self.source / installer.HELPER:
            return self.candidate_helper
        return self.helper if path.name == "VibePierFileServer" else self.old

    def identity_available(self, _fingerprint):
        return self.available

    def verify_identity(self, path, expected):
        if path in [self.source, self.source / installer.HELPER] and self.inspect(path) != expected:
            raise installer.UpdateError("Synthetic identity mismatch")
        if path == self.target and self.fail_new_verification and (path / installer.EXECUTABLE).read_bytes() == b"new":
            raise installer.UpdateError("Synthetic installed validation failure")

    def sign(self, path, expected, _workspace):
        self.sign_calls.append((path, expected))

    def run(self, arguments, check=True):
        assert arguments[:3] == ["/bin/launchctl", "print", f"gui/{os.getuid()}/{installer.BUNDLE_ID}"]
        return subprocess.CompletedProcess(arguments, 0 if self.loaded else 1, b"", b"")

    def stop(self, _target, _plist):
        self.stop_calls += 1
        self.loaded = False
        if self.fail_stop:
            raise installer.UpdateError("Synthetic stop failure")
        return True

    def executable_pids(self, _target, include_helper=True):
        return [12345] if self.manual_running else []

    def verify_running(self, _target):
        self.runtime_checks += 1
        if self.fail_runtime:
            self.fail_runtime = False
            raise installer.UpdateError("Synthetic immediate process exit")

    def resume(self, _plist):
        self.resume_calls += 1
        if self.fail_resume:
            self.fail_resume = False
            self.loaded = True
            raise installer.UpdateError("Synthetic restart failure")
        self.loaded = True


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vibepier-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source/VibePier.app"
        self.target = self.root / "installed/VibePier.app"
        for path, content, build in [(self.source, b"new", "25"), (self.target, b"old", "24")]:
            (path / "Contents/MacOS").mkdir(parents=True)
            (path / "Contents/Resources").mkdir()
            (path / installer.EXECUTABLE).write_bytes(content)
            (path / installer.HELPER).write_bytes(b"synthetic-helper")
            for relative in [installer.EXECUTABLE, installer.HELPER]:
                (path / relative).chmod(0o755)
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": installer.BUNDLE_ID, "CFBundleExecutable": "VibePier", "CFBundleVersion": build}))
        (self.target / "Contents/Resources/stale.txt").write_text("must disappear")
        self.backend = FakeBackend(self.source, self.target)
        self.plist = self.root / "original-job.plist"
        self.original_job = {"Label": installer.BUNDLE_ID, "ProgramArguments": [str(self.target / installer.EXECUTABLE)],
                             "EnvironmentVariables": {"SYNTHETIC_PROXY": "local-only"}, "KeepAlive": {"SuccessfulExit": False}}
        self.plist.write_bytes(plistlib.dumps(self.original_job))
        self.plist.chmod(0o644)
        self.config = self.root / "config.json"
        self.config.write_bytes(b'{"synthetic":"retain"}')
        self.hashes = {path: installer.hashlib.sha256(path.read_bytes()).hexdigest() for path in [self.plist, self.config]}

    def plan(self):
        return installer.preflight(self.source, self.target, self.backend)

    def preserved(self):
        return self.plist, dict(self.hashes), installer.association_update(self.plist.read_bytes(), self.target)

    def install(self):
        with patch.object(installer, "preserved_files", return_value=self.preserved()), \
                patch.object(installer, "update_lock_directory", return_value=self.root / "locks"):
            return installer.apply(self.plan(), self.root / "backups", self.backend)

    def test_dry_run_reads_only_and_does_not_sign_stop_or_change_files(self):
        before = installer.tree_manifest(self.root)
        with patch.object(installer.sys, "platform", "darwin"), patch.object(installer, "Backend", return_value=self.backend), \
                patch.object(installer, "preserved_files", return_value=self.preserved()), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(installer.main(["--source", str(self.source), "--target", str(self.target), "--dry-run"]), 0)
        self.assertIn('"mode": "dry-run"', output.getvalue())
        self.assertEqual(installer.tree_manifest(self.root), before)
        self.assertEqual(self.backend.sign_calls, [])
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (0, 0))

    def test_prepare_signs_only_new_copy_with_exact_inner_and_outer_identity(self):
        parent = self.root / "prepared"
        parent.mkdir()
        output = parent / "VibePier.app"
        before = installer.tree_manifest(self.target)
        inode = self.target.stat().st_ino
        installer.prepare(self.plan(), output, self.backend)
        self.assertEqual(self.backend.sign_calls, [(output / installer.HELPER, self.backend.helper), (output, self.backend.old)])
        self.assertEqual(installer.tree_manifest(self.target), before)
        self.assertEqual(self.target.stat().st_ino, inode)
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (0, 0))
        with self.assertRaises(installer.UpdateError):
            installer.prepare(self.plan(), output, self.backend)

    def test_apply_preserves_app_inode_cleans_stale_resources_and_keeps_settings(self):
        inode = self.target.stat().st_ino
        contents_inode = (self.target / "Contents").stat().st_ino
        info_inode = (self.target / "Contents/Info.plist").stat().st_ino
        executable_inodes = {relative: (self.target / relative).stat().st_ino for relative in [installer.EXECUTABLE, installer.HELPER]}
        old_manifest = installer.tree_manifest(self.target)
        config = self.config.read_bytes()
        backup = self.install()
        self.assertEqual(self.target.stat().st_ino, inode)
        self.assertEqual((self.target / "Contents").stat().st_ino, contents_inode)
        self.assertEqual((self.target / "Contents/Info.plist").stat().st_ino, info_inode)
        for relative, old_inode in executable_inodes.items():
            self.assertNotEqual((self.target / relative).stat().st_ino, old_inode)
        self.assertEqual((self.target / installer.EXECUTABLE).read_bytes(), b"new")
        self.assertFalse((self.target / "Contents/Resources/stale.txt").exists())
        self.assertEqual(installer.tree_manifest(backup), old_manifest)
        self.assertEqual(self.config.read_bytes(), config)
        job = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(job.pop("AssociatedBundleIdentifiers"), [installer.BUNDLE_ID])
        self.assertEqual(job, self.original_job)
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (1, 1))
        self.assertEqual((backup.parent.stat().st_mode & 0o777), 0o700)

    def test_failed_installed_verification_restores_same_inode_and_original_files(self):
        inode = self.target.stat().st_ino
        contents_inode = (self.target / "Contents").stat().st_ino
        info_inode = (self.target / "Contents/Info.plist").stat().st_ino
        executable_inodes = {relative: (self.target / relative).stat().st_ino for relative in [installer.EXECUTABLE, installer.HELPER]}
        before, job = installer.tree_manifest(self.target), self.plist.read_bytes()
        self.backend.fail_new_verification = True
        with self.assertRaises(installer.UpdateError):
            self.install()
        self.assertEqual(installer.tree_manifest(self.target), before)
        self.assertEqual(self.target.stat().st_ino, inode)
        self.assertEqual((self.target / "Contents").stat().st_ino, contents_inode)
        self.assertEqual((self.target / "Contents/Info.plist").stat().st_ino, info_inode)
        for relative, old_inode in executable_inodes.items():
            self.assertNotEqual((self.target / relative).stat().st_ino, old_inode)
        self.assertEqual(self.plist.read_bytes(), job)
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (1, 1))

    def test_failed_restart_stops_candidate_and_restores_original_plist_bytes(self):
        inode = self.target.stat().st_ino
        before, job = installer.tree_manifest(self.target), self.plist.read_bytes()
        self.backend.fail_resume = True
        with self.assertRaises(installer.UpdateError):
            self.install()
        self.assertEqual(installer.tree_manifest(self.target), before)
        self.assertEqual(self.target.stat().st_ino, inode)
        self.assertEqual(self.plist.read_bytes(), job)
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (2, 2))

    def test_failed_stop_never_changes_installed_bundle(self):
        before = installer.tree_manifest(self.target)
        self.backend.fail_stop = True
        with self.assertRaises(installer.UpdateError):
            self.install()
        self.assertEqual(installer.tree_manifest(self.target), before)
        self.assertEqual(self.backend.resume_calls, 1)

    def test_same_target_uses_one_lock_even_with_different_backup_roots(self):
        directory = self.root / "locks"
        directory.mkdir(mode=0o700)
        name = installer.hashlib.sha256(os.fsencode(self.target)).hexdigest() + ".lock"
        descriptor = os.open(directory / name, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            installer.fcntl.flock(descriptor, installer.fcntl.LOCK_EX | installer.fcntl.LOCK_NB)
            with patch.object(installer, "update_lock_directory", return_value=directory), self.assertRaises(installer.UpdateError):
                installer.apply(self.plan(), self.root / "different-backups", self.backend)
        finally:
            os.close(descriptor)
        self.assertEqual(self.backend.stop_calls, 0)

    def test_manually_running_app_is_refused_without_closing_it(self):
        self.backend.loaded = False
        self.backend.manual_running = True
        before = installer.tree_manifest(self.target)
        with self.assertRaises(installer.UpdateError):
            self.install()
        self.assertEqual(self.backend.stop_calls, 0)
        self.assertEqual(self.backend.resume_calls, 0)
        self.assertEqual(installer.tree_manifest(self.target), before)

    def test_immediate_exit_after_restart_rolls_back_instead_of_recording_success(self):
        before, job = installer.tree_manifest(self.target), self.plist.read_bytes()
        self.backend.fail_runtime = True
        with self.assertRaises(installer.UpdateError):
            self.install()
        self.assertEqual(installer.tree_manifest(self.target), before)
        self.assertEqual(self.plist.read_bytes(), job)
        self.assertEqual((self.backend.stop_calls, self.backend.resume_calls), (2, 2))
        self.assertEqual(self.backend.runtime_checks, 2)

    def test_identity_drift_and_missing_exact_private_key_are_refused(self):
        self.backend.available = False
        with self.assertRaises(installer.UpdateError):
            self.plan()
        self.backend.available = True
        self.backend.candidate = installer.Signature(installer.BUNDLE_ID, "other-team", "B" * 40, "identifier different", {}, 0)
        with self.assertRaises(installer.UpdateError):
            self.plan()

    def test_source_symlinks_overlap_and_downgrade_are_refused(self):
        with self.assertRaises(installer.UpdateError):
            installer.preflight(self.target, self.target, self.backend)
        link = self.source / "Contents/Resources/external"
        link.symlink_to(self.config)
        with self.assertRaises(installer.UpdateError):
            self.plan()
        link.unlink()
        info = plistlib.loads((self.source / "Contents/Info.plist").read_bytes())
        info["CFBundleVersion"] = "23"
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaises(installer.UpdateError):
            self.plan()

    def test_overlay_refuses_type_changes_before_modifying_any_file(self):
        resource = self.source / "Contents/Resources/stale.txt"
        resource.mkdir()
        before = installer.tree_manifest(self.target)
        with self.assertRaises(installer.UpdateError):
            installer.replace_in_place(self.target, self.source)
        self.assertEqual(installer.tree_manifest(self.target), before)

    def test_parent_link_and_traversal_are_refused_before_resolution(self):
        link = self.root / "linked-source"
        link.symlink_to(self.source.parent, target_is_directory=True)
        with self.assertRaises(installer.UpdateError):
            installer.safe_path(link / "VibePier.app")
        with self.assertRaises(installer.UpdateError):
            installer.safe_path(self.source / ".." / "VibePier.app")

    def test_changes_after_preflight_are_refused_without_stopping(self):
        plan = self.plan()
        (self.source / installer.EXECUTABLE).write_bytes(b"changed")
        with self.assertRaises(installer.UpdateError):
            installer.prepare(plan, self.root / "VibePier.app", self.backend)
        self.assertEqual(self.backend.stop_calls, 0)

    def test_association_preserves_other_ids_and_refuses_unrelated_job(self):
        job = dict(self.original_job, AssociatedBundleIdentifiers=["other.app"])
        updated = plistlib.loads(installer.association_update(plistlib.dumps(job), self.target))
        self.assertEqual(updated.pop("AssociatedBundleIdentifiers"), ["other.app", installer.BUNDLE_ID])
        job.pop("AssociatedBundleIdentifiers")
        self.assertEqual(updated, job)
        already = dict(job, AssociatedBundleIdentifiers=["other.app", installer.BUNDLE_ID])
        self.assertIsNone(installer.association_update(plistlib.dumps(already), self.target))
        self.assertIsNone(installer.association_update(plistlib.dumps(dict(job, AssociatedBundleIdentifiers=installer.BUNDLE_ID)), self.target))
        string_association = plistlib.loads(installer.association_update(plistlib.dumps(dict(job, AssociatedBundleIdentifiers="other.app")), self.target))
        self.assertEqual(string_association["AssociatedBundleIdentifiers"], ["other.app", installer.BUNDLE_ID])
        for invalid in [dict(job, Label="other.job"), dict(job, ProgramArguments=["/synthetic/foreign"]),
                        dict(job, Program="/synthetic/foreign"), dict(job, AssociatedBundleIdentifiers=17)]:
            with self.subTest(invalid=invalid), self.assertRaises(installer.UpdateError):
                installer.association_update(plistlib.dumps(invalid), self.target)


if __name__ == "__main__":
    unittest.main()

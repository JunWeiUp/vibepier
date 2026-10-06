#!/usr/bin/env python3
"""Hermetic tests: no SDK, APK build, ADB, emulator or physical device is used."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('android_session_qa', Path(__file__).with_name('android-session-qa.py'))
qa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qa)


def success(probe='codex', locale='en'):
    return ('INSTRUMENTATION_RESULT: probe={}\nINSTRUMENTATION_RESULT: locale={}\n'
            'INSTRUMENTATION_RESULT: stream=PASS: synthetic fixture assertions\nINSTRUMENTATION_CODE: -1\n').format(probe, locale)


def manifest(package, target=qa.PACKAGE, runner=qa.CLASS):
    entry = '<instrumentation android:name="{}" android:targetPackage="{}"/>'.format(runner, target) if package.endswith('.test') else ''
    return '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{}">{}</manifest>'.format(package, entry)


def xmltree(package, target=qa.PACKAGE, runner=qa.CLASS):
    # Matches the actual local build-tools 37.0.0 dump format, including URI,
    # resource IDs, Raw values and four-space element nesting.
    text = ('N: android=http://schemas.android.com/apk/res/android (line=2)\n'
            '  E: manifest (line=2)\n'
            '    A: http://schemas.android.com/apk/res/android:compileSdkVersion(0x01010572)=35\n'
            '    A: package="{0}" (Raw: "{0}")\n'
            '      E: uses-sdk (line=5)\n'
            '        A: http://schemas.android.com/apk/res/android:minSdkVersion(0x0101020c)=33\n').format(package)
    if package.endswith('.test'):
        text += ('      E: instrumentation (line=9)\n'
                 '        A: http://schemas.android.com/apk/res/android:name(0x01010003)="{0}" (Raw: "{0}")\n'
                 '        A: http://schemas.android.com/apk/res/android:targetPackage(0x01010021)="{1}" (Raw: "{1}")\n'
                 '        A: http://schemas.android.com/apk/res/android:functionalTest(0x01010023)=false\n').format(runner, target)
    text += ('      E: application (line=16)\n'
             '        A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=true\n'
             '          E: uses-library (line=19)\n'
             '            A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.test.runner" (Raw: "android.test.runner")\n')
    return text


class FakeSDK:
    def __init__(self):
        self.calls = []
        self.qemu = b'1'
        self.api = b'37'
        self.state = b'device'
        self.bad_manifest = False
        self.install_output = b'Success\n'
        self.outcomes = []
        self.fail_capture = False
        self.fail_stop = False
        self.locale = 'en'
        self.capture_interrupt = False
        self.invalid_png = False
        self.on_call = None
        self.git_available = False
        self.diff = b'synthetic private diff content'
        self.deadlines = []

    def run(self, command, capture_output, timeout, check):
        assert capture_output and not check and 0 < timeout <= 2400
        if timeout > 600:
            assert 'instrument' in command and command[-2] == 'background-soak'
        self.calls.append(command)
        self.deadlines.append(timeout)
        if self.on_call:
            self.on_call(command)
        if command[0] == 'git':
            if not self.git_available:
                raise FileNotFoundError('No fake git installed')
            data = self.diff if 'diff' in command else b'a' * 40 + b'\n'
            return subprocess.CompletedProcess(command, 0, data, b'')
        if command[0] == 'aapt2-fake':
            assert command[1:3] == ['dump', 'xmltree'] and command[-2:] == ['--file', 'AndroidManifest.xml']
            package = qa.TEST_PACKAGE if command[3].endswith('test.apk') else qa.PACKAGE
            target = 'production' if self.bad_manifest else qa.PACKAGE
            return subprocess.CompletedProcess(command, 0, xmltree(package, target).encode(), b'')
        if command[0] == 'analyzer':
            package = qa.TEST_PACKAGE if command[-1].endswith('test.apk') else qa.PACKAGE
            if self.bad_manifest and package == qa.TEST_PACKAGE:
                return subprocess.CompletedProcess(command, 0, manifest(package, target='production').encode(), b'')
            return subprocess.CompletedProcess(command, 0, manifest(package).encode(), b'')
        assert command[:3] == ['adb-fake', '-s', 'emulator-5554'], command
        parts = command[3:]
        output, code = b'', 0
        if parts == ['get-state']:
            output = self.state
        elif parts[:2] == ['shell', 'getprop']:
            output = {'ro.kernel.qemu': self.qemu, 'ro.build.version.sdk': self.api, 'sys.boot_completed': b'1'}[parts[2]]
        elif parts[0] == 'install':
            output = self.install_output
        elif parts[:3] == ['shell', 'pm', 'clear']:
            output = b'Success'
        elif parts[:3] == ['shell', 'cmd', 'locale']:
            self.locale = parts[-1]
        elif parts[:3] == ['shell', 'am', 'instrument']:
            outcome = self.outcomes.pop(0) if self.outcomes else success(parts[-2], self.locale)
            if isinstance(outcome, BaseException):
                raise outcome
            output = outcome.encode()
        elif parts[:3] == ['shell', 'am', 'force-stop'] and self.fail_stop:
            code = 1
        elif parts[:2] == ['exec-out', 'screencap']:
            if self.capture_interrupt:
                raise qa.TerminationRequested('SIGTERM')
            if self.invalid_png:
                return subprocess.CompletedProcess(command, 0, b'not an image', b'')
            if self.fail_capture:
                raise subprocess.TimeoutExpired(command, timeout)
            output = b'\x89PNG\r\n\x1a\nfixture'
        elif parts[:2] == ['exec-out', 'uiautomator']:
            output = b'<?xml version="1.0"?><hierarchy/>'
        return subprocess.CompletedProcess(command, code, output, b'')


class VerificationTests(unittest.TestCase):
    def test_valid_explicit_results_and_locale_list(self):
        for probe in qa.PROBES:
            for locale in qa.LOCALES:
                qa.verify_result(0, success(probe, locale + ',en-US'), probe, locale)

    def test_fail_closed_result_matrix(self):
        good = success()
        invalid = [('', 0), (good, 1), (good.replace('probe=codex', 'probe=composer'), 0),
                   (good.replace('locale=en', 'locale=en-US'), 0),
                   (good.replace('locale=en', 'locale=english'), 0),
                   (good.replace('PASS:', 'SKIP:'), 0), (good.replace('PASS:', 'FAIL:'), 0),
                   (good.replace('-1', '0'), 0), (good + 'INSTRUMENTATION_CODE: -1\n', 0),
                   (good + 'INSTRUMENTATION_RESULT: probe=codex\n', 0),
                   (good + 'INSTRUMENTATION_RESULT: locale=en\n', 0),
                   (good + 'INSTRUMENTATION_RESULT: stream=PASS: duplicate\n', 0),
                   (good + 'OK (0 tests)\n', 0), (good + 'INSTRUMENTATION_FAILED: crash\n', 0)]
        for text, code in invalid:
            with self.subTest(text=text, code=code), self.assertRaises(RuntimeError):
                qa.verify_result(code, text, 'codex', 'en')
        with self.assertRaises(RuntimeError):
            qa.verify_result(0, success('unknown'), 'unknown', 'en')
        with self.assertRaises(RuntimeError):
            qa.verify_result(0, success(locale='zh-TW'), 'codex', 'zh-CN')

    def test_reuses_original_verifier(self):
        with patch.object(qa._ci, 'verify_result', side_effect=RuntimeError('original verifier')) as verify:
            with self.assertRaisesRegex(RuntimeError, 'original verifier'):
                qa.verify_result(0, success(), 'codex', 'en')
            verify.assert_called_once()

    def test_manifest_boundary(self):
        for package in (qa.PACKAGE, qa.TEST_PACKAGE):
            qa.validate_manifest(manifest(package), package)
        for xml, package in [(manifest('production'), qa.PACKAGE),
                             (manifest(qa.TEST_PACKAGE, target='production'), qa.TEST_PACKAGE),
                             (manifest(qa.TEST_PACKAGE, runner='Other'), qa.TEST_PACKAGE),
                             (manifest(qa.PACKAGE), qa.TEST_PACKAGE),
                             (manifest(qa.PACKAGE).replace('<manifest ', '<manifest android:sharedUserId="system" '), qa.PACKAGE)]:
            with self.subTest(xml=xml), self.assertRaises(RuntimeError):
                qa.validate_manifest(xml, package)


class FileIdentityTests(unittest.TestCase):
    def test_hash_and_size_cover_multiple_chunks(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'large.apk'
            data = b'fixture' * 400000
            path.write_bytes(data)
            identity, _ = qa.file_identity(path)
            self.assertEqual(identity, {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})

    def test_mutation_during_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'changing.apk'
            path.write_bytes(b'original')
            original_fstat = qa.os.fstat
            calls = []
            def changed(fd):
                calls.append(fd)
                if len(calls) == 2:
                    path.write_bytes(b'overwritten concurrently')
                return original_fstat(fd)
            with patch.object(qa.os, 'fstat', side_effect=changed), self.assertRaisesRegex(RuntimeError, 'changed while hashing'):
                qa.file_identity(path)


class Aapt2ParsingTests(unittest.TestCase):
    def test_real_tree_structure(self):
        for package in (qa.PACKAGE, qa.TEST_PACKAGE):
            qa.validate_manifest(qa.parse_aapt2_manifest(xmltree(package)), package)

    def test_reject_bad_identities_and_structure(self):
        good = xmltree(qa.TEST_PACKAGE)
        shared = '    A: http://schemas.android.com/apk/res/android:sharedUserId(0x0101000b)="" (Raw: "")\n'
        cases = [('', qa.TEST_PACKAGE),
                 (xmltree('production.test'), qa.TEST_PACKAGE),
                 (xmltree(qa.TEST_PACKAGE, target='production'), qa.TEST_PACKAGE),
                 (xmltree(qa.TEST_PACKAGE, runner='Other'), qa.TEST_PACKAGE),
                 (good.replace('      E: uses-sdk', shared + '      E: uses-sdk'), qa.TEST_PACKAGE),
                 (good.replace('      E: uses-sdk', shared.replace('="" (Raw: "")', '=@0x7f000001') + '      E: uses-sdk'), qa.TEST_PACKAGE),
                 (good.replace('      E: instrumentation', '          E: instrumentation'), qa.TEST_PACKAGE),
                 (good.replace('      E: instrumentation', '      E: application'), qa.TEST_PACKAGE),
                 (good + good, qa.TEST_PACKAGE),
                 (good.replace('    A: package=', '  A: package='), qa.TEST_PACKAGE),
                 (good.replace('(Raw: "' + qa.TEST_PACKAGE + '")', '(Raw: "production")'), qa.TEST_PACKAGE),
                 (good.replace(':targetPackage(0x01010021)', ':other(0x01010021)'), qa.TEST_PACKAGE),
                 (good.replace('    A: package=', '    A: package="duplicate"\n    A: package='), qa.TEST_PACKAGE),
                 (good, qa.PACKAGE)]
        for text, package in cases:
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                qa.validate_manifest(qa.parse_aapt2_manifest(text), package)

    def test_cannot_spoof_root_with_nested_package(self):
        text = xmltree(qa.TEST_PACKAGE).replace('    A: package=', '    A: unrelated=')
        text += '            A: package="{}"\n'.format(qa.TEST_PACKAGE)
        with self.assertRaises(RuntimeError):
            qa.validate_manifest(qa.parse_aapt2_manifest(text), qa.TEST_PACKAGE)

    def test_detect_highest_executable_version(self):
        with tempfile.TemporaryDirectory() as folder:
            sdk = Path(folder)
            self.assertIsNone(qa.discover_aapt2(sdk))
            for version in ('9.0.0', '36.1.0', '37.0.0', '99.0.0'):
                executable = sdk / 'build-tools' / version / 'aapt2'
                executable.parent.mkdir(parents=True)
                executable.write_text('fixture')
                executable.chmod(0o600 if version == '99.0.0' else 0o700)
            self.assertEqual(qa.discover_aapt2(sdk), str(sdk / 'build-tools/37.0.0/aapt2'))


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('app.apk', 'test.apk'):
            (self.root / name).write_bytes(b'fake')
        self.argv = ['--serial', 'emulator-5554', '--output', str(self.root / 'evidence'),
                     '--app-apk', str(self.root / 'app.apk'), '--test-apk', str(self.root / 'test.apk'),
                     '--adb', 'adb-fake', '--apkanalyzer', 'analyzer', '--probes', 'codex,composer', '--locales', 'en']
        self.sdk = FakeSDK()
        self.mock = patch.object(qa.subprocess, 'run', side_effect=self.sdk.run)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def execute(self, extras=()):
        with contextlib.redirect_stdout(io.StringIO()):
            code = qa.main(self.argv + list(extras))
        report = json.loads((self.root / 'evidence/summary.json').read_text())
        self.assertEqual(code, report['exitCode'])
        return code, report

    def test_success_and_no_destructive_or_unscoped_commands(self):
        code, report = self.execute()
        self.assertEqual(code, 0)
        self.assertTrue(report['complete'])
        self.assertTrue(report['passed'])
        self.assertEqual(report['plannedCases'], 2)
        for command in self.sdk.calls:
            self.assertNotIn('clear', command)
            self.assertNotIn('uninstall', command)
            self.assertNotIn('emu', command)
            self.assertNotIn('settings', command)
            self.assertNotIn('gradlew', command)
        self.assertEqual(len([c for c in self.sdk.calls if 'install' in c]), 2)
        self.assertTrue((self.root / 'evidence/en-codex-crash.log').exists())

    def test_explicit_aapt2_path(self):
        index = self.argv.index('--apkanalyzer')
        self.argv[index:index+2] = ['--aapt2', 'aapt2-fake']
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(len([c for c in self.sdk.calls if c[0] == 'aapt2-fake']), 2)

    def test_aapt2_invalid_test_target_blocks_all_installation(self):
        index = self.argv.index('--apkanalyzer')
        self.argv[index:index+2] = ['--aapt2', 'aapt2-fake']
        self.sdk.bad_manifest = True
        self.assertEqual(self.execute()[0], 2)
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_default_aapt2_discovery(self):
        index = self.argv.index('--apkanalyzer')
        del self.argv[index:index+2]
        with patch.object(qa, 'discover_aapt2', return_value='aapt2-fake'):
            self.assertEqual(self.execute()[0], 0)
        self.assertFalse(any(c[0] == 'analyzer' for c in self.sdk.calls))

    def test_default_matrix_and_approval(self):
        args = qa.parse_args(self.argv[:self.argv.index('--probes')])
        self.assertEqual(args.probes, list(qa.DEFAULT_PROBES))
        self.assertEqual(len(args.probes), 12)
        self.assertIn('approval-actions', args.probes)
        self.assertIn('session-cancellation', args.probes)
        self.assertEqual(args.locales, ['en', 'zh-CN'])

    def test_physical_qemu_refused_before_mutation(self):
        self.sdk.qemu = b'0'
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertFalse(report['complete'])
        self.assertFalse(any('install' in c or 'force-stop' in c for c in self.sdk.calls))

    def test_wrong_api_refused(self):
        self.sdk.api = b'36'
        self.assertEqual(self.execute()[0], 2)
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_offline_refused(self):
        self.sdk.state = b'offline'
        self.assertEqual(self.execute()[0], 2)
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_second_manifest_validated_before_first_install(self):
        self.sdk.bad_manifest = True
        self.assertEqual(self.execute()[0], 2)
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_install_requires_success_receipt(self):
        self.sdk.install_output = b'Failure [INSTALL_FAILED_INVALID_APK]'
        self.assertEqual(self.execute()[0], 2)
        self.assertFalse(any('instrument' in c for c in self.sdk.calls))

    def test_reset_only_explicit_review_package(self):
        self.assertEqual(self.execute(['--reset-review-data'])[0], 0)
        clears = [c for c in self.sdk.calls if 'clear' in c]
        self.assertEqual(len(clears), 2)
        self.assertTrue(all(c[-1] == qa.PACKAGE for c in clears))

    def test_timeout_partial_log_stop_before_tree_continue(self):
        self.sdk.outcomes = [subprocess.TimeoutExpired('instrument', 240, output=b'partial log\n', stderr=b'error')]
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertTrue(report['complete'])
        self.assertEqual([r['status'] for r in report['results']], ['timeout', 'passed'])
        tree = next(i for i, c in enumerate(self.sdk.calls) if 'uiautomator' in c)
        self.assertEqual(self.sdk.calls[tree-2][-2:], ['force-stop', qa.PACKAGE])
        self.assertEqual(self.sdk.calls[tree-1][-2:], ['force-stop', qa.TEST_PACKAGE])
        self.assertEqual((self.root / 'evidence/en-codex.log').read_bytes(), b'partial log\nerror')
        self.assertTrue((self.root / 'evidence/en-codex-failure.png').is_file())

    def test_failed_verification_continues(self):
        self.sdk.outcomes = [success('wrong-probe')]
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertEqual([r['passed'] for r in report['results']], [False, True])

    def test_diagnostic_failure_does_not_abort_matrix(self):
        self.sdk.outcomes = ['FAIL: fake']
        self.sdk.fail_capture = True
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertTrue(report['results'][1]['passed'])
        self.assertTrue(report['results'][0]['evidenceErrors'])

    def test_failed_stop_skips_ui_dump_and_reports_cleanup(self):
        self.sdk.outcomes = ['FAIL: fake']
        self.sdk.fail_stop = True
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertTrue(report['cleanupErrors'])
        self.assertFalse(any('uiautomator' in c for c in self.sdk.calls))

    def test_cleanup_failure_turns_success_nonzero(self):
        self.sdk.fail_stop = True
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertFalse(report['passed'])

    def test_sigint_preserves_pending_cases(self):
        self.sdk.outcomes = [KeyboardInterrupt()]
        code, report = self.execute()
        self.assertEqual(code, 130)
        self.assertFalse(report['complete'])
        self.assertEqual([r['status'] for r in report['results']], ['interrupted', 'not-run'])

    def test_sigterm_preserves_pending_cases(self):
        self.sdk.outcomes = [qa.TerminationRequested('SIGTERM')]
        self.assertEqual(self.execute()[0], 143)

    def test_sigterm_during_diagnostics_is_not_swallowed(self):
        self.sdk.outcomes = ['FAIL: fake']
        self.sdk.capture_interrupt = True
        code, report = self.execute()
        self.assertEqual(code, 143)
        self.assertEqual(report['results'][0]['status'], 'interrupted')

    def test_invalid_screenshot_is_reported(self):
        self.sdk.outcomes = ['FAIL: fake']
        self.sdk.invalid_png = True
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertTrue(any('not PNG' in e for e in report['results'][0]['evidenceErrors']))

    def test_complete_default_bilingual_matrix(self):
        self.argv = self.argv[:self.argv.index('--probes')]
        code, report = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(report['plannedCases'], 24)
        self.assertEqual(len(report['results']), 24)
        self.assertTrue(all(r['passed'] for r in report['results']))

    def test_optional_probes_are_explicit_and_run_both_locales(self):
        optional = ('agent-open', 'protocol-negotiation', 'relay-framing',
                    'background-connection', 'enrollment', 'private-storage',
                    'conversation-scroll', 'task-notifications', 'tool-groups',
                    'conversation-images', 'attachment-upload', 'markdown', 'background-soak', 'video-preview', 'apk')
        self.assertEqual(qa.PROBES, qa.DEFAULT_PROBES + optional)
        self.assertEqual(len(set(qa.PROBES)), 27)
        self.assertTrue(set(optional).isdisjoint(qa.DEFAULT_PROBES))
        code, report = self.execute(['--probes', ','.join(optional), '--locales', 'en,zh-CN'])
        self.assertEqual(code, 0)
        self.assertEqual(report['plannedCases'], 30)
        self.assertEqual(len(report['results']), 30)
        self.assertTrue(all(r['passed'] for r in report['results']))
        self.assertEqual({r['probe'] for r in report['results']}, set(optional))

    def test_provenance_and_private_install_snapshots(self):
        self.sdk.git_available = True
        code, report = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(report['git']['head'], 'a' * 40)
        self.assertEqual(report['git']['diffHeadSha256'], hashlib.sha256(self.sdk.diff).hexdigest())
        self.assertNotIn(self.sdk.diff.decode(), json.dumps(report))
        self.assertEqual(report['runnerSha256'], hashlib.sha256(Path(qa.__file__).read_bytes()).hexdigest())
        self.assertEqual(len(report['apkMetadata']), 2)
        for record in report['apkMetadata']:
            self.assertEqual(record['sha256'], hashlib.sha256(b'fake').hexdigest())
            self.assertEqual(record['size'], 4)
            self.assertTrue(record['installed'])
            self.assertEqual(Path(record['snapshot']).read_bytes(), b'fake')
            self.assertNotEqual(record['path'], record['snapshot'])
        installs = [c[-1] for c in self.sdk.calls if 'install' in c]
        self.assertEqual(installs, [r['snapshot'] for r in report['apkMetadata']])

    def test_git_unavailable_does_not_block_installation(self):
        code, report = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(report['git']['status'], 'unavailable')
        self.assertIsNone(report['git']['diffHeadSha256'])

    def test_apk_changed_during_manifest_validation_aborts_before_install(self):
        def replace(command):
            if command[0] == 'analyzer':
                (self.root / 'app.apk').write_bytes(b'evil')
        self.sdk.on_call = replace
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertEqual(report['apkChangeDetected']['stage'], 'after manifest validation')
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_apk_changed_between_validation_and_install_aborts(self):
        def replace(command):
            if command[-1] == 'sys.boot_completed':
                (self.root / 'test.apk').write_bytes(b'new apk bytes')
        self.sdk.on_call = replace
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertEqual(report['apkChangeDetected']['stage'], 'before install 0')
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_apk_changed_during_install_aborts_before_next_install(self):
        def replace(command):
            if 'install' in command:
                (self.root / 'test.apk').write_bytes(b'other bytes')
        self.sdk.on_call = replace
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertEqual(report['apkChangeDetected']['stage'], 'after install 0')
        self.assertEqual(len([c for c in self.sdk.calls if 'install' in c]), 1)
        self.assertFalse(any('instrument' in c for c in self.sdk.calls))
        self.assertTrue(report['apkMetadata'][0]['installed'])
        self.assertFalse(report['apkMetadata'][1]['installed'])

    def test_apk_changed_during_second_install_aborts_matrix(self):
        def replace(command):
            if 'install' in command and command[-1].endswith('test.apk'):
                (self.root / 'app.apk').write_bytes(b'updated')
        self.sdk.on_call = replace
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertEqual(report['apkChangeDetected']['stage'], 'after install 1')
        self.assertFalse(any('instrument' in c for c in self.sdk.calls))

    def test_missing_apk_is_fatal_even_without_git(self):
        (self.root / 'app.apk').unlink()
        code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_snapshot_must_match_original_hash(self):
        def bad_copy(source, target):
            Path(target).write_bytes(b'wrong copy')
        with patch.object(qa.shutil, 'copyfile', side_effect=bad_copy):
            code, report = self.execute()
        self.assertEqual(code, 2)
        self.assertIn('snapshotting', report['error'])
        self.assertFalse(any('install' in c for c in self.sdk.calls))

    def test_background_soak_2400_is_explicit(self):
        code, report = self.execute(['--probes', 'background-soak', '--timeout', '2400'])
        self.assertEqual(code, 0)
        self.assertEqual(report['results'][0]['timeoutSeconds'], 2400)
        deadlines = [timeout for command, timeout in zip(self.sdk.calls, self.sdk.deadlines) if 'instrument' in command]
        self.assertEqual(deadlines, [2400])

    def test_background_soak_default_is_still_240(self):
        code, report = self.execute(['--probes', 'background-soak'])
        self.assertEqual(code, 0)
        self.assertEqual(report['results'][0]['timeoutSeconds'], 240)

    def test_long_deadline_cannot_leak_to_other_probes(self):
        for probes, timeout in [('codex', '2400'), ('background-soak,codex', '2400'),
                                ('background-soak', '2401'), ('background-soak', '0')]:
            with self.subTest(probes=probes, timeout=timeout), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                qa.parse_args(self.argv + ['--probes', probes, '--timeout', timeout])
        self.assertEqual(self.sdk.calls, [])

    def test_zero_cases_defense(self):
        args = qa.parse_args(self.argv)
        args.probes = []
        runner = qa.SessionQA(args)
        self.assertEqual(runner.execute(), 2)
        self.assertEqual(self.sdk.calls, [])

    def test_reject_bad_arguments_without_sdk(self):
        invalid = [('--serial', '123456'), ('--serial', '192.168.1.2:5555'), ('--serial', 'emulator-5554;id'),
                   ('--probes', ''), ('--probes', 'unknown'), ('--probes', 'native-phone-gateway'), ('--probes', 'codex,'),
                   ('--probes', 'codex,codex'), ('--locales', ''), ('--locales', 'zh-TW'),
                   ('--timeout', '0'), ('--timeout', '601')]
        for key, value in invalid:
            with self.subTest(key=key, value=value), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                qa.main(self.argv + [key, value])
            self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.sdk.calls, [])

    def test_missing_serial_and_existing_output_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            qa.parse_args(self.argv[2:])
        (self.root / 'evidence').mkdir()
        sentinel = self.root / 'evidence/keep'
        sentinel.write_text('keep')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(qa.main(self.argv), 2)
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertEqual(self.sdk.calls, [])


if __name__ == '__main__':
    unittest.main()

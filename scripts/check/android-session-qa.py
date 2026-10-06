#!/usr/bin/env python3
"""Run session fixtures on an explicitly selected, already running local API 37 emulator.

Build separately, then pass --app-apk and --test-apk (absolute or relative paths).
No AVD lifecycle, global settings, production packages or implicit data resets.
Exit codes: 0 all passed, 1 case/evidence failure, 2 setup failure, 130 SIGINT,
143 SIGTERM. summary.json records all planned cases, including those not run.
APK snapshots are retained under output/apks for reproducibility. Use
--probes background-soak --timeout 2400 for an explicit long soak run;
all probe deadlines otherwise default to 240 seconds.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = 'io.github.junweiup.vibepier.remote.review'
TEST_PACKAGE = PACKAGE + '.test'
CLASS = 'io.github.junweiup.vibepier.remote.BindingSyncInstrumentation'
RUNNER = TEST_PACKAGE + '/' + CLASS
DEFAULT_PROBES = ('session-response', 'codex', 'providers', 'new-session-receipts',
          'new-session-composer', 'composer', 'codex-panel', 'session-blocker',
          'plan-mode', 'provider-access', 'approval-actions', 'session-cancellation')
PROBES = DEFAULT_PROBES + (
    'agent-open', 'protocol-negotiation', 'relay-framing', 'background-connection',
    'enrollment', 'private-storage', 'conversation-scroll', 'task-notifications',
    'tool-groups', 'conversation-images', 'attachment-upload', 'markdown', 'background-soak', 'video-preview', 'apk',
)
LOCALES = ('en', 'zh-CN')
ANDROID = '{http://schemas.android.com/apk/res/android}'
RUNNER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


class TerminationRequested(BaseException):
    """Keep SIGTERM out of ordinary command/diagnostic exception handlers."""


# Import only the verifier; the original CI-only main/guard remains untouched.
_spec = importlib.util.spec_from_file_location('android_emulator_qa', Path(__file__).with_name('android-emulator.py'))
_ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ci)


def verify_result(returncode, text, probe, locale):
    if probe not in PROBES or locale not in LOCALES:
        raise RuntimeError('Unknown probe or locale')
    _ci.verify_result(returncode, text, probe, locale)
    actual = re.findall(r'^INSTRUMENTATION_RESULT: locale=(.*)$', text, re.M)[0].strip().split(',')[0]
    if actual.replace('_', '-').lower() != locale.lower():
        raise RuntimeError('Requested exact primary app locale was not active')
    streams = re.findall(r'^INSTRUMENTATION_RESULT: stream=(.*)$', text, re.M)
    if not streams[0].strip().startswith('PASS:') or re.search(r'\b(?:OK \(0 tests?\)|INSTRUMENTATION_FAILED|INSTRUMENTATION_ABORTED)', text):
        raise RuntimeError('Missing explicit PASS or zero/aborted test execution')


def csv_choices(value, allowed):
    values = [part.strip() for part in value.split(',')]
    if not values or any(part not in allowed for part in values) or len(set(values)) != len(values):
        raise argparse.ArgumentTypeError('Expected nonempty, unique comma-separated choices: ' + ','.join(allowed))
    return values


def discover_aapt2(sdk):
    """Prefer the newest installed executable build-tools version, without SDK writes."""
    candidates = [path for path in (sdk / 'build-tools').glob('*/aapt2')
                  if path.is_file() and os.access(path, os.X_OK)]
    def version(path):
        numbers = tuple(int(n) for n in re.findall(r'\d+', path.parent.name))
        return numbers, path.parent.name
    return str(max(candidates, key=version)) if candidates else None


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True, help='Explicit emulator-NNNN serial; physical and network serials refused.')
    parser.add_argument('--output', required=True, type=Path, help='New evidence directory (must not exist).')
    parser.add_argument('--app-apk', required=True, type=Path, help='Already built app-designReview.apk.')
    parser.add_argument('--test-apk', required=True, type=Path, help='Already built app-designReview-androidTest.apk.')
    parser.add_argument('--probes', type=lambda s: csv_choices(s, PROBES), default=list(DEFAULT_PROBES),
                        help='Comma-separated allowed probes; defaults to the 12 core session probes.')
    parser.add_argument('--locales', type=lambda s: csv_choices(s, LOCALES), default=list(LOCALES))
    parser.add_argument('--reset-review-data', action='store_true', help='Explicitly clear review app data before each case.')
    parser.add_argument('--timeout', type=int, default=240, help='Instrumentation deadline, 1–600 seconds; up to 2400 only when selecting background-soak alone.')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or Path.home() / 'Library/Android/sdk')
    parser.add_argument('--adb', default=str(sdk / 'platform-tools/adb'))
    manifest_tools = parser.add_mutually_exclusive_group()
    manifest_tools.add_argument('--apkanalyzer', help='Explicit apkanalyzer executable (manifest print).')
    manifest_tools.add_argument('--aapt2', help='Explicit aapt2 executable; defaults to newest installed SDK build-tools/aapt2.')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'emulator-[0-9]+', args.serial):
        parser.error('--serial must explicitly name an emulator-NNNN device')
    maximum = 2400 if args.probes == ['background-soak'] else 600
    if not 1 <= args.timeout <= maximum:
        parser.error('--timeout must be 1–600; 601–2400 requires --probes background-soak alone')
    if not args.aapt2 and not args.apkanalyzer:
        args.aapt2 = discover_aapt2(sdk)
        if not args.aapt2:
            analyzer = sdk / 'cmdline-tools/latest/bin/apkanalyzer'
            if analyzer.is_file() and os.access(analyzer, os.X_OK):
                args.apkanalyzer = str(analyzer)
            else:
                parser.error('No SDK aapt2/apkanalyzer found; provide --aapt2 or --apkanalyzer')
    return args


def raw(value):
    return value.encode() if isinstance(value, str) else value or b''


def run(command, timeout=30):
    return subprocess.run(command, capture_output=True, timeout=timeout, check=False)


def checked(result):
    if result.returncode:
        raise RuntimeError('Command failed (exit {}): {}'.format(result.returncode, raw(result.stderr).decode(errors='replace')[-2000:]))
    return raw(result.stdout).decode(errors='replace').strip()


def validate_manifest(xml, package):
    root = ET.fromstring(xml) if isinstance(xml, str) else xml
    if root.tag != 'manifest' or root.get('package') != package or ANDROID + 'sharedUserId' in root.attrib:
        raise RuntimeError('APK must have the expected isolated review package: ' + package)
    entries = root.findall('instrumentation')
    if len(list(root.iter('instrumentation'))) != len(entries):
        raise RuntimeError('Instrumentation must be a direct manifest child')
    if package == TEST_PACKAGE:
        if len(entries) != 1 or entries[0].get(ANDROID + 'targetPackage') != PACKAGE or entries[0].get(ANDROID + 'name') != CLASS:
            raise RuntimeError('Unexpected instrumentation runner or target package')
    elif entries:
        raise RuntimeError('Review application APK must not declare instrumentation')


def parse_aapt2_manifest(text):
    """Parse aapt2's indented E:/A: tree, not its unrelated strings or Raw hints.

    Real aapt2 uses fully qualified attribute URIs and optional resource IDs:
      E: manifest (line=2)
        A: package="..." (Raw: "...")
          E: instrumentation (line=9)
            A: http://schemas.android.com/apk/res/android:name(0x01010003)="..."
    """
    stack = []
    root = None
    protected_ids = {'0x01010003': ANDROID + 'name',
                     '0x0101000b': ANDROID + 'sharedUserId',
                     '0x01010021': ANDROID + 'targetPackage'}
    for line in text.splitlines():
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(' '))
        content = line[indent:]
        if content.startswith('N: '):
            continue
        element = re.fullmatch(r'E: ([\w.-]+) \(line=\d+\)', content)
        if element:
            while stack and stack[-1][0] >= indent:
                stack.pop()
            node = ET.Element(element[1])
            if stack:
                if indent != stack[-1][0] + 4:
                    raise RuntimeError('Unexpected aapt2 element indentation')
                stack[-1][1].append(node)
            elif root is None:
                root = node
            else:
                raise RuntimeError('Multiple aapt2 manifest roots')
            stack.append((indent, node))
            continue
        attribute = re.fullmatch(r'A: ([^=()]+?)(?:\((0x[0-9a-fA-F]+)\))?=(.*)', content)
        if not attribute or not stack or indent != stack[-1][0] + 2:
            raise RuntimeError('Malformed aapt2 XML tree record: ' + content[:160])
        name, resource_id, value = attribute.groups()
        uri = 'http://schemas.android.com/apk/res/android:'
        if name.startswith(uri):
            name = ANDROID + name[len(uri):]
        if resource_id and resource_id.lower() in protected_ids and name != protected_ids[resource_id.lower()]:
            raise RuntimeError('aapt2 attribute resource ID/name mismatch')
        if name in stack[-1][1].attrib:
            raise RuntimeError('Duplicate aapt2 attribute: ' + name)
        if name in ('package', ANDROID + 'name', ANDROID + 'targetPackage', ANDROID + 'sharedUserId'):
            quoted = re.fullmatch(r'"([^"\\]*)"(?: \(Raw: "([^"\\]*)"\))?', value)
            if not quoted or (quoted[2] is not None and quoted[1] != quoted[2]):
                raise RuntimeError('Expected unambiguous literal manifest identity: ' + name)
            value = quoted[1]
        stack[-1][1].set(name, value)
    if root is None:
        raise RuntimeError('Empty aapt2 XML tree')
    return root


def inspect_apk(args, apk, package):
    if args.aapt2:
        text = checked(run([args.aapt2, 'dump', 'xmltree', str(apk.resolve()), '--file', 'AndroidManifest.xml']))
        validate_manifest(parse_aapt2_manifest(text), package)
    else:
        validate_manifest(checked(run([args.apkanalyzer, 'manifest', 'print', str(apk.resolve())])), package)


def file_identity(path):
    """Hash all bytes and reject replacement or concurrent writes during the read."""
    def signature(st):
        return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    if not path.is_file():
        raise RuntimeError('Expected a regular file: ' + str(path))
    digest = hashlib.sha256()
    size = 0
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            size += len(block)
        after = os.fstat(stream.fileno())
    if signature(before) != signature(after) or signature(after) != signature(path.stat()) or size != after.st_size:
        raise RuntimeError('File changed while hashing: ' + str(path))
    return {'sha256': digest.hexdigest(), 'size': size}, signature(after)


def git_metadata():
    """Only emit hashes; never expose diff bytes or git stderr in the report."""
    prefix = ['git', '--no-pager', '-C', str(Path(__file__).resolve().parents[2])]
    metadata = {'status': 'unavailable', 'head': None, 'diffHeadSha256': None,
                'diffScope': 'git diff --no-ext-diff --no-textconv --binary HEAD -- (tracked files only)'}
    try:
        head = checked(run(prefix + ['rev-parse', 'HEAD']))
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', head):
            raise RuntimeError('Invalid HEAD')
        diff = run(prefix + ['diff', '--no-ext-diff', '--no-textconv', '--binary', 'HEAD', '--'])
        if diff.returncode or checked(run(prefix + ['rev-parse', 'HEAD'])) != head:
            raise RuntimeError('Git diff failed or HEAD changed')
        metadata.update(status='available', head=head, diffHeadSha256=hashlib.sha256(raw(diff.stdout)).hexdigest())
    except Exception:
        pass
    return metadata


class SessionQA:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.safe_device = False
        self.apk_records = []
        self.report = {'serial': args.serial, 'api': 37, 'complete': False, 'passed': False,
                       'exitCode': 2, 'resetReviewData': args.reset_review_data,
                       'apks': [str(args.app_apk.resolve()), str(args.test_apk.resolve())],
                       'apkMetadata': [], 'runnerSha256': RUNNER_SHA256,
                       'results': [{'probe': probe, 'locale': locale, 'status': 'not-run', 'passed': False,
                                    'timeoutSeconds': args.timeout}
                                   for locale in args.locales for probe in args.probes]}
        self.report['plannedCases'] = len(self.report['results'])

    def save(self):
        temporary = self.output / 'summary.json.tmp'
        temporary.write_text(json.dumps(self.report, indent=2) + '\n')
        temporary.replace(self.output / 'summary.json')

    def device(self, *command, timeout=30):
        return run([self.args.adb, '-s', self.args.serial, *command], timeout)

    def preflight(self):
        if not self.report['results']:
            raise RuntimeError('Zero cases are forbidden')
        self.report['git'] = git_metadata()
        # Install private byte-for-byte snapshots, not shared build output paths.
        # Source checks additionally abort if another agent overwrites either APK.
        staging = self.output / 'apks'
        staging.mkdir(mode=0o700)
        for name, apk, package in (('app.apk', self.args.app_apk, PACKAGE),
                                   ('test.apk', self.args.test_apk, TEST_PACKAGE)):
            identity, signature = file_identity(apk)
            snapshot = staging / name
            shutil.copyfile(apk, snapshot)
            snapshot.chmod(0o400)
            if file_identity(snapshot)[0] != identity:
                raise RuntimeError('APK changed while snapshotting: ' + str(apk))
            record = dict(identity, path=str(apk.absolute()), package=package,
                          snapshot=str(snapshot), installed=False)
            self.report['apkMetadata'].append(record)
            self.apk_records.append((apk, snapshot, identity, signature))
        self.save()
        self.check_apks('before manifest validation')
        for record, (_, snapshot, _, _) in zip(self.report['apkMetadata'], self.apk_records):
            inspect_apk(self.args, snapshot, record['package'])
        self.check_apks('after manifest validation')
        if checked(self.device('get-state')) != 'device':
            raise RuntimeError('Explicit emulator is not online/authorized')
        if checked(self.device('shell', 'getprop', 'ro.kernel.qemu')) != '1':
            raise RuntimeError('Refusing non-emulator device')
        if checked(self.device('shell', 'getprop', 'ro.build.version.sdk')) != '37':
            raise RuntimeError('Only API 37 is allowed')
        if checked(self.device('shell', 'getprop', 'sys.boot_completed')) != '1':
            raise RuntimeError('Emulator must already be booted')
        self.safe_device = True
        for index, (_, snapshot, _, _) in enumerate(self.apk_records):
            self.check_apks('before install {}'.format(index))
            try:
                result = self.device('install', '-r', str(snapshot), timeout=120)
                (self.output / ('install-{}.log'.format(index))).write_bytes(raw(result.stdout) + raw(result.stderr))
                if 'Success' not in checked(result).splitlines():
                    raise RuntimeError('APK installation was not confirmed')
                self.report['apkMetadata'][index]['installed'] = True
            finally:
                self.check_apks('after install {}'.format(index))
                self.save()

    def check_apks(self, stage):
        for apk, snapshot, identity, signature in self.apk_records:
            actual, current_signature = file_identity(apk)
            if actual != identity or current_signature != signature or file_identity(snapshot)[0] != identity:
                self.report['apkChangeDetected'] = {'path': str(apk.absolute()), 'stage': stage}
                raise RuntimeError('APK changed ' + stage + ': ' + str(apk))

    def stop(self):
        # Stop the target process hosting instrumentation AND its test package.
        errors = []
        for package in (PACKAGE, TEST_PACKAGE):
            try:
                checked(self.device('shell', 'am', 'force-stop', package, timeout=10))
            except Exception as error:
                errors.append(str(error))
        return errors

    def evidence(self, item, label, failure=False):
        errors = item.setdefault('evidenceErrors', [])

        def capture(suffix, command, timeout=15):
            try:
                result = self.device(*command, timeout=timeout)
                (self.output / (label + suffix)).write_bytes(raw(result.stdout))
                checked(result)
                if suffix.endswith('.png') and not raw(result.stdout).startswith(b'\x89PNG\r\n\x1a\n'):
                    raise RuntimeError('Screenshot is not PNG')
                if suffix.endswith('.xml'):
                    text = raw(result.stdout).decode(errors='replace')
                    start, end = text.find('<hierarchy'), text.rfind('</hierarchy>')
                    if start < 0 or (end < 0 and '<hierarchy/>' not in text):
                        raise RuntimeError('UI hierarchy missing')
                    ET.fromstring(text[start:end + len('</hierarchy>')] if end >= 0 else '<hierarchy/>')
            except Exception as error:
                errors.append(suffix + ': ' + str(error))
        capture('-crash.log', ('logcat', '-d', '-b', 'crash', '-v', 'threadtime', '-t', '200'))
        if failure:
            capture('-failure.png', ('exec-out', 'screencap', '-p'))
            # Never request a second UiAutomation client until instrumentation is stopped.
            stop_errors = self.stop()
            errors.extend(stop_errors)
            if not stop_errors:
                capture('-failure.xml', ('exec-out', 'uiautomator', 'dump', '/dev/tty'), 30)
            else:
                errors.append('UI dump skipped because instrumentation termination was not confirmed')
            capture('-system.log', ('logcat', '-d', '-v', 'threadtime', '-t', '1000'))

    def case(self, item):
        label = item['locale'] + '-' + item['probe']
        started = time.monotonic()
        item['status'] = 'running'
        log = self.output / (label + '.log')
        log.write_bytes(b'')
        self.save()
        try:
            if self.args.reset_review_data:
                if checked(self.device('shell', 'pm', 'clear', PACKAGE)) != 'Success':
                    raise RuntimeError('Review data reset not confirmed')
            checked(self.device('shell', 'cmd', 'locale', 'set-app-locales', PACKAGE, '--locales', item['locale']))
            result = self.device('shell', 'am', 'instrument', '-w', '-r', '-e', 'test', item['probe'], RUNNER, timeout=self.args.timeout)
            text = (raw(result.stdout) + raw(result.stderr)).decode(errors='replace')
            log.write_text(text)
            item['instrumentationExitCode'] = result.returncode
            verify_result(result.returncode, text, item['probe'], item['locale'])
            item.update(status='passed', passed=True)
        except (KeyboardInterrupt, TerminationRequested) as error:
            item.update(status='interrupted', error=str(error))
            raise
        except Exception as error:
            item.update(status='timeout' if isinstance(error, subprocess.TimeoutExpired) else 'failed', error=str(error))
            if isinstance(error, subprocess.TimeoutExpired):
                log.write_bytes(raw(error.stdout) + raw(error.stderr))
            else:
                with log.open('a') as stream:
                    stream.write('\nERROR: ' + str(error) + '\n')
        finally:
            try:
                self.evidence(item, label, failure=not item['passed'])
            except (KeyboardInterrupt, TerminationRequested) as error:
                item.update(passed=False, status='interrupted', error=str(error))
                raise
            if item.get('evidenceErrors'):
                item.update(passed=False, status='failed' if item['status'] == 'passed' else item['status'])
            item['durationSeconds'] = round(time.monotonic() - started, 3)
            self.save()
        print('{} {}'.format(item['status'].upper(), label), flush=True)

    def execute(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.save()
        try:
            self.preflight()
            for item in self.report['results']:
                self.case(item)
            self.report['complete'] = True
            self.report['passed'] = all(item['passed'] for item in self.report['results'])
            self.report['exitCode'] = 0 if self.report['passed'] else 1
        except KeyboardInterrupt:
            self.report.update(exitCode=130, error='Interrupted (SIGINT)')
        except TerminationRequested:
            self.report.update(exitCode=143, error='Interrupted (SIGTERM)')
        except Exception as error:
            self.report.update(exitCode=2, error=str(error))
        finally:
            if self.safe_device:
                errors = self.stop()
                if errors:
                    self.report['cleanupErrors'] = errors
                    self.report['passed'] = False
                    if self.report['exitCode'] == 0:
                        self.report['exitCode'] = 1
            self.save()
        return self.report['exitCode']


def main(argv=None):
    args = parse_args(argv)

    def terminated(signum, frame):
        raise TerminationRequested('SIGTERM')

    previous = signal.signal(signal.SIGTERM, terminated)
    try:
        return SessionQA(args).execute()
    except OSError as error:
        print('Cannot create/write evidence: ' + str(error))
        return 2
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    raise SystemExit(main())

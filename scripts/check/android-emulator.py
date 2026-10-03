#!/usr/bin/env python3
"""Run explicit, disposable GitHub-runner Android API checks; never target a physical phone."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def verify_result(returncode, text, probe, locale):
    codes = re.findall(r'^INSTRUMENTATION_CODE: (-?\d+)\s*$', text, re.M)
    names = re.findall(r'^INSTRUMENTATION_RESULT: probe=(.*)$', text, re.M)
    locales = re.findall(r'^INSTRUMENTATION_RESULT: locale=(.*)$', text, re.M)
    streams = re.findall(r'^INSTRUMENTATION_RESULT: stream=(.*)$', text, re.M)
    if returncode != 0 or codes != ['-1']:
        raise RuntimeError('Instrumentation did not report exactly one successful result')
    if [name.strip() for name in names] != [probe]:
        raise RuntimeError('Instrumentation ran a different/unknown probe')
    if len(locales) != 1 or not locales[0].lower().startswith(locale.split('-')[0].lower()):
        raise RuntimeError('Requested app language was not active')
    if len(streams) != 1 or not streams[0].strip() or 'FAIL:' in text:
        raise RuntimeError('Missing or failed explicit probe result')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api', type=int, choices=(33, 35, 36), required=True)
    parser.add_argument('--suite', choices=('smoke', 'full'), default='smoke')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_OS') != 'Linux':
        raise SystemExit('This destructive fixture reset is restricted to an ephemeral Linux GitHub runner.')
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sdk = Path(os.environ['ANDROID_HOME'])
    adb = str(sdk / 'platform-tools/adb')
    emulator = str(sdk / 'emulator/emulator')
    avdmanager = str(sdk / 'cmdline-tools/latest/bin/avdmanager')
    serial = 'emulator-5554'
    package = 'io.github.junweiup.vibepier.remote.review'
    runner = package + '.test/io.github.junweiup.vibepier.remote.BindingSyncInstrumentation'
    avd = 'VibePier_API_' + str(args.api)
    image = 'system-images;android-{};google_apis;x86_64'.format(args.api)
    avd_state = tempfile.TemporaryDirectory(prefix='vibepier-api-{}-'.format(args.api), dir=os.environ.get('RUNNER_TEMP'))
    state_root = Path(avd_state.name)
    avd_root = state_root / 'avd'
    user_root = state_root / 'user'
    avd_root.mkdir(); user_root.mkdir()
    # New emulator releases and older avdmanager versions have different default homes.
    # Pin all SDK user/AVD paths to one task-owned directory outside uploaded evidence.
    task_env = dict(os.environ, ANDROID_AVD_HOME=str(avd_root), ANDROID_USER_HOME=str(user_root),
                    ANDROID_EMULATOR_HOME=str(user_root))

    def run(command, timeout=60, check=True, **kwargs):
        try:
            return subprocess.run(command, timeout=timeout, check=check, capture_output=True, env=task_env, **kwargs)
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or error.stdout or b'')
            if isinstance(detail, bytes):
                detail = detail.decode('utf-8', errors='replace')
            raise RuntimeError(str(error) + '\n' + detail[-8000:]) from error

    def device(*command, timeout=60, check=True):
        return run([adb, '-s', serial, *command], timeout=timeout, check=check)

    devices = run([adb, 'devices'], text=True).stdout
    if any(line.strip() for line in devices.splitlines()[1:]):
        raise SystemExit('Runner already has an ADB device; refusing to share or reset it.')
    # Build has finished. Free its daemon heap before booting the full Android UI.
    run([str(root / 'apps/android/gradlew'), '-p', str(root / 'apps/android'), '--stop'], timeout=60)
    run([avdmanager, 'create', 'avd', '--name', avd, '--package', image, '--device', 'pixel_2'],
        input='no\n', text=True, timeout=120)
    available = run([emulator, '-list-avds'], text=True).stdout.splitlines()
    if avd not in available or not (avd_root / (avd + '.ini')).is_file():
        raise RuntimeError('AVD creation and emulator discovery disagree: ' + repr(available))
    log = (output / 'emulator.log').open('wb')
    process = subprocess.Popen([emulator, '-avd', avd, '-port', '5554', '-no-window', '-no-snapshot',
        '-no-boot-anim', '-no-audio', '-no-metrics', '-gpu', 'swiftshader', '-accel', 'on',
        '-memory', '3072'],
        stdout=log, stderr=subprocess.STDOUT, env=task_env)
    results = []
    report = {'api': args.api, 'suite': args.suite, 'serial': serial, 'image': image,
              'commit': run(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).stdout.strip(),
              'scope': 'Review fixtures, real Android Keystore and encrypted loopback hosts; no real Mac or phone.',
              'results': results}
    try:
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Emulator exited before boot; see emulator.log')
            boot_state = device('shell', 'getprop', 'sys.boot_completed', timeout=10, check=False)
            if boot_state.returncode == 0 and boot_state.stdout.strip() == b'1':
                break
            time.sleep(2)
        else:
            raise RuntimeError('Emulator did not boot before its deadline')
        actual = device('shell', 'getprop', 'ro.build.version.sdk').stdout.decode().strip()
        model = device('shell', 'getprop', 'ro.product.model').stdout.decode().strip()
        if actual != str(args.api) or 'sdk' not in model.lower():
            raise RuntimeError('Unexpected emulator identity/API: ' + actual + ' / ' + model)
        report['model'] = model
        device('shell', 'input', 'keyevent', '82')
        for key in ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale'):
            device('shell', 'settings', 'put', 'global', key, '0')
        for apk in [root / 'apps/android/app/build/outputs/apk/designReview/app-designReview.apk',
                    root / 'apps/android/app/build/outputs/apk/androidTest/designReview/app-designReview-androidTest.apk']:
            installed = device('install', '-r', '-g', str(apk), timeout=120)
            if b'Success' not in installed.stdout:
                raise RuntimeError('APK installation not confirmed')
        probes = ['codec-compatibility', 'brand-icons', 'binding-sync', 'private-storage', 'enrollment', 'relay-store', 'relay-framing',
                  'protocol-negotiation', 'session-response', 'codex', 'providers', 'new-session-receipts', 'new-session-composer',
                  'screen-controls', 'codex-usage', 'application-picker', 'composer', 'codex-panel', 'markdown', 'tool-groups',
                  'conversation-images', 'controls-localization', 'controls', 'dock', 'app-usage',
                  'background-connection', 'microphone', 'apk']
        cases = [('en', name, 'normal') for name in probes]
        if args.api >= 33:
            cases += [('zh-CN', name, 'normal') for name in
                      ['protocol-negotiation', 'session-response', 'codex', 'providers', 'new-session-receipts', 'new-session-composer', 'screen-controls', 'codex-usage', 'application-picker']]
        cases += [('en', name, 'small-large-type') for name in ['controls-localization', 'screen-controls', 'codex-usage', 'application-picker', 'composer', 'new-session-composer', 'app-usage']]
        if args.suite == 'smoke':
            cases = [('en', name, 'normal') for name in
                     ['relay-framing', 'protocol-negotiation', 'session-response', 'codex',
                      'new-session-composer', 'new-session-receipts']]
            cases += [('zh-CN', 'new-session-composer', 'small-large-type')]
        report['plannedCases'] = len(cases)
        report['complete'] = False
        for locale, name, layout in cases:
            label = '{}-{}-{}'.format(locale, layout, name)
            item = {'probe': name, 'locale': locale, 'layout': layout, 'passed': False}
            results.append(item)
            try:
                if device('shell', 'pm', 'clear', package).stdout.strip() != b'Success':
                    raise RuntimeError('Disposable review data reset was not confirmed')
                device('shell', 'wm', 'size', '640x1280' if layout == 'small-large-type' else '1080x1920')
                device('shell', 'wm', 'density', '320' if layout == 'small-large-type' else '420')
                device('shell', 'settings', 'put', 'system', 'font_scale', '1.5' if layout == 'small-large-type' else '1.0')
                if args.api >= 33:
                    device('shell', 'cmd', 'locale', 'set-app-locales', package, '--locales', locale)
                permissions = ['android.permission.RECORD_AUDIO']
                permissions += ['android.permission.BLUETOOTH_CONNECT', 'android.permission.BLUETOOTH_SCAN'] if args.api >= 31 else ['android.permission.ACCESS_FINE_LOCATION']
                for permission in permissions:
                    device('shell', 'pm', 'grant', package, permission)
                if name == 'apk':
                    device('shell', 'appops', 'set', package, 'REQUEST_INSTALL_PACKAGES', 'allow')
                cleared = device('logcat', '-c', check=False)
                if cleared.returncode != 0:
                    (output / (label + '-logcat-clear.log')).write_bytes(cleared.stdout + cleared.stderr)
                result = device('shell', 'am', 'instrument', '-w', '-r', '-e', 'test', name, runner, timeout=240, check=False)
                text = (result.stdout + result.stderr).decode('utf-8', errors='replace')
                (output / (label + '.log')).write_text(text)
                if name == 'controls-localization':
                    # The probe closes its dialogs during cleanup; a later screencap cannot show
                    # their failing geometry. Retrieve the snapshots made before each assertion.
                    for language in ('en', 'zh_CN'):
                        for width in (320, 400):
                            for scale in ('1.0', '1.5'):
                                for position in ('controls', 'controls-bottom'):
                                    filename = '{}-{}-{}-{}.png'.format(position, language, width, scale)
                                    pixels = device('exec-out', 'run-as', package, 'cat', 'files/' + filename, check=False).stdout
                                    if pixels.startswith(b'\x89PNG\r\n\x1a\n'):
                                        (output / (label + '-' + filename)).write_bytes(pixels)
                verify_result(result.returncode, text, name, locale)
                if name == 'screen-controls':
                    screenshot = '/sdcard/Android/data/' + package + '/cache/screen-controls-menu.png'
                    pixels = device('exec-out', 'cat', screenshot).stdout
                    if not pixels.startswith(b'\x89PNG\r\n\x1a\n'):
                        raise RuntimeError('Menu screenshot missing')
                    (output / (label + '.png')).write_bytes(pixels)
                item['passed'] = True
                print('PASS ' + label, flush=True)
            except Exception as error:
                item['error'] = str(error)
                if isinstance(error, subprocess.TimeoutExpired):
                    (output / (label + '.log')).write_bytes((error.stdout or b'') + (error.stderr or b''))
                print('FAIL ' + label + ': ' + str(error), flush=True)
                for description, command in [
                    ('system-log', ('logcat', '-d', '-v', 'threadtime')),
                    ('last-anr', ('shell', 'dumpsys', 'activity', 'lastanr')),
                ]:
                    try:
                        (output / (label + '-' + description + '.log')).write_bytes(device(*command, timeout=20, check=False).stdout)
                    except subprocess.TimeoutExpired:
                        pass
                pixels = device('exec-out', 'screencap', '-p', check=False).stdout
                if pixels.startswith(b'\x89PNG\r\n\x1a\n'):
                    (output / (label + '-failure.png')).write_bytes(pixels)
                # Stop any timed-out instrumentation before asking another UiAutomation client for a tree.
                device('shell', 'am', 'force-stop', package, check=False)
                tree = device('exec-out', 'uiautomator', 'dump', '/dev/tty', timeout=30, check=False).stdout
                (output / (label + '-failure.xml')).write_bytes(tree)
            finally:
                logs = device('logcat', '-d', '-b', 'crash', check=False).stdout
                (output / (label + '-crash.log')).write_bytes(logs)
                device('shell', 'pm', 'uninstall', 'io.github.junweiup.vibepier.installprobe', check=False)
                (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        if not all(item['passed'] for item in results):
            raise RuntimeError('One or more Android API checks failed; inspect uploaded evidence')
        report['complete'] = True
    finally:
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        try:
            device('emu', 'kill', check=False, timeout=15)
        except subprocess.TimeoutExpired:
            pass
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        log.close()
        avd_state.cleanup()


if __name__ == '__main__':
    main()

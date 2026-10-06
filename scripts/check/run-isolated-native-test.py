#!/usr/bin/env python3
"""Run only the dedicated native test source against already-built Core objects."""
import argparse
import os
from pathlib import Path
import plistlib
import signal
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opt-in-native', action='store_true', required=True)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--phase', choices=['registered-options', 'claude-followup', 'codex-approval', 'codex-deny', 'codex-allow', 'claude-approval', 'reply-evidence'], required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    run = args.run.resolve()
    if run.parent != root / '.local' or not run.name.startswith('native-lifecycle-'):
        parser.error('Expected a dedicated run directory under this repository .local')
    products = root / 'apps/macos/.build/out/Products/Debug'
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    bundle = run / 'NativeAcceptance.xctest'
    binary = bundle / 'Contents/MacOS/NativeAcceptance'
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'NativeAcceptance', '-enable-testing',
        '-I', str(products), '-F', str(platform/'Library/Frameworks'), '-I', str(platform/'usr/lib'),
        '-L', str(platform/'usr/lib')]
    for framework in ['XCTest', 'AppKit', 'CoreBluetooth', 'ApplicationServices', 'IOKit', 'Security']:
        command += ['-framework', framework]
    command += ['-lsqlite3', '-Xlinker', '-bundle']
    for directory in [platform/'Library/Frameworks', platform/'usr/lib']:
        command += ['-Xlinker', '-rpath', '-Xlinker', str(directory)]
    command += ['-o', str(binary), str(root/'apps/macos/Tests/VibePierCoreTests/NativeAdapterAcceptanceTests.swift')]
    command += [str(products/(name+'.o')) for name in ['VibePierCore', 'VibeKit', 'VibeLocalization']]
    subprocess.run(command, check=True, timeout=90)
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'vibepier.native-acceptance', 'CFBundleExecutable': 'NativeAcceptance',
        'CFBundlePackageType': 'BNDL'}))
    env = dict(os.environ, VIBEPIER_NATIVE_ACCEPTANCE='1', VIBEPIER_NATIVE_LIFECYCLE='1', VIBEPIER_NATIVE_RUN=str(run))
    for key in ['VIBEPIER_NATIVE_DEFINITIVE_RETRY', 'VIBEPIER_NATIVE_CLAUDE_FOLLOWUP']:
        env.pop(key, None)
    if args.phase == 'registered-options':
        test = 'testRegisteredWorkspacePreflight'
    elif args.phase == 'claude-followup':
        test = 'testDedicatedNativeLifecycle'
        env.update(VIBEPIER_NATIVE_PROVIDER='claude', VIBEPIER_NATIVE_CLAUDE_FOLLOWUP='1')
    elif args.phase == 'claude-approval':
        test = 'testClaudeNativeApproval'
        env['VIBEPIER_NATIVE_PROVIDER'] = 'claude'
    elif args.phase == 'reply-evidence':
        test = 'testNativeReplyEvidence'
    elif args.phase in ['codex-deny', 'codex-allow']:
        test = 'testNativeApprovalDecisions'
        env.update(VIBEPIER_NATIVE_PROVIDER='codex', VIBEPIER_NATIVE_DECISION=args.phase.removeprefix('codex-'))
    else:
        test = 'testHarmlessNativeApproval'
        env['VIBEPIER_NATIVE_PROVIDER'] = 'codex'
    process = subprocess.Popen(['xcrun', 'xctest', '-XCTest',
        'NativeAcceptance.NativeAdapterAcceptanceTests/'+test, str(bundle)], env=env, start_new_session=True)
    try:
        code = process.wait(timeout=180)
    except subprocess.TimeoutExpired:
        code = 124
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    print('ISOLATED_NATIVE_EXIT='+str(code))
    return code


if __name__ == '__main__':
    raise SystemExit(main())

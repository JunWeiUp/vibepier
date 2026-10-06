#!/usr/bin/env python3
"""Create dedicated native fixtures once; never resume/retry an uncertain mutation."""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
CODEX = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'


def save(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as out:
        json.dump(value, out, indent=2)


def stop(process):
    # All callers start a new session: clean up only this test's process group,
    # including a CLI child still running after XCTest itself has already exited.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
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


class RPC:
    def __init__(self, workspace):
        self.process = subprocess.Popen([CODEX, 'app-server', '--listen', 'stdio://'],
            cwd=workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True)
        self.buffer = b''
        self.sequence = 0
        self.deadline = time.monotonic() + 60

    def call(self, method, params):
        self.sequence += 1
        self.process.stdin.write((json.dumps(dict(id=self.sequence, method=method, params=params))+'\n').encode())
        self.process.stdin.flush()
        received = 0
        while time.monotonic() < self.deadline:
            if b'\n' not in self.buffer:
                if not select.select([self.process.stdout], [], [], max(0, self.deadline-time.monotonic()))[0]:
                    break
                data = os.read(self.process.stdout.fileno(), 65536)
                received += len(data)
                if not data or received > 8*1024*1024:
                    raise RuntimeError('native_transport_limit')
                self.buffer += data
                continue
            line, self.buffer = self.buffer.split(b'\n', 1)
            value = json.loads(line)
            if value.get('id') == self.sequence:
                if 'error' in value:
                    raise RuntimeError('native_rpc_rejected')
                return value['result']
        raise TimeoutError('native_unknown_timeout')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opt-in-native', action='store_true', required=True)
    args = parser.parse_args()
    run = REPO / '.local' / ('native-lifecycle-' + str(uuid.uuid4()))
    run.mkdir(mode=0o700)
    workspace = run / 'workspace'
    workspace.mkdir(mode=0o700)
    save(run/'manifest.json', {'workspace': str(workspace), 'purpose': 'dedicated-native-acceptance'})
    result = {}
    rpc = RPC(workspace)
    try:
        rpc.call('initialize', {'clientInfo': {'name': 'vibepier', 'version': '1'},
            'capabilities': {'experimentalApi': True, 'explicitGatewayOauth': True}})
        save(run/'codex-bootstrap-attempt.json', {'attempted': True})
        project = rpc.call('project/create', {'idempotencyKey': str(uuid.uuid4()),
            'name': 'VibePier acceptance '+run.name[-8:], 'roots': [{'path': str(workspace)}]})['project']['id']
        save(run/'codex-project.json', {'projectId': project})
        thread = rpc.call('thread/start', {'cwd': str(workspace), 'projectId': project,
            'runtimeWorkspaceRoots': [str(workspace)], 'ephemeral': False,
            'experimentalRawEvents': False, 'allowProviderModelFallback': False,
            'model': 'gpt-6.1-sol', 'permissions': ':workspace',
            'approvalPolicy': 'on-request', 'approvalsReviewer': 'user'})['thread']
        assert thread['cwd'] == str(workspace) and thread['projectId'] == project
        save(run/'codex-bootstrap-thread.json', {'threadId': thread['id']})
        rpc.call('thread/name/set', {'threadId': thread['id'], 'name': 'VibePier acceptance bootstrap'})
        rpc.call('thread/archive', {'threadId': thread['id']})
        rpc.call('thread/unarchive', {'threadId': thread['id']})
        result['codexBootstrap'] = 'native_project_and_empty_thread_created'
    except Exception as error:
        result['codexBootstrap'] = type(error).__name__ + ':unknown_or_rejected_no_retry'
    finally:
        stop(rpc.process)
    save(run/'result.json', result)
    print(json.dumps(result), flush=True)

    session = str(uuid.uuid4())
    save(run/'claude-bootstrap-attempt.json', {'sessionId': session, 'attempted': True})
    process = subprocess.Popen(['/opt/homebrew/bin/claude', '-p', '--session-id', session,
        '--permission-mode', 'default', '--tools', '', '--output-format', 'json',
        'Dedicated VibePier acceptance bootstrap. Reply READY only. Do not use tools.'],
        cwd=workspace, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        # Bounded output; never print model text, helper output or raw errors.
        output = b''
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if not select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                raise TimeoutError()
            data = os.read(process.stdout.fileno(), 65536)
            if not data:
                break
            output += data
            if len(output) > 8*1024*1024:
                raise RuntimeError()
        else:
            raise TimeoutError()
        reply = json.loads(output)
        valid = reply.get('session_id') == session and reply.get('is_error') is False
        result['claudeBootstrap'] = 'native_session_created' if valid else 'native_result_failed_no_retry'
    except Exception as error:
        result['claudeBootstrap'] = type(error).__name__ + ':unknown_no_retry'
    finally:
        stop(process)
    save(run/'result.json', result)
    print(json.dumps(result), flush=True)
    print('NATIVE_RUN_DIRECTORY='+str(run), flush=True)
    for provider in ['codex', 'claude']:
        if not result.get(provider+'Bootstrap', '').startswith('native_') or 'failed' in result[provider+'Bootstrap']:
            continue
        env = dict(os.environ, VIBEPIER_NATIVE_ACCEPTANCE='1', VIBEPIER_NATIVE_LIFECYCLE='1',
            VIBEPIER_NATIVE_RUN=str(run), VIBEPIER_NATIVE_PROVIDER=provider)
        env.pop('VIBEPIER_NATIVE_DEFINITIVE_RETRY', None)
        process = subprocess.Popen(['swift', 'test', '--package-path', str(REPO/'apps/macos'),
            '--filter', 'NativeAdapterAcceptanceTests/testDedicatedNativeLifecycle'],
            cwd=REPO, env=env, start_new_session=True)
        try:
            result[provider+'LifecycleExit'] = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            result[provider+'LifecycleExit'] = 'unknown_timeout_no_retry'
        finally:
            stop(process)
        save(run/'result.json', result)
    return 0 if all(result.get(p+'LifecycleExit') == 0 for p in ['codex', 'claude']) else 1


if __name__ == '__main__':
    raise SystemExit(main())

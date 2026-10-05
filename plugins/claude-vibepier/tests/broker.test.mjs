import assert from 'node:assert/strict';
import { test } from 'node:test';
import { webcrypto } from 'node:crypto';
import { register } from '../hooks/register.js';
globalThis.crypto ??= webcrypto;

function harness({ version = '2.1.287', writes = true, command = null } = {}) {
  const hooks = new Map(); let poll; let submits = 0; let aborts = 0; let currentSession = 'session-a';
  let nextCommand = command; const store = new Map(); const calls = [];
  const binding = { endpoint: 'http://127.0.0.1:45678', token: 'a'.repeat(44), sessionID: currentSession,
    cwd: '/tmp/project', runtimeVersion: version, contractDigest: 'b'.repeat(64), expiresAt: 600 };
  const $ = {
    session: { id: async () => currentSession, cwd: async () => '/tmp/project', version: async () => ({ version }), messages: async () => [] },
    env: { get: async () => '/tmp/private-binding.json' }, fs: { read: async () => JSON.stringify(binding) },
    clock: { now: async () => 1000, every: async (_, callback) => { poll = callback; return { cancel() {} }; } },
    store: { keys: async () => [...store.keys()], get: async key => store.get(key), set: async (key, value) => store.set(key, structuredClone(value)) },
    prompt: { submit: async () => { submits++; } }, turn: { abort: async () => { aborts++; } },
    http: { fetch: async (url, init) => {
      const body = JSON.parse(init.body); calls.push({ url, body });
      let response = {};
      if (url.endsWith('/v1/register')) response = { ownershipEpoch: 'epoch-a', writesVerified: writes };
      if (url.endsWith('/v1/poll')) {
        response = { command: nextCommand ? { ...nextCommand, instanceID: body.instanceID, ownershipEpoch: 'epoch-a' } : null };
        nextCommand = null;
      }
      return { ok: true, text: JSON.stringify(response) };
    } },
  };
  register((name, matcher, hook) => { hooks.set(name, typeof matcher === 'function' ? matcher : hook); });
  const fire = (name, event = {}) => hooks.get(name)($, event, async e => e);
  return { $, fire, poll: () => poll?.(), store, calls, counts: () => ({ submits, aborts }),
    switchSession: () => { currentSession = 'session-b'; }, resend: c => { nextCommand = c; } };
}
const submit = { action: 'submit', operationID: 'op-a', operationKey: 'c'.repeat(64), fingerprint: 'd'.repeat(64),
  sessionID: 'session-a', text: 'synthetic test only' };

test('unsupported engine stays disconnected and never submits', async () => {
  const h = harness({ version: '2.1.283', command: submit });
  await h.fire('session.start'); await h.poll();
  assert.equal(h.calls.length, 0); assert.equal(h.counts().submits, 0);
});
test('read only binding and unverified idle cannot submit', async () => {
  for (const writes of [false, true]) {
    const h = harness({ writes, command: submit }); await h.fire('session.start'); await h.poll();
    assert.equal(h.counts().submits, 0);
  }
});
test('persistent reservation precedes one native call and duplicate does not submit', async () => {
  const h = harness({ command: submit }); await h.fire('session.start');
  await h.fire('ui.render', { props: { isWorking: false } }); await h.poll();
  assert.equal(h.counts().submits, 1); assert.equal(h.store.size, 1);
  assert.equal([...h.store.values()][0].status, 'unknown');
  assert.equal(h.calls.filter(c => c.url.endsWith('/v1/result')).length, 1);
  h.resend(submit); await h.poll(); assert.equal(h.counts().submits, 1);
});
test('changed native session invalidates outstanding commands', async () => {
  const h = harness({ command: submit }); await h.fire('session.start');
  await h.fire('ui.render', { props: { isWorking: false } }); h.switchSession(); await h.poll();
  assert.equal(h.counts().submits, 0); assert.equal(h.store.size, 0);
});
test('exact native turn ID is required for interrupt', async () => {
  for (const turnID of ['wrong-turn', 'turn-a']) {
    const h = harness({ command: { ...submit, action: 'interrupt', turnID } });
    await h.fire('session.start'); await h.fire('turn.start', { turnId: 'turn-a', text: 'test' }); await h.poll();
    assert.equal(h.counts().aborts, turnID === 'turn-a' ? 1 : 0);
  }
});
test('store failure prevents a native side effect', async () => {
  const h = harness({ command: submit }); h.$.store.set = async () => { throw new Error('synthetic write failure'); };
  await h.fire('session.start'); await h.fire('ui.render', { props: { isWorking: false } }); await h.poll();
  assert.equal(h.counts().submits, 0);
});
test('event overflow emits bounded resync without unbounded native bodies', async () => {
  const h = harness(); await h.fire('session.start');
  for (let i = 0; i < 40; i++) await h.fire('session.append', { text: 'x'.repeat(10000) });
  await h.poll();
  const batches = h.calls.filter(c => c.url.endsWith('/v1/events')).map(c => c.body.events);
  assert.ok(batches.flat().some(e => e.method === 'resync'));
  assert.ok(batches.every(b => b.length <= 32));
});

// Read against the target engine's generated Mods types before enabling writes.
// No token, provider credentials, arbitrary process or shell action lives here.
const MAX_BODY = 280000;
const MAX_EVENTS = 32;
const MAX_OPERATIONS = 2048;

function bytes(value) { return new TextEncoder().encode(JSON.stringify(value)).length; }
function validID(value) { return typeof value === 'string' && value.length > 0 && value.length <= 256 && !value.includes('\0'); }
function versionAllowed(version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) return false;
  const [major, minor, patch] = version.split('.').map(Number);
  return major > 2 || (major === 2 && (minor > 1 || (minor === 1 && patch >= 287)));
}
async function digest(value) {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(hash)].map(v => v.toString(16).padStart(2, '0')).join('');
}
async function identity($) {
  const sessionID = await $.session.id();
  const cwd = await $.session.cwd();
  const runtimeVersion = (await $.session.version()).version;
  return { sessionID, cwd, runtimeVersion };
}
async function request($, state, path, extra = {}) {
  const payload = { sessionID: state.binding.sessionID, instanceID: state.instanceID,
    ownershipEpoch: state.epoch, ...extra };
  if (bytes(payload) > MAX_BODY) throw new Error('VibePier broker payload limit');
  const response = await $.http.fetch(state.binding.endpoint + path, {
    method: 'POST', headers: { Authorization: 'Bearer ' + state.binding.token, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!response.ok || typeof response.text !== 'string' || response.text.length > MAX_BODY) {
    throw new Error('VibePier broker unavailable');
  }
  return JSON.parse(response.text);
}
async function sameSession($, state) {
  const current = await identity($);
  return current.sessionID === state.binding.sessionID && current.cwd === state.binding.cwd
    && current.runtimeVersion === state.binding.runtimeVersion && versionAllowed(current.runtimeVersion);
}
async function queueEvent($, state, method, payload) {
  if (!state.binding || !state.epoch || !(await sameSession($, state))) return;
  const event = { method, payload };
  if (bytes(event) > MAX_BODY || state.events.length >= MAX_EVENTS || bytes([...state.events, event]) > MAX_BODY - 2048) {
    state.events = [{ method: 'resync', payload: { reason: 'event_budget' } }];
  } else { state.events.push(event); }
}
async function reserve($, state, command) {
  if (!/^[a-f0-9]{64}$/.test(command.operationKey) || !/^[a-f0-9]{64}$/.test(command.fingerprint)) return false;
  const key = 'vibepier.operation.' + command.operationKey;
  const commandHash = await digest(command);
  const prior = await $.store.get(key);
  if (prior !== undefined) return false; // unknown/confirmed/conflict all prevent another execution
  const keys = await $.store.keys();
  if (keys.filter(k => k.startsWith('vibepier.operation.')).length >= MAX_OPERATIONS) return false;
  const record = { fingerprint: command.fingerprint, commandHash, sessionID: state.binding.sessionID,
    instanceID: state.instanceID, ownershipEpoch: state.epoch, status: 'unknown' };
  await $.store.set(key, record);
  const saved = await $.store.get(key);
  return saved?.fingerprint === record.fingerprint && saved?.commandHash === commandHash
    && saved?.instanceID === state.instanceID && saved?.ownershipEpoch === state.epoch;
}
async function execute($, state, command) {
  if (!state.writesVerified || !validID(command.operationID) || command.sessionID !== state.binding.sessionID
    || command.instanceID !== state.instanceID || command.ownershipEpoch !== state.epoch
    || !['submit', 'interrupt'].includes(command.action) || !(await sameSession($, state))) return;
  if (command.action === 'submit' && (typeof command.text !== 'string' || !command.text.trim()
    || new TextEncoder().encode(command.text).length > 240000 || !state.idleVerified || state.activeTurnID !== null)) return;
  if (command.action === 'interrupt' && (!validID(command.turnID) || command.turnID !== state.activeTurnID)) return;
  if (!(await reserve($, state, command)) || !(await sameSession($, state))) return;
  // Recheck after asynchronous durable reservation. Never retry an attempted API.
  if (command.action === 'submit') {
    if (!state.idleVerified || state.activeTurnID !== null) return;
    await $.prompt.submit({ text: command.text, asUser: true });
  } else {
    if (command.turnID !== state.activeTurnID) return;
    await $.turn.abort({ turnId: command.turnID });
  }
  await request($, state, '/v1/result', { operationKey: command.operationKey,
    fingerprint: command.fingerprint, nativeTurnID: state.activeTurnID });
  // ACK is intentionally unknown. Only Mac's independent native evidence reader
  // can promote it; session.append is before persistence, messages() has no IDs.
}
async function snapshot($, state) {
  const messages = await $.session.messages();
  if (!Array.isArray(messages)) return;
  const bounded = messages.slice(-64);
  while (bounded.length > 0 && bytes(bounded) > MAX_BODY - 4096) bounded.shift();
  await queueEvent($, state, 'session.snapshot', { messages: bounded, partial: true,
    activeTurnID: state.activeTurnID, idleVerified: state.idleVerified });
}
async function poll($, state) {
  if (state.busy || !state.binding || !state.epoch || state.ended) return;
  state.busy = true;
  try {
    if (!(await sameSession($, state)) || await $.clock.now() >= state.binding.expiresAt * 1000) {
      state.ended = true; state.timer?.cancel(); return;
    }
    if (state.events.length) {
      const batch = state.events.splice(0, MAX_EVENTS);
      await request($, state, '/v1/events', { events: batch });
    }
    const response = await request($, state, '/v1/poll', { idle: state.idleVerified, activeTurnID: state.activeTurnID });
    if (response.command) await execute($, state, response.command);
  } catch {
    // Failures do not resend a consumed command or expose token/body to logs.
    state.events = [{ method: 'resync', payload: { reason: 'broker_unavailable' } }];
  } finally { state.busy = false; }
}
async function begin($, state) {
  const path = await $.env.get('VIBEPIER_MODS_BINDING_FILE');
  if (typeof path !== 'string' || !path.startsWith('/')) return;
  const text = await $.fs.read(path);
  if (typeof text !== 'string' || text.length > 8192) return;
  const binding = JSON.parse(text);
  const endpoint = new URL(binding.endpoint);
  if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port
    || endpoint.pathname !== '/' || endpoint.username || endpoint.password || endpoint.search || endpoint.hash
    || !validID(binding.sessionID) || typeof binding.token !== 'string' || binding.token.length < 40
    || !/^[a-f0-9]{64}$/.test(binding.contractDigest) || !versionAllowed(binding.runtimeVersion)
    || typeof binding.expiresAt !== 'number' || await $.clock.now() >= binding.expiresAt * 1000) return;
  state.binding = binding;
  if (!(await sameSession($, state))) { state.binding = null; return; }
  const registered = await request($, state, '/v1/register', { cwd: binding.cwd,
    runtimeVersion: binding.runtimeVersion, contractDigest: binding.contractDigest });
  if (!validID(registered.ownershipEpoch)) { state.binding = null; return; }
  state.epoch = registered.ownershipEpoch;
  state.writesVerified = registered.writesVerified === true;
  await snapshot($, state);
  state.timer = await $.clock.every(1000, async () => poll($, state));
}

export function register(on) {
  // An instance changes at every reload. Persistent operation reservations do not.
  const state = { instanceID: crypto.randomUUID(), binding: null, epoch: null, timer: null,
    activeTurnID: null, idleVerified: false, writesVerified: false, busy: false, ended: false, events: [] };
  on('session.start', async ($, e, next) => {
    try { await begin($, state); } catch { state.binding = null; }
    return next(e);
  });
  on('session.end', async ($, e, next) => {
    state.ended = true; state.timer?.cancel();
    try { if (state.binding && state.epoch) await request($, state, '/v1/end'); } catch { /* expired */ }
    state.binding = null; state.epoch = null;
    return next(e);
  });
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (typeof e.props?.isWorking === 'boolean') state.idleVerified = !e.props.isWorking && state.activeTurnID === null;
    return next(e);
  });
  on('turn.start', async ($, e, next) => {
    if (validID(e.turnId)) { state.activeTurnID = e.turnId; state.idleVerified = false; }
    await queueEvent($, state, 'turn.start', e);
    return next(e);
  });
  on('turn.complete', async ($, e, next) => {
    const result = await next(e);
    if (e.turnId === state.activeTurnID) { state.activeTurnID = null; state.idleVerified = true; }
    await queueEvent($, state, 'turn.complete', e);
    await snapshot($, state);
    return result;
  });
  on('session.append', async ($, e, next) => {
    const result = await next(e);
    await queueEvent($, state, 'session.append', e);
    return result;
  });
}

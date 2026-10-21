// V1 Prod DB migration load: all REST and WebSocket traffic goes to one direct V1 API URL.
// This deliberately has no V2 URL, ALB routing, DNS split, or V1/V2 traffic share.
// During S2-S9, the V1 backend keeps using ProxySQL while its writer changes underneath it.
//
// Required inputs are dedicated load-test users and fixture rows created for this direct API.
// Do not point this at production data with ordinary user accounts.
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { targetUrl, confirmLoadTestTarget, runId, commonOptions, envInt, envDuration, arrivalVus } from './lib/env.js';
import { configureApi, me, createCommunityPost, createComment } from './lib/api.js';
import { loadUsers, loadFixture, poolUser, poolSize } from './lib/fixture.js';
import { buildWheel, runReadOp, discoverTargets } from './lib/read-mix.js';
import { holdChatSession } from './lib/stomp.js';
import { restThresholds } from './lib/slo.js';

const base = targetUrl('V1_DIRECT_API_URL', 'https', 'http');
const host = confirmLoadTestTarget(base);
const wsUrl = __ENV.V1_DIRECT_WS_URL
  ? targetUrl('V1_DIRECT_WS_URL', 'wss', 'ws')
  : base.replace(/^http/i, 'ws');
if (confirmLoadTestTarget(wsUrl) !== host) {
  throw new Error('V1_DIRECT_WS_URL must use the same direct V1 host as V1_DIRECT_API_URL');
}

// Require an explicit production acknowledgement in addition to the host confirmation.
if (__ENV.CONFIRM_V1_PROD_LOAD !== 'I_UNDERSTAND_V1_PROD_LOAD') {
  throw new Error('For a production run, set CONFIRM_V1_PROD_LOAD=I_UNDERSTAND_V1_PROD_LOAD');
}
if (host === 'moyeota.com' || host === 'www.moyeota.com' || host === 'dev.moyeota.com' ||
    host === 'stg.moyeota.com' || host === 'v1sim.moyeota.com' ||
    (host.endsWith('amazonaws.com') && host.includes('.elb.'))) {
  throw new Error(`${host} is a known ALB/stage hostname; V1_DIRECT_API_URL must point to the V1 API origin`);
}

const RUN = runId('migration-v1');
if (!/^[A-Za-z0-9_-]{1,32}$/.test(RUN)) {
  throw new Error('RUN_ID must be 1-32 letters, digits, _ or -');
}
const DURATION = envDuration('DURATION', '20m');
const READ_RPS = envInt('READ_RPS', 30, 1);
const WRITE_RPS = envInt('WRITE_RPS', 15, 0);
const CHAT_ROOMS = envInt('CHAT_ROOMS', 20, 0);
const CHAT_MSG_RATE = envInt('CHAT_MSG_RATE', 10, 0);
const CHAT_SESSION_S = envInt('CHAT_SESSION_S', 60, 1);
const hasMutations = WRITE_RPS > 0 || CHAT_MSG_RATE > 0;
if (hasMutations && __ENV.ALLOW_PROD_MUTATIONS !== 'I_UNDERSTAND_PROD_TEST_WRITES') {
  throw new Error('Writes/chat mutate V1 Prod data; set ALLOW_PROD_MUTATIONS=I_UNDERSTAND_PROD_TEST_WRITES only for approved test accounts and fixtures');
}

const users = loadUsers();
const fixture = loadFixture(true);
const wheel = buildWheel(false); // read scenario has no hidden writes
if (poolSize(fixture, 'writer') === 0) {
  throw new Error('The fixture writer user pool is empty');
}
const fixtureHost = fixture.base_url && /^https?:\/\/([^/:]+)/i.exec(fixture.base_url);
if (!fixtureHost || fixtureHost[1].toLowerCase() !== host) {
  throw new Error('FIXTURE_FILE.base_url must match V1_DIRECT_API_URL; seed dedicated rows through the same V1 origin first');
}

const rooms = (fixture.rooms || []).filter((room) => room.room_id && room.members && room.members.length > 0);
const chatVus = Math.min(CHAT_ROOMS, rooms.length);
if (CHAT_MSG_RATE > 0 && chatVus === 0) {
  throw new Error('CHAT_MSG_RATE is non-zero but FIXTURE_FILE has no seeded rooms');
}
if (WRITE_RPS > 0 && (!fixture.community_posts || fixture.community_posts.length === 0)) {
  throw new Error('WRITE_RPS is non-zero but FIXTURE_FILE has no dedicated community posts');
}

configureApi(base, `mig-${RUN}`);

export const migrationWrite = new Counter('migration_write'); // {kind, outcome}
export const migrationWriteDuration = new Trend('migration_write_duration', true);

const readVus = arrivalVus(READ_RPS);
const writeVus = WRITE_RPS > 0 ? arrivalVus(WRITE_RPS) : null;
const scenarios = {
  measure_reads: {
    executor: 'constant-arrival-rate', exec: 'readTraffic', rate: READ_RPS, timeUnit: '1s', duration: DURATION,
    ...readVus,
  },
};
if (WRITE_RPS > 0) {
  scenarios.measure_writes = {
    executor: 'constant-arrival-rate', exec: 'writeTraffic', rate: WRITE_RPS, timeUnit: '1s', duration: DURATION,
    ...writeVus,
  };
}
if (chatVus > 0 && CHAT_MSG_RATE > 0) {
  scenarios.measure_chat = {
    executor: 'constant-vus', exec: 'chatTraffic', vus: chatVus, duration: DURATION,
    gracefulStop: `${CHAT_SESSION_S + 10}s`,
  };
}

export const options = {
  ...commonOptions('migration-v1-direct', `mig-${RUN}`),
  discardResponseBodies: false,
  setupTimeout: '2m',
  scenarios,
  thresholds: {
    ...restThresholds('measure'),
    'dropped_iterations{scenario:measure_reads}': ['count==0'],
    ...(WRITE_RPS > 0 ? { 'dropped_iterations{scenario:measure_writes}': ['count==0'] } : {}),
  },
};

export function setup() {
  const probe = me({ token: poolUser(users, fixture, 'writer', 0).token, phase: 'setup' });
  if (probe.response.status !== 200) {
    throw new Error(`V1 direct API preflight failed: GET /api/users/me → ${probe.response.status}`);
  }
  const targets = discoverTargets(fixture);
  if (targets.companions.length === 0 || targets.community.length === 0) {
    throw new Error('No read targets found in fixture or V1 API');
  }
  console.log(`MIGRATION_RUN ${JSON.stringify({ run: RUN, target: base, reads_rps: READ_RPS, writes_rps: WRITE_RPS, chat_msg_rate: CHAT_MSG_RATE })}`);
  return targets;
}

export function readTraffic(targets) {
  const op = wheel[exec.scenario.iterationInTest % wheel.length];
  runReadOp(op, { users, fixture, targets, tags: { op, migration_phase: 'v1-direct' } });
}

function writeKey() {
  return `mig-${RUN}-${exec.vu.idInTest}-${exec.scenario.iterationInTest}`;
}

function recordWrite(kind, key, result, extra = {}) {
  const status = result.response.status;
  const outcome = status === 0 ? 'unknown' : (status >= 200 && status < 300 ? 'acked' : 'failed');
  migrationWrite.add(1, { kind, outcome });
  migrationWriteDuration.add(result.response.timings.duration, { kind });
  console.log(`LEDGER ${JSON.stringify({ k: key, kind, side: 'v1', out: outcome, st: status, code: result.outcome.code || '', ...extra, t: Date.now() })}`);
}

export function writeTraffic() {
  const n = exec.scenario.iterationInTest;
  const key = writeKey();
  const author = poolUser(users, fixture, 'writer', n);
  if (n % 2 === 0) {
    const result = createCommunityPost({
      title: `migration ${key}`.slice(0, 30),
      content: `${key} migration load record`,
      lat: 37.497952,
      lng: 127.027619,
    }, { token: author.token, cuj: 'COMMUNITY', step: 'MIGRATION_WRITE' });
    recordWrite('post', key, result, { id: result.data && result.data.id });
  } else {
    const postId = fixture.community_posts[n % fixture.community_posts.length];
    const result = createComment(postId, `${key} migration load record`, {
      token: author.token, cuj: 'COMMUNITY', step: 'MIGRATION_WRITE',
    });
    recordWrite('comment', key, result, { post: postId });
  }
}

export function chatTraffic() {
  const room = rooms[(exec.vu.idInTest - 1) % chatVus];
  const userIndex = room.members[exec.scenario.iterationInInstance % room.members.length];
  const user = users[userIndex];
  if (!user || !user.token) throw new Error(`No token for seeded chat member index ${userIndex}`);
  holdChatSession({
    wsUrl,
    runIdValue: `mig-${RUN}`,
    token: user.token,
    roomId: room.room_id,
    lifetimeMs: CHAT_SESSION_S * 1000,
    sendIntervalMs: Math.max(100, Math.round((chatVus / CHAT_MSG_RATE) * 1000)),
    messagePrefix: `mig-${RUN}`,
    tags: { migration_phase: 'v1-direct' },
  });
}

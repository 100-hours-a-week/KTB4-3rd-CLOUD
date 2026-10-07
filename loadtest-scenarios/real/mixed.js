// S5. 혼합 부하: "조회 단독 ↔ 조회 + X" 를 한 실행 안의 시간 창으로 비교한다.
//   window=control   : 조회만 (READ_RPS)
//   window=ramp      : 간섭 부하가 목표치까지 올라가는 중 (판정 제외)
//   window=treatment : 조회 + 간섭 부하
//   INTERFERE=ws       → WebSocket 연결 유지 (JVM heap·GC 경유 REST 지연 전파)
//   INTERFERE=chat     → 연결 + 메시지 저장 (공용 HikariCP 10개 경유 전파)
//   INTERFERE=hotrow   → 인기 팟 동시 참여 버스트 (row lock + 커넥션 점유 경유 꼬리 지연)
//   INTERFERE=all      → 위 세 가지 동시 (CUJ 측정은 cuj.js를 별도 프로세스로 함께 실행)
//   PROFILE=event      → 조회를 삼각형(0→PEAK→0, 10분)으로, 연결 6/s→1,800, 메시지 36/s, 경합 버스트를 함께 (행사 스파이크)
// 결과 비교: api_duration{window:control,sli_class:read} vs api_duration{window:treatment,sli_class:read}
import exec from 'k6/execution';
import { sleep } from 'k6';
import { httpBase, wsBase, runId, commonOptions, envInt, envFloat, envDuration, envBool, arrivalVus, durationToMilliseconds } from './lib/env.js';
import { configureApi } from './lib/api.js';
import { SLO } from './lib/slo.js';
import { holdChatSession } from './lib/stomp.js';
import { companionRound } from './lib/contention.js';
import { loadUsers, loadFixture, poolSize } from './lib/fixture.js';
import { buildWheel, runReadOp, discoverTargets } from './lib/read-mix.js';

const base = httpBase();
const wsUrl = wsBase();
const PROFILE = (__ENV.PROFILE || 'compare').toLowerCase();
const INTERFERE = (__ENV.INTERFERE || (PROFILE === 'event' ? 'all' : 'chat')).toLowerCase();
const has = (k) => INTERFERE === 'all' || INTERFERE === k;
const currentRunId = runId(`mixed-${PROFILE}-${INTERFERE}`);
configureApi(base, currentRunId);
const users = loadUsers();
const fixture = loadFixture(true);
const wheel = buildWheel(envBool('WRITE_TRAFFIC', true));

const readRps = envFloat('READ_RPS', 50, 0.1);
const peakRps = envFloat('PEAK_RPS', 180, 1); // 행사 단독 180, 기준 중첩 225.5
const controlMs = durationToMilliseconds(envDuration('CONTROL', PROFILE === 'event' ? '0s' : '5m'));
const treatMs = durationToMilliseconds(envDuration('TREATMENT', PROFILE === 'event' ? '10m' : '5m'));
const wsTarget = envInt('WS_CONNECTIONS', PROFILE === 'event' ? 1800 : 1600);
const connectRate = envFloat('CONNECT_RATE', PROFILE === 'event' ? 6 : 20, 0.1);
const messageRate = has('chat') ? envFloat('MESSAGE_RATE', PROFILE === 'event' ? 36 : 47, 0.1) : 0;
const hotLevel = envInt('HOTROW_CONCURRENCY', 50);
const hotEvery = durationToMilliseconds(envDuration('HOTROW_INTERVAL', '30s')) / 1000;
const wsRampMs = (has('ws') || has('chat')) ? Math.ceil(wsTarget / connectRate) * 1000 : 0;
const rampMs = PROFILE === 'event' ? 0 : wsRampMs;
const totalMs = controlMs + rampMs + treatMs;

const members = [];
for (const room of fixture.rooms) for (const u of room.members) members.push({ userIndex: u, roomId: room.room_id });
if ((has('ws') || has('chat')) && wsTarget > members.length) {
  throw new Error(`WS_CONNECTIONS ${wsTarget} > seeded chat members ${members.length}`);
}

function windowName() {
  const t = exec.instance.currentTestRunDuration;
  if (t < controlMs) return 'control';
  if (t < controlMs + rampMs) return 'ramp';
  return 'treatment';
}

const vus = arrivalVus(PROFILE === 'event' ? peakRps : readRps);
const scenarios = {};
if (PROFILE === 'event') {
  const half = `${Math.round(treatMs / 2000)}s`;
  scenarios.measure_read = {
    executor: 'ramping-arrival-rate', startRate: 1, timeUnit: '1s', ...vus,
    stages: [{ duration: half, target: Math.round(peakRps) }, { duration: half, target: 1 }],
    exec: 'read', tags: { workload: 'read' },
  };
} else {
  scenarios.measure_read = {
    executor: 'constant-arrival-rate', rate: Math.round(readRps * 10), timeUnit: '10s',
    duration: `${totalMs / 1000}s`, ...vus, exec: 'read', tags: { workload: 'read' },
  };
}
if (has('ws') || has('chat')) {
  const hold = Math.max(1000, totalMs - controlMs - wsRampMs);
  scenarios.ws = {
    executor: 'ramping-vus', startVUs: 0, startTime: `${controlMs / 1000}s`,
    stages: [
      { duration: `${wsRampMs / 1000}s`, target: wsTarget },
      { duration: `${hold / 1000}s`, target: wsTarget },
      { duration: '10s', target: 0 },
    ],
    gracefulRampDown: '5s', exec: 'chatter', tags: { workload: 'ws' },
  };
}
if (has('hotrow')) {
  scenarios.hotrow = {
    executor: 'constant-vus', vus: 1, startTime: `${(controlMs + rampMs) / 1000}s`,
    duration: `${treatMs / 1000}s`, exec: 'contention', tags: { workload: 'hotrow' },
  };
}

const thresholds = {
  'sli_availability{window:treatment}': [`rate>=${SLO.availability}`],
  'api_duration{window:treatment,sli_class:read}': [`p(95)<${SLO.readP95}`, `p(99)<${SLO.readP99}`],
  'api_duration{window:control,sli_class:read}': [`p(95)<${SLO.readP95}`, `p(99)<${SLO.readP99}`],
  'api_duration{window:treatment,sli_class:write}': [`p(95)<${SLO.writeP95}`, `p(99)<${SLO.writeP99}`],
  'dropped_iterations{scenario:measure_read}': ['count==0'],
  nginx_rate_limited: ['count==0'],
};
if (has('ws') || has('chat')) {
  thresholds['stomp_connected{phase:connect}'] = [`rate>=${SLO.wsConnect}`];
  thresholds.ws_unexpected_close = ['count==0'];
}
if (messageRate > 0) {
  thresholds['chat_delivery_success{phase:treatment}'] = [`rate>=${SLO.chatPersist}`];
  thresholds['chat_delivery_seconds{phase:treatment}'] = [`p(99)<${SLO.chatDeliveryP99}`];
}
if (has('hotrow')) thresholds.hot_row_consistency = ['rate==1'];

export const options = {
  ...commonOptions(`mixed-${PROFILE}`, currentRunId),
  batch: hotLevel,
  batchPerHost: hotLevel,
  scenarios,
  thresholds,
};

export function setup() {
  return discoverTargets(fixture);
}

export function read(targets) {
  const op = wheel[exec.scenario.iterationInTest % wheel.length];
  runReadOp(op, { users, fixture, targets, tags: { op, window: windowName() } });
}

export function chatter() {
  const member = members[(exec.vu.idInTest - 1) % members.length];
  const remaining = Math.max(5000, totalMs - exec.instance.currentTestRunDuration);
  holdChatSession({
    wsUrl,
    runIdValue: currentRunId,
    token: users[member.userIndex].token,
    roomId: member.roomId,
    lifetimeMs: remaining,
    sendIntervalMs: messageRate > 0 ? Math.round((wsTarget / messageRate) * 1000) : 0,
    phase: windowName,
    tags: { window: 'ws' },
  });
  sleep(3);
}

let round = 0;
export function contention() {
  const tags = { phase: 'measure', window: windowName(), concurrency: String(hotLevel), mode: 'companion' };
  if (hotLevel + 1 > poolSize(fixture, 'hotrow')) throw new Error('hotrow pool too small');
  companionRound({ users, fixture, runIdValue: currentRunId, distribute: 1 }, hotLevel, round, tags);
  round += 1;
  sleep(hotEvery);
}

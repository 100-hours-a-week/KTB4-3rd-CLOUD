// S1. 조회 증가 (단독): 실제 탐색·상세 API를 단계별 RPS로 올리며 Spring·HikariCP·MySQL 점유를 본다.
//   기본 단계: 45.5(출퇴근 1세션) → 91(왕복 기준) → 180(행사) → 225.5(행사+기준 중첩) → 300·450(한계 탐색)
//   1 arrival = 1 HTTP 요청이므로 단계 값이 곧 HTTP RPS다.
//
// k6 run -e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host> -e STEPS=46,91,180,226 real/read.js
import exec from 'k6/execution';
import { httpBase, runId, commonOptions, envDuration, envBool, parseSteps, arrivalVus, durationToMilliseconds } from './lib/env.js';
import { configureApi } from './lib/api.js';
import { restThresholds } from './lib/slo.js';
import { loadUsers, loadFixture } from './lib/fixture.js';
import { buildWheel, runReadOp, discoverTargets } from './lib/read-mix.js';

const base = httpBase();
const steps = parseSteps('STEPS', '46,91,180,226');
const currentRunId = runId(`read-${steps.join('_')}`);
configureApi(base, currentRunId);
const users = loadUsers();
const fixture = loadFixture(true);
const wheel = buildWheel(envBool('WRITE_TRAFFIC', true));

const warmup = envDuration('WARMUP', '2m');
const stepDuration = envDuration('STEP_DURATION', '5m');
const gap = envDuration('STEP_GAP', '30s'); // 단계 사이 회복 구간(자원 지표 경계 구분용)
const vus = arrivalVus(Math.max(...steps));

const scenarios = {
  warmup: {
    executor: 'ramping-arrival-rate',
    startRate: 1,
    timeUnit: '1s',
    preAllocatedVUs: vus.preAllocatedVUs,
    maxVUs: vus.maxVUs,
    stages: [{ duration: warmup, target: Math.round(steps[0]) }],
    gracefulStop: '0s',
    exec: 'readTraffic',
    tags: { phase: 'warmup', step_rps: 'warmup' },
  },
};
let offsetMs = durationToMilliseconds(warmup);
const key = (rps) => String(rps).replace('.', '_');
for (const rps of steps) {
  scenarios[`measure_${key(rps)}`] = {
    executor: 'constant-arrival-rate',
    startTime: `${offsetMs / 1000}s`,
    rate: Math.round(rps * 10),
    timeUnit: '10s', // 45.5 같은 소수 RPS 지원
    duration: stepDuration,
    preAllocatedVUs: vus.preAllocatedVUs,
    maxVUs: vus.maxVUs,
    gracefulStop: '10s',
    exec: 'readTraffic',
    tags: { phase: 'measure', step_rps: key(rps) },
  };
  offsetMs += durationToMilliseconds(stepDuration) + durationToMilliseconds(gap);
}

const thresholds = restThresholds('measure');
for (const rps of steps) {
  // 단계별 SLO 판정: 어느 RPS에서 처음 깨지는지 summary에서 바로 보이게 한다.
  thresholds[`sli_availability{step_rps:${key(rps)}}`] = ['rate>=0.999'];
  thresholds[`api_duration{step_rps:${key(rps)},sli_class:read}`] = ['p(95)<1000', 'p(99)<2500'];
  thresholds[`dropped_iterations{scenario:measure_${key(rps)}}`] = ['count==0'];
}

const base0 = commonOptions('read', currentRunId);
export const options = { ...base0, scenarios, thresholds };

export function setup() {
  const targets = discoverTargets(fixture);
  if (targets.companions.length === 0 || targets.community.length === 0) {
    throw new Error('조회 대상 게시글이 없습니다. seed.js를 먼저 실행하세요.');
  }
  console.log(`[read] targets companions=${targets.companions.length} community=${targets.community.length}`);
  return targets;
}

export function readTraffic(targets) {
  const op = wheel[exec.scenario.iterationInTest % wheel.length];
  runReadOp(op, { users, fixture, targets, tags: { op } });
}

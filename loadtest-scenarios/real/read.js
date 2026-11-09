// S1. 조회 증가 (단독): 실제 탐색·상세 API를 단계별 RPS로 올리며 Spring·HikariCP·MySQL 점유를 본다.
//   기본 단계: 45.5(출퇴근 1세션) → 91(왕복 기준) → 180(행사) → 225.5(행사+기준 중첩) → 300·450(한계 탐색)
//   1 arrival = 1 HTTP 요청이므로 단계 값이 곧 HTTP RPS다.
//
// k6 run -e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host> -e STEPS=46,91,180,226 real/read.js
//
// 상한 탐색 ramp (RAMP=true): STEPS 대신 RAMP_START → RAMP_TARGET 을 RAMP_STEP(rps) 폭의 구간으로 쪼개 선형으로 올린다.
//   구간마다 ramping-arrival-rate(startRate=구간 시작, target=구간 끝)라 구간 경계에서 부하가 끊기거나 튀지 않는다.
//   기울기 = RAMP_STEP / RAMP_SLICE_DURATION (기본 10rps / 2m = 분당 5rps). 오토스케일 스케일아웃이 끝나기 전에
//   헤드룸이 소진되지 않도록 (기울기 × 스케일아웃 소요시간) 이 태스크 1개의 여유 처리량보다 작게 잡는다.
//   k6 run -e RAMP=true -e RAMP_START=20 -e RAMP_TARGET=300 -e RAMP_STEP=10 -e RAMP_SLICE_DURATION=2m real/read.js
// 중단: 구간별 가용성·dropped_iterations 가 깨지면 abortOnFail 로 즉시 멈춘다 (ABORT_ON_FAIL=false 로 끔).
import exec from 'k6/execution';
import { httpBase, runId, commonOptions, envDuration, envBool, envInt, envFloat, parseSteps, durationToMilliseconds } from './lib/env.js';
import { configureApi } from './lib/api.js';
import { restThresholds, SLO } from './lib/slo.js';
import { loadUsers, loadFixture } from './lib/fixture.js';
import { buildWheel, runReadOp, discoverTargets } from './lib/read-mix.js';

const base = httpBase();
const ramp = envBool('RAMP', false);
const rampStart = envFloat('RAMP_START', 20, 1);
const rampTarget = envFloat('RAMP_TARGET', 300, 1);
const rampStep = envFloat('RAMP_STEP', 10, 0.5);
const rampSlice = envDuration('RAMP_SLICE_DURATION', '2m');
if (ramp && rampTarget <= rampStart) {
  throw new Error(`RAMP_TARGET(${rampTarget}) must be greater than RAMP_START(${rampStart})`);
}
const steps = ramp ? [] : parseSteps('STEPS', '46,91,180,226');
const currentRunId = runId(ramp ? `read-ramp-${rampStart}_${rampTarget}` : `read-${steps.join('_')}`);
configureApi(base, currentRunId);
const users = loadUsers();
const fixture = loadFixture(true);
const wheel = buildWheel(envBool('WRITE_TRAFFIC', true));

const warmup = envDuration('WARMUP', '2m');
const stepDuration = envDuration('STEP_DURATION', '5m');
const gap = envDuration('STEP_GAP', ramp ? '0s' : '30s'); // 단계 사이 회복 구간(자원 지표 경계 구분용)
// abort 는 "SLO 위반 기록"과 분리한 보호용이다. SLO(가용성 99.9%·p95·p99) 위반은 구간별로 끝까지 평가해 결과에 남기고,
// 상한은 실행 후 "처음 위반한 구간의 직전"으로 정한다. abort 는 명백한 붕괴(공용 stg DB 보호)에만 건다.
// 매분 정각 스케줄러 정체(약 2초, 06~ 리허설)가 일시적으로 SLO·dropped 를 건드려도 멈추지 않도록 느슨하게 둔다.
const abortOnFail = envBool('ABORT_ON_FAIL', true);
const abortDelay = envDuration('ABORT_DELAY', '30s'); // 구간 초반 표본이 적을 때 한 건 실패로 멈추지 않게
const abortDroppedMax = envInt('ABORT_DROPPED_MAX', 50, 0); // 구간당 이 건수를 넘게 dropped 되면 중단
const abortAvailability = envFloat('ABORT_AVAILABILITY', 0.95, 0, 1); // 구간 가용성이 이 아래로 떨어지면 중단

// VU 산정 (Little의 법칙: 동시 요청 수 = 도착률 × 응답시간). 평균 지연이 아니라 "예상 정체 길이"로 잡는다.
//   pre = rate × VU_PRE_SECONDS : 매분 정각 정체(약 2초)가 와도 추가 VU 생성 지연으로 dropped 가 나지 않게 2.5s.
//         (평균 지연 0.16s 기준 0.5s 로 잡았다가 35 RPS 구간에서 정체 2초에 VU 20→34 급증, dropped 14건이 났다)
//   max = rate × VU_MAX_SECONDS : 정체가 더 길어도 VU 가 모자라 dropped 로 오인되지 않게 5s. 요청 타임아웃(10s) 전이다.
//   생성기 메모리: 300 RPS 면 pre 750 / max 1,500 VU. 부족하면 PRE_ALLOCATED_VUS / MAX_VUS 로 절대값을 덮어쓴다.
const vuPreSeconds = envFloat('VU_PRE_SECONDS', 2.5, 0.1);
const vuMaxSeconds = envFloat('VU_MAX_SECONDS', 5, 0.5);
function vusFor(rate) {
  const pre = envInt('PRE_ALLOCATED_VUS', Math.max(10, Math.ceil(rate * vuPreSeconds)));
  const max = envInt('MAX_VUS', Math.max(pre, Math.ceil(rate * vuMaxSeconds)));
  return { preAllocatedVUs: pre, maxVUs: max };
}

const key = (rps) => String(rps).replace('.', '_');
const rate10 = (rps) => Math.round(rps * 10); // timeUnit 10s 로 소수 RPS 지원

// slices: 판정·태그 단위. 단계 모드는 구간 1개 = 평탄 단계 1개, ramp 모드는 구간 1개 = RPS 폭 rampStep 의 선형 구간.
const slices = [];
if (ramp) {
  for (let lo = rampStart; lo < rampTarget; lo += rampStep) {
    const hi = Math.min(lo + rampStep, rampTarget);
    slices.push({ label: `${key(lo)}to${key(hi)}`, lo, hi, duration: rampSlice });
  }
} else {
  for (const rps of steps) slices.push({ label: key(rps), lo: rps, hi: rps, duration: stepDuration });
}
const firstRate = slices[0].lo;
const peakRate = Math.max(...slices.map((s) => s.hi));

const warmupVus = vusFor(firstRate);
const scenarios = {
  warmup: {
    executor: 'ramping-arrival-rate',
    startRate: 1,
    timeUnit: '1s',
    ...warmupVus,
    stages: [{ duration: warmup, target: Math.round(firstRate) }],
    gracefulStop: '0s',
    exec: 'readTraffic',
    tags: { phase: 'warmup', step_rps: 'warmup' },
  },
};
let offsetMs = durationToMilliseconds(warmup);
for (const s of slices) {
  const common = {
    startTime: `${offsetMs / 1000}s`,
    timeUnit: '10s',
    ...vusFor(s.hi),
    gracefulStop: '10s',
    exec: 'readTraffic',
    tags: { phase: 'measure', step_rps: s.label },
  };
  scenarios[`measure_${s.label}`] = ramp
    ? { ...common, executor: 'ramping-arrival-rate', startRate: rate10(s.lo), stages: [{ duration: s.duration, target: rate10(s.hi) }] }
    : { ...common, executor: 'constant-arrival-rate', rate: rate10(s.lo), duration: s.duration };
  offsetMs += durationToMilliseconds(s.duration) + durationToMilliseconds(gap);
}

const thresholds = restThresholds('measure');
const abortable = (threshold) => (abortOnFail ? { threshold, abortOnFail: true, delayAbortEval: abortDelay } : threshold);
for (const s of slices) {
  // 구간별 SLO 판정: 어느 RPS에서 처음 깨지는지 summary에서 바로 보이게 한다.
  // 가용성은 SLO 판정(끝까지 평가)과 abort 판정(ABORT_AVAILABILITY, 붕괴 시 중단)을 따로 둔다.
  thresholds[`sli_availability{step_rps:${s.label}}`] = [
    `rate>=${SLO.availability}`,
    ...(abortOnFail ? [abortable(`rate>=${abortAvailability}`)] : []),
  ];
  thresholds[`api_duration{step_rps:${s.label},sli_class:read}`] = ['p(95)<1000', 'p(99)<2500'];
  // dropped 는 서버 포화 또는 VU 상한 도달 신호다.
  // 리포트용 count==0 은 그대로 두고, abort 는 ABORT_DROPPED_MAX 초과(지속되는 밀림)부터 건다.
  thresholds[`dropped_iterations{scenario:measure_${s.label}}`] = ['count==0', abortable(`count<=${abortDroppedMax}`)];
}

const base0 = commonOptions('read', currentRunId);
// setup() 은 지역 6곳의 map-pins 로 조회 대상을 찾는다. map-pins 쿼리가 미수정이라 DB 부하 중에는 호출당 수 초~10초 이상 걸려
// k6 기본 60s 를 넘길 수 있다 (2026-11-05 ws1-A-n10000: setup() timed out → 배경 조회 부하가 시작되지 못했다).
const setupTimeout = __ENV.SETUP_TIMEOUT || '180s';
export const options = { ...base0, setupTimeout, scenarios, thresholds };

export function setup() {
  const targets = discoverTargets(fixture);
  if (targets.companions.length === 0 || targets.community.length === 0) {
    throw new Error('조회 대상 게시글이 없습니다. seed.js를 먼저 실행하세요.');
  }
  const totalMin = Math.round(offsetMs / 6000) / 10;
  console.log(ramp
    ? `[read] RAMP ${rampStart}→${rampTarget} rps, ${slices.length} slices x ${rampSlice} (${rampStep} rps/slice, slope ${(rampStep / (durationToMilliseconds(rampSlice) / 60000)).toFixed(2)} rps/min), total ${totalMin}m incl. warmup, VU pre/max at peak ${JSON.stringify(vusFor(peakRate))}, abortOnFail=${abortOnFail}`
    : `[read] STEPS ${steps.join(',')} total ${totalMin}m, abortOnFail=${abortOnFail}`);
  console.log(`[read] targets companions=${targets.companions.length} community=${targets.community.length}`);
  return targets;
}

export function readTraffic(targets) {
  const op = wheel[exec.scenario.iterationInTest % wheel.length];
  runReadOp(op, { users, fixture, targets, tags: { op } });
}

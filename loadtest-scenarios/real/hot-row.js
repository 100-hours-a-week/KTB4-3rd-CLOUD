// S4. 인기 자원 집중(좌석 경합)
//   MODE=companion : 같은 동행 모집글에 서로 다른 사용자가 동시에 참여
//                    → ChatParticipationService.participate 의 조건부 UPDATE
//                      (companions.current_count < capacity, 같은 행 X-lock) + 참여 행 INSERT
//   MODE=taxi      : 같은 출발·도착 좌표와 같은 출발 '분'으로 동시에 택시팟 매칭
//                    → TaxiPotService.start 의 users FOR UPDATE + findMatchableTaxiPotForUpdate(FOR UPDATE)
//                      잠금 획득 실패 3회 → 409 MATCH_BUSY(Bad event)
//   DISTRIBUTE=K   : 같은 동시성을 K개 대상으로 분산한 대조군 (K=1이 hot-row)
// 매 라운드 후 정합성(정원 초과·중복 팟)을 검증하고 참여를 정리한다.
//
// k6 run -e BASE_URL=... -e CONFIRM_TARGET_HOST=... -e MODE=companion -e LEVELS=20,50,100 -e ROUNDS=3 real/hot-row.js
import { sleep } from 'k6';
import { httpBase, runId, commonOptions, envInt, envDuration, parseSteps, durationToMilliseconds } from './lib/env.js';
import * as api from './lib/api.js';
import { restThresholds } from './lib/slo.js';
import { companionRound, taxiRound } from './lib/contention.js';
import { loadUsers, loadFixture, poolSize } from './lib/fixture.js';

const base = httpBase();
const MODE = (__ENV.MODE || 'companion').toLowerCase();
if (!['companion', 'taxi'].includes(MODE)) throw new Error('MODE must be companion or taxi');
const levels = parseSteps('LEVELS', '20,50,100');
const rounds = envInt('ROUNDS', 3);
const distribute = envInt('DISTRIBUTE', 1, 1, 50);
const pause = durationToMilliseconds(envDuration('ROUND_PAUSE', '10s')) / 1000;
const currentRunId = runId(`hot-${MODE}-d${distribute}`);
api.configureApi(base, currentRunId);
const users = loadUsers();
const fixture = loadFixture(true);

const maxLevel = Math.max(...levels);
if (maxLevel + distribute > poolSize(fixture, 'hotrow')) {
  throw new Error(`hotrow pool(${poolSize(fixture, 'hotrow')}) < level ${maxLevel} + hosts ${distribute}`);
}

const thresholds = {
  ...restThresholds('measure'),
  hot_row_consistency: ['rate==1'],
  cleanup_failures: ['count==0'],
};
for (const level of levels) {
  thresholds[`sli_availability{concurrency:${level}}`] = ['rate>=0.999'];
  thresholds[`api_duration{concurrency:${level},sli_class:write}`] = ['p(95)<1500', 'p(99)<3000'];
}

export const options = {
  ...commonOptions(`hot-row-${MODE}`, currentRunId),
  batch: maxLevel,
  batchPerHost: maxLevel,
  scenarios: { measure: { executor: 'per-vu-iterations', vus: 1, iterations: 1, maxDuration: '60m' } },
  thresholds,
};

export default function () {
  for (const level of levels) {
    for (let round = 0; round < rounds; round += 1) {
      const tags = { phase: 'measure', concurrency: String(level), mode: MODE, distribute: String(distribute) };
      const ctx = { users, fixture, runIdValue: currentRunId, distribute };
      if (MODE === 'companion') companionRound(ctx, level, round, tags);
      else taxiRound(ctx, level, round, tags);
      sleep(pause);
    }
  }
}

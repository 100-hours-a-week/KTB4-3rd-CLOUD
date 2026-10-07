// 좌석 경합 1라운드 로직. hot-row.js(단독)와 mixed.js(조회 중 경합 주입)가 함께 쓴다.
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter, Trend } from 'k6/metrics';
import * as api from './api.js';
import { recordOutcome, OUTCOME } from './slo.js';
import { poolUser, poolSize } from './fixture.js';
import { DISTRICTS, minutesFromNow, taxiDepartureMinute } from './geo.js';

export const consistency = new Rate('hot_row_consistency'); // 정원·중복 정합성 (목표 100%)
export const acceptedPerTarget = new Trend('hot_row_accepted_per_target');
export const taxiPotsCreated = new Counter('taxi_pots_created');
export const taxiFragmentation = new Counter('taxi_pot_fragmentation'); // 최적 대비 추가로 생긴 팟 수
export const cleanupFailures = new Counter('cleanup_failures');


// ctx = { users, fixture, runIdValue, distribute }
export function companionRound(ctx, level, round, tags) {
  const { users, fixture, distribute } = ctx;
  const currentRunId = ctx.runIdValue;
  // 대상 글 생성: SUBWAY, recruit_count 9 → capacity 10 (이동수단별 최대)
  const hostOffset = (round * distribute) % poolSize(fixture, 'hotrow');
  const targets = [];
  for (let k = 0; k < distribute; k += 1) {
    const host = poolUser(users, fixture, 'hotrow', hostOffset + k);
    const d = DISTRICTS[k % DISTRICTS.length];
    const r = api.createCompanion({
      origin_name: `${d.name} 인기팟`, origin_lat: d.lat, origin_lng: d.lng,
      dest_name: '판교 테크노밸리', dest_lat: 37.401, dest_lng: 127.108,
      departure_at: minutesFromNow(120), transport_type: 'SUBWAY', recruit_count: 9,
      content: `hot-row ${currentRunId}`,
    }, { token: host.token, phase: 'prepare' });
    if (!r.ok) throw new Error(`hot-row target create failed: ${r.response.status} ${r.response.body}`);
    targets.push({ id: r.data.id, host, capacity: 10 });
  }

  // 참여자는 호스트와 겹치지 않게 풀의 뒤쪽에서 라운드마다 회전
  const joiners = [];
  for (let i = 0; i < level; i += 1) {
    joiners.push(poolUser(users, fixture, 'hotrow', distribute + ((round * level + i) % (poolSize(fixture, 'hotrow') - distribute))));
  }
  const requests = joiners.map((u, i) => api.batchJoinRequest(targets[i % distribute].id, u.token, tags));
  const responses = http.batch(requests.map((r) => [r.method, r.url, r.body, r.params]));

  const accepted = targets.map(() => []);
  responses.forEach((res, i) => {
    const outcome = recordOutcome(res, api.RULES.companionJoin, { ...tags, api: 'POST /api/companion-posts/{companion_id}/participants', sli_class: 'write' });
    if (outcome.result === OUTCOME.GOOD) accepted[i % distribute].push(joiners[i]);
  });

  // 검증: 응답 기준 수락 수 ≤ 남은 좌석, DB 기준 current_count == 1 + 수락 수 ≤ capacity
  targets.forEach((t, k) => {
    const detail = api.companionDetail(t.id, { phase: 'verify' });
    const current = detail.data ? detail.data.current_count : -1;
    const ok = current >= 1 && current <= t.capacity && current === 1 + accepted[k].length && accepted[k].length <= t.capacity - 1;
    consistency.add(ok ? 1 : 0, tags);
    acceptedPerTarget.add(accepted[k].length, tags);
    check(null, { 'companion seats consistent': () => ok }, tags);
    if (!ok) console.error(`[hot-row] inconsistent companion ${t.id}: current=${current} accepted=${accepted[k].length}`);
  });

  // 정리: 참여자 → 방장 순으로 나가 채팅방까지 닫는다.
  targets.forEach((t, k) => {
    for (const u of accepted[k]) {
      if (!api.leaveCompanion(t.id, { token: u.token, phase: 'cleanup' }).ok) cleanupFailures.add(1);
    }
    if (!api.leaveCompanion(t.id, { token: t.host.token, phase: 'cleanup' }).ok) cleanupFailures.add(1);
  });
}

export function taxiRound(ctx, level, round, tags) {
  const { users, fixture, distribute } = ctx;
  // 출발 '분'이 같아야 같은 팟 후보가 된다. 라운드마다 다른 분을 써서 이전 라운드 팟과 섞이지 않게 한다.
  const departure = taxiDepartureMinute(30 + ((round + level) % 120));
  const routes = [];
  for (let k = 0; k < distribute; k += 1) {
    const o = DISTRICTS[k % DISTRICTS.length];
    const dst = DISTRICTS[(k + 1) % DISTRICTS.length];
    routes.push({
      origin_name: `${o.name} 택시`, origin_lat: o.lat, origin_lng: o.lng,
      dest_name: `${dst.name} 택시`, dest_lat: dst.lat, dest_lng: Math.round((dst.lng + k * 0.000001) * 1e6) / 1e6,
      departure_at: departure,
    });
  }
  const riders = [];
  for (let i = 0; i < level; i += 1) {
    riders.push(poolUser(users, fixture, 'hotrow', (round * level + i) % poolSize(fixture, 'hotrow')));
  }
  const requests = riders.map((u, i) => api.batchTaxiRequest(routes[i % distribute], u.token, tags));
  const responses = http.batch(requests.map((r) => [r.method, r.url, r.body, r.params]));

  const pots = {}; // pot id → {count, capacity, route}
  const joined = [];
  responses.forEach((res, i) => {
    const outcome = recordOutcome(res, api.RULES.taxiStart, { ...tags, api: 'POST /api/taxi-pots', sli_class: 'write' });
    if (outcome.result !== OUTCOME.GOOD) return;
    const data = api.readData(res);
    const route = i % distribute;
    pots[data.id] = pots[data.id] || { members: 0, maxSeen: 0, capacity: data.capacity, route };
    pots[data.id].members += 1;
    pots[data.id].maxSeen = Math.max(pots[data.id].maxSeen, data.current_count);
    joined.push({ user: riders[i], potId: data.id });
  });

  const potIds = Object.keys(pots);
  taxiPotsCreated.add(potIds.length, tags);
  const perRoute = {};
  for (const id of potIds) {
    const p = pots[id];
    perRoute[p.route] = perRoute[p.route] || { joined: 0, pots: 0 };
    perRoute[p.route].joined += p.members;
    perRoute[p.route].pots += 1;
    const ok = p.members <= p.capacity && p.maxSeen <= p.capacity;
    consistency.add(ok ? 1 : 0, tags);
    if (!ok) console.error(`[hot-row] taxi pot ${id} over capacity: members=${p.members} max=${p.maxSeen}`);
  }
  for (const r of Object.values(perRoute)) {
    // 완전 일치 매칭이므로 이상적으로는 ceil(joined/4)개 팟. 초과분은 동시 'no pot found → create' 경쟁의 흔적.
    taxiFragmentation.add(r.pots - Math.ceil(r.joined / 4), tags);
  }

  for (const j of joined) {
    if (!api.leaveTaxiPot(j.potId, { token: j.user.token, phase: 'cleanup' }).ok) cleanupFailures.add(1);
  }
}

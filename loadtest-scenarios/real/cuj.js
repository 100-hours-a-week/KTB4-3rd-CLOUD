// CUJ E2E: SLI 문서의 세 여정을 실제 API 순서대로 실행하고 "의도 확정 → 첫 MESSAGE" 신뢰성 완료율(P8·H6·T8)을 잰다.
//   participant : nearby-posts → companion detail → [의도 확정] POST participants → chat-room → messages → STOMP 첫 메시지
//   host        : [의도 확정] POST companion-posts → detail(current_count) → chat-rooms에서 방 찾기 → STOMP 첫 메시지
//   taxi        : [의도 확정] POST taxi-pots → current-taxi-pot(같은 id·방) → taxi detail → STOMP 첫 메시지
// 각 여정 후 참여를 정리해 같은 계정이 반복 실행될 수 있게 한다.
// JOURNEY=all 이면 세 여정을 동시에 (각자 JOURNEY_RATE/분) 실행한다. 다른 부하와 함께 돌릴 땐 mixed.js 사용.
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { httpBase, wsBase, runId, commonOptions, envInt, envDuration } from './lib/env.js';
import * as api from './lib/api.js';
import { SLO, restThresholds, OUTCOME } from './lib/slo.js';
import { chatRoundTrip } from './lib/stomp.js';
import { loadUsers, loadFixture, poolSize } from './lib/fixture.js';
import { district, pointNear, viewportAround, minutesFromNow, rand, DISTRICTS } from './lib/geo.js';

const base = httpBase();
const wsUrl = wsBase();
const JOURNEY = (__ENV.JOURNEY || 'all').toLowerCase();
const currentRunId = runId(`cuj-${JOURNEY}`);
api.configureApi(base, currentRunId);
const users = loadUsers();
const fixture = loadFixture(true);

export const cujReliability = new Rate('cuj_reliability'); // 의도 확정 후 첫 MESSAGE까지 (SLO 97%)
export const cujFunnel = new Rate('cuj_funnel'); // 탐색 시작 기준 제품 퍼널 (참고 지표)
export const cujSeconds = new Trend('cuj_completion_seconds');
export const cujStep = new Counter('cuj_step_total');
export const taxiMatch = new Counter('taxi_match_total');
export const taxiFresh = new Rate('taxi_state_fresh'); // T6: POST 결과와 current 조회 일치

const think = envInt('THINK_TIME_MS', 500, 0) / 1000;
const ratePerMin = envInt('JOURNEY_RATE', 12); // 여정별 분당 시작 수
const duration = envDuration('DURATION', '10m');

const journeys = JOURNEY === 'all' ? ['participant', 'host', 'taxi'] : [JOURNEY];
for (const j of journeys) {
  if (!['participant', 'host', 'taxi'].includes(j)) throw new Error(`unknown JOURNEY ${j}`);
}
const cujSize = poolSize(fixture, 'cuj');
const slice = Math.floor(cujSize / journeys.length);

const scenarios = {};
journeys.forEach((j, k) => {
  scenarios[`measure_${j}`] = {
    executor: 'constant-arrival-rate',
    rate: ratePerMin,
    timeUnit: '1m',
    duration,
    preAllocatedVUs: Math.min(slice, Math.max(2, Math.ceil(ratePerMin / 6))),
    maxVUs: slice, // 한 계정을 두 VU가 동시에 쓰지 않도록 상한 = 할당 계정 수
    exec: j,
    tags: { journey: j },
    env: { POOL_OFFSET: String(k * slice) },
  };
});

const cujNames = { participant: 'COMPANION_PARTICIPANT', host: 'COMPANION_HOST', taxi: 'TAXI_MATCH' };
const thresholds = { ...restThresholds('measure') };
for (const j of journeys) {
  thresholds[`cuj_reliability{cuj:${cujNames[j]}}`] = [`rate>=${SLO.cujCompletion}`];
}
thresholds['taxi_state_fresh'] = ['rate>=0.999'];

export const options = { ...commonOptions('cuj', currentRunId), scenarios, thresholds };

// VU마다 고정 계정: 같은 사용자의 이전 여정이 끝난 뒤에만 다음 여정을 시작한다.
function actor() {
  const [start] = fixture.pools.cuj;
  const offset = Number(__ENV.POOL_OFFSET || 0);
  const local = (exec.vu.idInTest - 1) % slice;
  return users[start + offset + local];
}

function step(cuj, name, result) {
  cujStep.add(1, { cuj, step: name, result });
}

function finish(cuj, intent, completed, startedAt) {
  cujFunnel.add(completed ? 1 : 0, { cuj });
  if (intent !== null) {
    cujReliability.add(completed ? 1 : 0, { cuj });
  }
  if (completed) cujSeconds.add((Date.now() - startedAt) / 1000, { cuj });
}

function chat(cuj, user, roomId) {
  const r = chatRoundTrip({ wsUrl, runIdValue: currentRunId, token: user.token, roomId, tags: { cuj, phase: 'measure' } });
  step(cuj, 'CHAT_CONNECT', r.connected ? OUTCOME.GOOD : OUTCOME.BAD);
  step(cuj, 'FIRST_MESSAGE', r.delivered ? OUTCOME.GOOD : OUTCOME.BAD);
  return r.delivered;
}

export function participant() {
  const cuj = cujNames.participant;
  const user = actor();
  const o = { cuj, token: user.token };
  const n = exec.scenario.iterationInTest;
  const startedAt = Date.now();
  const d = district(n);
  const center = pointNear(d, n + 777);

  const explore = api.nearbyPosts(center, viewportAround(center), null, { ...o, step: 'EXPLORE' });
  step(cuj, 'EXPLORE', explore.outcome.result);
  const candidates = ((explore.data && explore.data.items) || [])
    .filter((it) => it.type === 'COMPANION' && !it.is_expired && it.current_count < it.capacity);
  if (!explore.ok || candidates.length === 0) {
    // 탐색만 하고 떠난 사용자: 신뢰성 분모에서 제외, 퍼널에는 포함
    step(cuj, 'EXPLORE', explore.ok ? 'ABANDONED' : OUTCOME.BAD);
    finish(cuj, explore.ok ? null : false, false, startedAt);
    return;
  }
  sleep(think);

  let joined = null;
  let intent = null;
  for (let attempt = 0; attempt < 3 && attempt < candidates.length && !joined; attempt += 1) {
    const target = candidates[Math.floor(rand(n + attempt) * candidates.length)];
    const detail = api.companionDetail(target.id, { ...o, step: 'DETAIL' });
    step(cuj, 'DETAIL', detail.outcome.result);
    if (!detail.ok || detail.data.is_full || detail.data.joined) continue;
    sleep(think);
    const join = api.joinCompanion(target.id, { ...o, step: 'JOIN' });
    step(cuj, 'JOIN', join.outcome.result);
    if (join.outcome.result === OUTCOME.REJECTED) continue; // 정원 마감 경합 등: 다른 글로 재시도
    intent = true;
    if (join.ok) joined = { companionId: target.id, roomId: join.data.chat_room_id };
    break;
  }
  if (!joined) {
    finish(cuj, intent, false, startedAt);
    return;
  }

  let ok = api.chatRoomDetail(joined.roomId, { ...o, step: 'CHAT_ROOM' }).ok;
  ok = api.chatMessages(joined.roomId, null, { ...o, step: 'CHAT_HISTORY' }).ok && ok;
  ok = ok && chat(cuj, user, joined.roomId);
  finish(cuj, true, ok, startedAt);

  api.leaveCompanion(joined.companionId, { token: user.token, phase: 'cleanup' });
}

export function host() {
  const cuj = cujNames.host;
  const user = actor();
  const o = { cuj, token: user.token };
  const n = exec.scenario.iterationInTest;
  const startedAt = Date.now();
  const d = district(n + 3);
  const origin = pointNear(d, n + 9000);
  const dest = DISTRICTS[(n + 1) % DISTRICTS.length];

  const created = api.createCompanion({
    origin_name: `${d.name} CUJ`, origin_lat: origin.lat, origin_lng: origin.lng,
    dest_name: dest.name, dest_lat: dest.lat, dest_lng: dest.lng,
    departure_at: minutesFromNow(90), transport_type: 'TAXI', recruit_count: 3,
    content: `cuj host ${currentRunId}`,
  }, { ...o, step: 'CREATE' });
  step(cuj, 'CREATE', created.outcome.result);
  if (!created.ok) {
    finish(cuj, created.outcome.result === OUTCOME.BAD ? true : null, false, startedAt);
    return;
  }
  const companionId = created.data.id;
  sleep(think);

  const detail = api.companionDetail(companionId, { ...o, step: 'JOIN_VISIBILITY' });
  let ok = detail.ok && detail.data.current_count === 1;
  // 등록 응답에 chat_room_id가 없어(현재 구현) 내 채팅방 목록에서 찾는다.
  const rooms = api.myChatRooms({ ...o, step: 'FIND_ROOM' });
  const room = ((rooms.data && rooms.data.items) || []).find((it) => it.companion_id === companionId);
  step(cuj, 'FIND_ROOM', room ? OUTCOME.GOOD : OUTCOME.BAD);
  ok = ok && Boolean(room) && chat(cuj, user, room.id);
  finish(cuj, true, ok, startedAt);

  api.leaveCompanion(companionId, { token: user.token, phase: 'cleanup' }); // 혼자인 방장 → 채팅방 종료
}

export function taxi() {
  const cuj = cujNames.taxi;
  const user = actor();
  const o = { cuj, token: user.token };
  const n = exec.scenario.iterationInTest;
  const startedAt = Date.now();
  // 경로 6개 × 10분 슬롯: 같은 슬롯에 들어온 사용자끼리 기존 팟 합류가 일어나도록
  const from = DISTRICTS[n % DISTRICTS.length];
  const to = DISTRICTS[(n + 1) % DISTRICTS.length];
  const slot = new Date(Date.now() + 40 * 60 * 1000);
  slot.setUTCMinutes(slot.getUTCMinutes() - (slot.getUTCMinutes() % 10), 0, 0);
  const departure = `${new Date(slot.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 19)}+09:00`;

  let start = api.startTaxiPot({
    origin_name: `${from.name} 택시`, origin_lat: from.lat, origin_lng: from.lng,
    dest_name: `${to.name} 택시`, dest_lat: to.lat, dest_lng: to.lng, departure_at: departure,
  }, { ...o, step: 'MATCH' });
  if (start.outcome.code === 'MATCH_ALREADY_IN_PROGRESS') {
    cleanupTaxi(user); // 이전 실행 잔여 매칭
    finish(cuj, null, false, startedAt);
    return;
  }
  step(cuj, 'MATCH', start.outcome.result);
  if (!start.ok) {
    finish(cuj, start.outcome.result === OUTCOME.BAD ? true : null, false, startedAt);
    return;
  }
  const pot = start.data;
  taxiMatch.add(1, { match_result: pot.current_count > 1 ? 'JOINED_EXISTING' : 'CREATED_NEW' });
  sleep(think);

  const current = api.currentTaxiPot({ ...o, step: 'MATCH_STATUS' });
  const fresh = current.ok && current.data && current.data.id === pot.id && current.data.chat_room_id === pot.chat_room_id;
  taxiFresh.add(fresh ? 1 : 0);
  let ok = fresh && api.taxiPotDetail(pot.id, { ...o, step: 'MATCH_DETAIL' }).ok;
  ok = ok && chat(cuj, user, pot.chat_room_id);
  finish(cuj, true, ok, startedAt);

  api.leaveTaxiPot(pot.id, { token: user.token, phase: 'cleanup' });
}

function cleanupTaxi(user) {
  const current = api.currentTaxiPot({ token: user.token, phase: 'cleanup' });
  if (current.data && current.data.id) api.leaveTaxiPot(current.data.id, { token: user.token, phase: 'cleanup' });
}

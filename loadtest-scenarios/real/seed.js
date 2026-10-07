// 실서버 시드: 사용자 SQL 적용 후 1회 실행한다.
// 공개 API만 사용하므로 게시글·채팅방·참여 행이 서비스 코드와 같은 트랜잭션 경로로 만들어진다.
//   1) taxi·cuj·hotrow 풀 계좌 등록      PUT  /api/users/me/bank-account
//   2) chat 풀 채팅방 구성               POST /api/companion-posts (방장) → POST .../participants (멤버)
//   3) writer 풀 조회 대상 콘텐츠        POST /api/companion-posts, POST /api/community-posts (6개 거점에 분산)
// 결과(풀 범위, 채팅방 멤버, 콘텐츠 ID)는 handleSummary로 FIXTURE_OUT 파일에 쓴다.
import http from 'k6/http';
import { sleep } from 'k6';
import { httpBase, runId, commonOptions, envInt } from './lib/env.js';
import { configureApi, readData } from './lib/api.js';
import { loadUsers, defaultPoolSizes, poolRanges } from './lib/fixture.js';
import { DISTRICTS, district, pointNear, minutesFromNow } from './lib/geo.js';

const base = httpBase();
const currentRunId = runId('seed');
configureApi(base, currentRunId);
const users = loadUsers();

const ROOM_SIZE = envInt('ROOM_SIZE', 4, 2, 10); // 택시팟 정원 4 기준
const EXTRA_COMPANIONS = envInt('SEED_COMPANION_POSTS', 600, 0);
const COMMUNITY_POSTS = envInt('SEED_COMMUNITY_POSTS', 600, 0);
const BATCH = envInt('SEED_BATCH', 15, 1, 100); // nginx limit_req(20r/s, burst 40) 안쪽
const PAUSE_MS = envInt('SEED_BATCH_PAUSE_MS', 1000, 0);

export const options = {
  ...commonOptions('seed', currentRunId),
  setupTimeout: __ENV.SEED_TIMEOUT || '60m',
  scenarios: { seed: { executor: 'shared-iterations', vus: 1, iterations: 1, maxDuration: '1m' } },
};

function req(method, path, token, body) {
  return {
    method,
    url: `${base}${path}`,
    body: body === undefined ? null : JSON.stringify(body),
    params: {
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
        'X-Load-Test-Run-Id': currentRunId,
      },
      tags: { name: `${method} ${path.replace(/\d+/g, '{id}')}`, phase: 'seed' },
      timeout: '30s',
    },
  };
}

// 429·5xx는 최대 4회 재시도. 나머지 실패는 그대로 돌려준다.
function runBatches(requests, label) {
  const results = new Array(requests.length);
  let pending = requests.map((r, i) => i);
  for (let attempt = 0; attempt < 5 && pending.length > 0; attempt += 1) {
    const retry = [];
    for (let s = 0; s < pending.length; s += BATCH) {
      const chunk = pending.slice(s, s + BATCH);
      const responses = http.batch(chunk.map((i) => requests[i]));
      responses.forEach((res, k) => {
        const i = chunk[k];
        if (res.status === 429 || res.status === 0 || res.status >= 500) {
          retry.push(i);
        }
        results[i] = res;
      });
      if (PAUSE_MS > 0) sleep(PAUSE_MS / 1000);
    }
    pending = retry;
    if (retry.length > 0) {
      console.warn(`[seed] ${label}: retry ${retry.length} requests (attempt ${attempt + 1})`);
      sleep(3);
    }
  }
  const failed = results.filter((r) => r.status >= 300).length;
  console.log(`[seed] ${label}: ${results.length - failed}/${results.length} ok`);
  if (failed > 0) {
    const sample = results.find((r) => r.status >= 300);
    console.warn(`[seed] ${label}: first failure ${sample.status} ${String(sample.body).slice(0, 200)}`);
  }
  return results;
}

function companionBody(seed, recruitCount, transport) {
  const d = district(seed);
  const origin = pointNear(d, seed);
  const dest = pointNear(DISTRICTS[(seed + 3) % DISTRICTS.length], seed + 101, 0.01);
  return {
    origin_name: `${d.name} 부하테스트 ${seed}`,
    origin_lat: origin.lat,
    origin_lng: origin.lng,
    dest_name: `${DISTRICTS[(seed + 3) % DISTRICTS.length].name} 도착`,
    dest_lat: dest.lat,
    dest_lng: dest.lng,
    // 테스트 기간 동안 RECRUITING·미만료 상태를 유지하도록 충분히 먼 미래
    departure_at: minutesFromNow(envInt('SEED_DEPARTURE_OFFSET_MIN', 20 * 60) + (seed % 120)),
    transport_type: transport,
    recruit_count: recruitCount,
    content: `load-test ${currentRunId} #${seed}`,
  };
}

export function setup() {
  const sizes = defaultPoolSizes();
  const pools = poolRanges(sizes, users.length);
  const idx = (pool) => {
    const [s, e] = pools[pool];
    const out = [];
    for (let i = s; i < e; i += 1) out.push(i);
    return out;
  };

  // 1) 계좌 등록: 택시팟 매칭 선행조건(BANK_ACCOUNT_REQUIRED)
  const bankUsers = [...idx('taxi'), ...idx('cuj'), ...idx('hotrow')];
  runBatches(bankUsers.map((i) => req('PUT', '/api/users/me/bank-account', users[i].token,
    { bank_name: 'kakao', account_no: `3333${String(users[i].id).padStart(9, '0')}` })), 'bank-account');

  // 2) 채팅방: ROOM_SIZE명씩 묶어 첫 사람이 방장으로 글을 올리고 나머지가 참여
  const chat = idx('chat');
  const roomCount = Math.floor(chat.length / ROOM_SIZE);
  const hostResponses = runBatches(
    Array.from({ length: roomCount }, (_, r) => req('POST', '/api/companion-posts', users[chat[r * ROOM_SIZE]].token,
      companionBody(r, ROOM_SIZE - 1, ROOM_SIZE <= 4 ? 'TAXI' : 'SUBWAY'))),
    'chat-room hosts',
  );
  const rooms = [];
  const joinRequests = [];
  const joinMeta = [];
  hostResponses.forEach((res, r) => {
    const data = res.status === 201 ? readData(res) : null;
    if (!data) return;
    const room = { companion_id: data.id, room_id: null, members: [chat[r * ROOM_SIZE]] };
    rooms.push(room);
    for (let m = 1; m < ROOM_SIZE; m += 1) {
      const u = chat[r * ROOM_SIZE + m];
      joinRequests.push(req('POST', `/api/companion-posts/${data.id}/participants`, users[u].token));
      joinMeta.push({ room, user: u });
    }
  });
  runBatches(joinRequests, 'chat-room members').forEach((res, k) => {
    if (res.status !== 201) return;
    const data = readData(res);
    joinMeta[k].room.room_id = data.chat_room_id;
    joinMeta[k].room.members.push(joinMeta[k].user);
  });
  const completeRooms = rooms.filter((r) => r.room_id && r.members.length === ROOM_SIZE);

  // 3) 조회 대상 콘텐츠: writer가 6개 거점에 고르게 작성
  const writers = idx('writer');
  const companionRes = runBatches(
    Array.from({ length: EXTRA_COMPANIONS }, (_, k) => {
      const transport = ['TAXI', 'OWNED_CAR', 'SUBWAY', 'BUS'][k % 4];
      const recruit = transport === 'TAXI' || transport === 'OWNED_CAR' ? 3 : 9;
      return req('POST', '/api/companion-posts', users[writers[k % writers.length]].token,
        companionBody(10000 + k, recruit, transport));
    }),
    'companion posts',
  );
  const communityRes = runBatches(
    Array.from({ length: COMMUNITY_POSTS }, (_, k) => {
      const d = district(k);
      const p = pointNear(d, 20000 + k);
      return req('POST', '/api/community-posts', users[writers[k % writers.length]].token, {
        title: `${d.name} 출근길 ${k}`.slice(0, 30),
        content: `load-test ${currentRunId} 커뮤니티 글 ${k}`,
        lat: p.lat,
        lng: p.lng,
      });
    }),
    'community posts',
  );
  const ids = (list) => list.filter((r) => r.status === 201).map((r) => readData(r).id);

  return {
    created_at: new Date().toISOString(),
    run_id: currentRunId,
    base_url: base,
    room_size: ROOM_SIZE,
    pools,
    rooms: completeRooms,
    companions: ids(companionRes).concat(completeRooms.map((r) => r.companion_id)),
    community_posts: ids(communityRes),
  };
}

export default function () {}

export function handleSummary(data) {
  const fixture = data.setup_data;
  const out = __ENV.FIXTURE_OUT || decodeURIComponent(import.meta.resolve('./data/fixture.json').replace(/^file:\/\//, ''));
  if (!fixture) {
    return { stdout: 'setup_data is missing; seed failed before returning a fixture\n' };
  }
  const line = `[seed] rooms=${fixture.rooms.length} companions=${fixture.companions.length} community=${fixture.community_posts.length} → ${out}\n`;
  return { [out]: JSON.stringify(fixture), stdout: line };
}

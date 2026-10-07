// 「4단계 V2 트래픽 성장」의 세션당 13건 비율(목록·검색 14 / 상세 14 / 혼잡도 10.5 / 쓰기 3.5 RPS, 기준 45.5)을
// 실제 V1 API로 옮긴 요청 믹스. 가중치 합 91 = 출퇴근 왕복 기준 91 RPS에서 1 가중치 = 1 RPS.
//
// | 문서 분류      | V1 실제 API                                        | 가중치 |
// |---------------|----------------------------------------------------|-------|
// | 목록·검색 28   | GET /api/nearby-posts (첫 페이지 20, 커서 재검색 8)   | 28    |
// | 상세 28        | GET /api/companion-posts/{id} (익명 10, 로그인 10)    | 20    |
// |               | GET /api/community-posts/{id}, /{id}/comments      | 8     |
// | 혼잡도 21      | V1에 혼잡도 API 없음 → 지도 이동 GET /api/map-pins      | 21    |
// | 쓰기 7         | POST 댓글 4, POST 동행 모집글 3                        | 7     |
// | 기타(인증) 7   | GET /api/users/me 3, GET /api/chat-rooms 4          | 7     |
import exec from 'k6/execution';
import * as api from './api.js';
import { district, pointNear, viewportAround, rand, minutesFromNow, DISTRICTS } from './geo.js';
import { poolUser } from './fixture.js';

export const READ_MIX = [
  ['nearby_first', 20],
  ['nearby_next', 8],
  ['companion_detail_anon', 10],
  ['companion_detail_auth', 10],
  ['community_detail', 5],
  ['community_comments', 3],
  ['map_pins', 21],
  ['comment_write', 4],
  ['companion_write', 3],
  ['me', 3],
  ['chat_rooms', 4],
];

export function buildWheel(includeWrites) {
  const wheel = [];
  for (const [op, weight] of READ_MIX) {
    if (!includeWrites && op.endsWith('_write')) continue;
    for (let i = 0; i < weight; i += 1) wheel.push(op);
  }
  // 같은 연산이 연속으로 몰리지 않게 결정적으로 섞는다.
  for (let i = wheel.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rand(i + 17) * (i + 1));
    [wheel[i], wheel[j]] = [wheel[j], wheel[i]];
  }
  return wheel;
}

const cursors = {}; // VU 로컬: 거점별 마지막 next_cursor (재검색·스크롤)

export function runReadOp(op, ctx) {
  const { users, fixture, targets } = ctx;
  const n = exec.scenario.iterationInTest;
  const d = district(n);
  const center = pointNear(d, n);
  const opts = { cuj: 'COMPANION_PARTICIPANT', extraTags: ctx.tags || {} };

  switch (op) {
    case 'nearby_first': {
      const r = api.nearbyPosts(center, viewportAround(center), null, { ...opts, step: 'EXPLORE' });
      if (r.data && r.data.next_cursor) cursors[d.key] = { cursor: r.data.next_cursor, center };
      return r;
    }
    case 'nearby_next': {
      const c = cursors[d.key];
      if (!c) return api.nearbyPosts(center, viewportAround(center), null, { ...opts, step: 'EXPLORE' });
      const r = api.nearbyPosts(c.center, viewportAround(c.center), c.cursor, { ...opts, step: 'EXPLORE' });
      if (r.data && r.data.next_cursor) c.cursor = r.data.next_cursor;
      else delete cursors[d.key];
      return r;
    }
    case 'map_pins':
      // 지도를 조금씩 옮기는 사용자: 뷰포트를 매번 다르게
      return api.mapPins(viewportAround(pointNear(d, n * 3 + 1, 0.01)), { ...opts, step: 'EXPLORE' });
    case 'companion_detail_anon':
      return api.companionDetail(pick(targets.companions, n), { ...opts, step: 'DETAIL' });
    case 'companion_detail_auth':
      return api.companionDetail(pick(targets.companions, n), { ...opts, step: 'DETAIL', token: poolUser(users, fixture, 'writer', n).token });
    case 'community_detail':
      return api.communityDetail(pick(targets.community, n), { ...opts, cuj: 'COMMUNITY', step: 'DETAIL' });
    case 'community_comments':
      return api.communityComments(pick(targets.community, n), { ...opts, cuj: 'COMMUNITY', step: 'DETAIL' });
    case 'comment_write':
      return api.createComment(pick(targets.community, n), `load-test comment ${n}`, {
        ...opts, cuj: 'COMMUNITY', step: 'WRITE', token: poolUser(users, fixture, 'writer', n).token,
      });
    case 'companion_write': {
      const origin = pointNear(d, n + 50000);
      const dest = DISTRICTS[(n + 2) % DISTRICTS.length];
      return api.createCompanion({
        origin_name: `${d.name} 부하`, origin_lat: origin.lat, origin_lng: origin.lng,
        dest_name: dest.name, dest_lat: dest.lat, dest_lng: dest.lng,
        departure_at: minutesFromNow(600 + (n % 300)), transport_type: 'SUBWAY', recruit_count: 9,
        content: 'load-test write traffic',
      }, { ...opts, cuj: 'COMPANION_HOST', step: 'CREATE', token: poolUser(users, fixture, 'writer', n).token });
    }
    case 'me':
      return api.me({ ...opts, cuj: 'none', step: 'AUTH', token: poolUser(users, fixture, 'chat', n).token });
    case 'chat_rooms':
      return api.myChatRooms({ ...opts, cuj: 'none', step: 'CHAT_LIST', token: poolUser(users, fixture, 'chat', n).token });
    default:
      throw new Error(`unknown op ${op}`);
  }
}

function pick(list, n) {
  if (!list || list.length === 0) throw new Error('no target ids. Run seed.js or check map-pins discovery');
  return list[(n * 7919) % list.length];
}

// fixture가 없거나 오래됐을 때를 대비해 실제 지도 API로 대상 ID를 다시 수집한다.
export function discoverTargets(fixture) {
  const companions = new Set((fixture && fixture.companions) || []);
  const community = new Set((fixture && fixture.community_posts) || []);
  if (__ENV.DISCOVER_TARGETS !== 'false') {
    for (const d of DISTRICTS) {
      const r = api.mapPins(viewportAround(d, 2), { phase: 'setup' });
      for (const item of (r.data && r.data.items) || []) {
        if (item.type === 'COMPANION') companions.add(item.id);
        if (item.type === 'COMMUNITY') community.add(item.id);
      }
    }
  }
  return { companions: [...companions], community: [...community] };
}

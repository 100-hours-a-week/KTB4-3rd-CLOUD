// tools/make-users.py(users.json)와 seed.js(fixture.json) 산출물을 읽는다.
// 사용자 풀을 용도별로 나눠 같은 계정이 서로 다른 시나리오에서 상태를 오염시키지 않게 한다.
//   chat   : 채팅방 멤버 (연결 유지·메시지 부하)
//   hotrow : 인기 팟 좌석 경합 (동행 참여 / 택시팟 동시 매칭)
//   taxi   : 택시팟 매칭 부하 (계좌 등록 완료)
//   cuj    : CUJ E2E 측정 사용자 (계좌 등록 완료)
//   writer : 조회 대상 콘텐츠 작성자 + 쓰기 트래픽
import { SharedArray } from 'k6/data';

export const POOL_ORDER = ['chat', 'hotrow', 'taxi', 'cuj', 'writer'];

export function defaultPoolSizes() {
  return {
    chat: Number(__ENV.POOL_CHAT || 1800),
    hotrow: Number(__ENV.POOL_HOTROW || 200),
    taxi: Number(__ENV.POOL_TAXI || 200),
    cuj: Number(__ENV.POOL_CUJ || 300),
    writer: Number(__ENV.POOL_WRITER || 100),
  };
}

export function poolRanges(sizes, total) {
  const ranges = {};
  let cursor = 0;
  for (const name of POOL_ORDER) {
    const size = sizes[name] || 0;
    ranges[name] = [cursor, cursor + size];
    cursor += size;
  }
  if (cursor > total) {
    throw new Error(`pool sizes need ${cursor} users but users.json has ${total}. Run make-users.py --count ${cursor}`);
  }
  return ranges;
}

export function loadUsers(path) {
  return new SharedArray('lt-users', () => {
    const parsed = JSON.parse(open(path || __ENV.USERS_FILE || import.meta.resolve('../data/users.json')));
    const now = Math.floor(Date.now() / 1000);
    if (parsed.expires_at && parsed.expires_at - now < 600) {
      throw new Error('users.json tokens expire within 10 minutes. Re-run make-users.py --tokens-only');
    }
    return parsed.users;
  });
}

export function loadFixture(required = true) {
  const arr = new SharedArray('lt-fixture', () => {
    const path = __ENV.FIXTURE_FILE || import.meta.resolve('../data/fixture.json');
    let raw;
    try {
      raw = open(path);
    } catch (e) {
      if (required) throw new Error(`${path} not found. Run seed.js first.`);
      return [null];
    }
    return [JSON.parse(raw)];
  });
  return arr[0];
}

export function poolUser(users, fixture, pool, index) {
  const [start, end] = fixture.pools[pool];
  const size = end - start;
  if (size <= 0) {
    throw new Error(`pool ${pool} is empty`);
  }
  const i = start + (index % size);
  return { index: i, ...users[i] };
}

export function poolSize(fixture, pool) {
  const [start, end] = fixture.pools[pool];
  return end - start;
}

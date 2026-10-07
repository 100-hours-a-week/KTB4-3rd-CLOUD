// 모여타 V1 백엔드(KTB4-3rd-BE) 실제 API를 호출하는 클라이언트.
// 경로·필드·상태코드는 Controller/Service 코드와 API 명세 기준이다.
// - JSON은 SNAKE_CASE (spring.jackson.property-naming-strategy)
// - 성공: { message, data }, 실패: { message, error: { code } }
// - URL에 실제 ID가 들어가므로 k6 `name` 태그로 경로를 정규화해 시계열 카디널리티를 막는다.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { recordOutcome, OUTCOME } from './slo.js';

// SLI 문서 2-2·3-2·4-2의 응답 분류를 엔드포인트별 규칙으로 고정한다.
export const RULES = {
  mapPins: { good: [200], invalid: ['VALIDATION_ERROR', 'MALFORMED_REQUEST'] },
  nearby: { good: [200], invalid: ['VALIDATION_ERROR', 'INVALID_CURSOR', 'COMMUNITY_VIEWPORT_OUT_OF_RANGE', 'COMMUNITY_VIEWPORT_TOO_LARGE'] },
  companionDetail: { good: [200], rejected: ['COMPANION_POST_NOT_FOUND', 'COMPANION_POST_CANCELED'] },
  communityDetail: { good: [200], rejected: ['COMMUNITY_POST_NOT_FOUND', 'COMMUNITY_POST_DELETED'] },
  communityComments: { good: [200] },
  companionCreate: {
    good: [201],
    rejected: ['COMPANION_POST_DEPARTURE_AT_PAST', 'COMPANION_POST_ORIGIN_DEST_SAME', 'COMPANION_POST_RECRUIT_COUNT_OUT_OF_RANGE'],
  },
  companionJoin: { good: [201], rejected: ['ALREADY_PARTICIPATING', 'COMPANION_NOT_JOINABLE', 'COMPANION_NOT_FOUND'] },
  companionLeave: { good: [200, 204], rejected: ['NOT_PARTICIPATING'] },
  communityCreate: { good: [201] },
  commentCreate: { good: [201], rejected: ['COMMUNITY_POST_NOT_FOUND', 'COMMUNITY_COMMENT_POST_DELETED'] },
  chatRoomDetail: { good: [200], rejected: ['CHATROOM_NOT_FOUND'] },
  chatMessages: { good: [200], rejected: ['CHATROOM_NOT_FOUND'] },
  chatRooms: { good: [200] },
  me: { good: [200] },
  bankAccount: { good: [200, 201, 204] },
  // MATCH_BUSY는 409지만 서버 동시성 처리 실패이므로 Bad event (SLI 문서 6-2)
  taxiStart: {
    good: [201],
    bad: ['MATCH_BUSY'],
    rejected: ['BANK_ACCOUNT_REQUIRED', 'MATCH_ALREADY_IN_PROGRESS', 'DEPARTURE_TIME_PASSED', 'DEPARTURE_TIME_TOO_FAR', 'SAME_ORIGIN_DEST'],
  },
  taxiCurrent: { good: [200] },
  taxiDetail: { good: [200], rejected: ['TAXI_POT_NOT_FOUND'] },
  taxiLeave: { good: [200, 204], rejected: ['TAXI_POT_NOT_FOUND'] },
};

let base = '';
let runIdValue = '';

export function configureApi(baseUrl, currentRunId) {
  base = baseUrl;
  runIdValue = currentRunId;
}

function phaseOf() {
  try {
    return exec.scenario.name === 'measure' || exec.scenario.name.startsWith('measure') ? 'measure' : exec.scenario.name;
  } catch (_) {
    return 'setup';
  }
}

function request(method, path, routeName, { token, body, rule, sliClass, cuj, step, phase, extraTags } = {}) {
  const headers = {
    Accept: 'application/json',
    'X-Load-Test-Run-Id': runIdValue,
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  let payload = null;
  if (body !== undefined) {
    payload = JSON.stringify(body);
    headers['Content-Type'] = 'application/json';
  }
  const tags = {
    name: `${method} ${routeName}`,
    api: `${method} ${routeName}`,
    sli_class: sliClass || (method === 'GET' ? 'read' : 'write'),
    cuj: cuj || 'none',
    step: step || 'none',
    phase: phase || phaseOf(),
    ...(extraTags || {}),
  };
  const response = http.request(method, `${base}${path}`, payload, {
    headers,
    tags,
    timeout: __ENV.REQUEST_TIMEOUT || '10s',
    // 상태코드 판정은 SLI 규칙(recordOutcome)으로 하고, http_req_failed는 5xx·타임아웃만 실패로 본다.
    responseCallback: http.expectedStatuses({ min: 200, max: 499 }),
  });
  const outcome = recordOutcome(response, rule || { good: [200] }, tags);
  check(response, { [`${tags.api} is SLI good or excluded`]: () => outcome.result !== OUTCOME.BAD }, tags);
  return { response, outcome, ok: outcome.result === OUTCOME.GOOD, data: safeData(response) };
}

function safeData(response) {
  if (!response.body || response.status >= 300) {
    return null;
  }
  try {
    return response.json('data');
  } catch (_) {
    return null;
  }
}

function qs(params) {
  return Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');
}

// ---------- 참여자 CUJ: 탐색·상세 ----------
export function mapPins(viewport, opts = {}) {
  return request('GET', `/api/map-pins?${qs(viewport)}`, '/api/map-pins', { ...opts, rule: RULES.mapPins });
}

export function nearbyPosts(center, viewport, cursor, opts = {}) {
  const query = qs({ lat: center.lat, lng: center.lng, ...viewport, cursor });
  return request('GET', `/api/nearby-posts?${query}`, '/api/nearby-posts', { ...opts, rule: RULES.nearby });
}

export function companionDetail(id, opts = {}) {
  return request('GET', `/api/companion-posts/${id}`, '/api/companion-posts/{companion_id}', { ...opts, rule: RULES.companionDetail });
}

export function communityDetail(id, opts = {}) {
  return request('GET', `/api/community-posts/${id}`, '/api/community-posts/{post_id}', { ...opts, rule: RULES.communityDetail });
}

export function communityComments(id, opts = {}) {
  return request('GET', `/api/community-posts/${id}/comments`, '/api/community-posts/{post_id}/comments', { ...opts, rule: RULES.communityComments });
}

export function joinCompanion(id, opts = {}) {
  return request('POST', `/api/companion-posts/${id}/participants`, '/api/companion-posts/{companion_id}/participants', { ...opts, rule: RULES.companionJoin });
}

export function leaveCompanion(id, opts = {}) {
  return request('DELETE', `/api/companion-posts/${id}/participants/me`, '/api/companion-posts/{companion_id}/participants/me', { ...opts, rule: RULES.companionLeave });
}

// ---------- 모집자 CUJ ----------
export function createCompanion(body, opts = {}) {
  return request('POST', '/api/companion-posts', '/api/companion-posts', { ...opts, body, rule: RULES.companionCreate });
}

export function createCommunityPost(body, opts = {}) {
  return request('POST', '/api/community-posts', '/api/community-posts', { ...opts, body, rule: RULES.communityCreate });
}

export function createComment(postId, content, opts = {}) {
  return request('POST', `/api/community-posts/${postId}/comments`, '/api/community-posts/{post_id}/comments', { ...opts, body: { content }, rule: RULES.commentCreate });
}

// ---------- 채팅 REST ----------
export function chatRoomDetail(roomId, opts = {}) {
  return request('GET', `/api/chat-rooms/${roomId}`, '/api/chat-rooms/{room_id}', { ...opts, rule: RULES.chatRoomDetail });
}

export function chatMessages(roomId, cursor, opts = {}) {
  const query = cursor ? `?${qs({ cursor })}` : '';
  return request('GET', `/api/chat-rooms/${roomId}/messages${query}`, '/api/chat-rooms/{room_id}/messages', { ...opts, rule: RULES.chatMessages });
}

export function myChatRooms(opts = {}) {
  return request('GET', '/api/chat-rooms', '/api/chat-rooms', { ...opts, rule: RULES.chatRooms });
}

export function me(opts = {}) {
  return request('GET', '/api/users/me', '/api/users/me', { ...opts, rule: RULES.me });
}

export function registerBankAccount(opts = {}) {
  return request('PUT', '/api/users/me/bank-account', '/api/users/me/bank-account', {
    ...opts,
    body: { bank_name: 'kakao', account_no: '3333-00-0000000' },
    rule: RULES.bankAccount,
  });
}

// ---------- 택시팟 CUJ ----------
export function startTaxiPot(body, opts = {}) {
  return request('POST', '/api/taxi-pots', '/api/taxi-pots', { ...opts, body, rule: RULES.taxiStart });
}

export function currentTaxiPot(opts = {}) {
  return request('GET', '/api/users/me/current-taxi-pot', '/api/users/me/current-taxi-pot', { ...opts, rule: RULES.taxiCurrent });
}

export function taxiPotDetail(id, opts = {}) {
  return request('GET', `/api/taxi-pots/${id}`, '/api/taxi-pots/{companion_id}', { ...opts, rule: RULES.taxiDetail });
}

export function leaveTaxiPot(id, opts = {}) {
  return request('DELETE', `/api/taxi-pots/${id}/participants/me`, '/api/taxi-pots/{companion_id}/participants/me', { ...opts, rule: RULES.taxiLeave });
}

// http.batch로 같은 행에 동시 도착시키기 위한 요청 빌더 (hot-row 전용)
export function batchJoinRequest(id, token, tags) {
  return {
    method: 'POST',
    url: `${base}/api/companion-posts/${id}/participants`,
    body: null,
    params: {
      headers: { Accept: 'application/json', Authorization: `Bearer ${token}`, 'X-Load-Test-Run-Id': runIdValue },
      tags: { name: 'POST /api/companion-posts/{companion_id}/participants', api: 'POST /api/companion-posts/{companion_id}/participants', sli_class: 'write', ...tags },
      timeout: __ENV.REQUEST_TIMEOUT || '30s',
      responseCallback: http.expectedStatuses({ min: 200, max: 499 }),
    },
  };
}

export function batchTaxiRequest(body, token, tags) {
  return {
    method: 'POST',
    url: `${base}/api/taxi-pots`,
    body: JSON.stringify(body),
    params: {
      headers: { Accept: 'application/json', 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'X-Load-Test-Run-Id': runIdValue },
      tags: { name: 'POST /api/taxi-pots', api: 'POST /api/taxi-pots', sli_class: 'write', ...tags },
      timeout: __ENV.REQUEST_TIMEOUT || '60s',
      responseCallback: http.expectedStatuses({ min: 200, max: 499 }),
    },
  };
}

export function readData(response) {
  return safeData(response);
}

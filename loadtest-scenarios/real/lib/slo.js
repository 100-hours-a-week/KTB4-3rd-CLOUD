// 「V1의 핵심 사용자 여정 별로 SLI/SLO 정의」 문서의 7장 초기 SLO를 k6 판정 기준으로 옮긴 파일.
// 숫자를 바꾸려면 문서와 이 파일을 함께 바꾼다. 실행 시 환경변수로 덮어쓸 수 있다.
import { Counter, Rate, Trend } from 'k6/metrics';
import { envFloat, envInt } from './env.js';

export const SLO = {
  availability: envFloat('SLO_AVAILABILITY', 0.999, 0, 1), // 핵심 REST 기술 가용성 99.9%
  readP95: envInt('SLO_READ_P95_MS', 1000), // 조회 95% ≤ 1초
  readP99: envInt('SLO_READ_P99_MS', 2500), // 조회 99% ≤ 2.5초
  writeP95: envInt('SLO_WRITE_P95_MS', 1500), // 쓰기·매칭 95% ≤ 1.5초
  writeP99: envInt('SLO_WRITE_P99_MS', 3000), // 쓰기·매칭 99% ≤ 3초
  wsConnect: envFloat('SLO_WS_CONNECT', 0.999, 0, 1), // WebSocket 연결 성공률 99.9%
  wsConnectTimeoutMs: envInt('SLO_WS_CONNECT_TIMEOUT_MS', 3000), // 3초 안에 CONNECTED
  chatPersist: envFloat('SLO_CHAT_PERSIST', 0.999, 0, 1), // 메시지 저장(=echo 수신) 99.9%
  chatDeliveryP99: envFloat('SLO_CHAT_DELIVERY_P99_S', 2), // 전달 99% ≤ 2초
  cujCompletion: envFloat('SLO_CUJ_COMPLETION', 0.97, 0, 1), // CUJ E2E 97%
  consistency: 1, // 참여·등록·택시팟 정합성 100%
};

// SLI 문서 6장: good / bad / 분모 제외(사용자 입력·인증·도메인 거절)
export const OUTCOME = {
  GOOD: 'SUCCESS',
  BAD: 'TECHNICAL_FAILURE',
  REJECTED: 'BUSINESS_REJECTION',
  INVALID: 'INVALID_REQUEST',
};

export const sliAvailability = new Rate('sli_availability'); // good=1, bad=0, 제외 이벤트는 기록하지 않음
export const sliOutcome = new Counter('sli_outcome'); // {result, error_code} 별 건수
export const businessRejections = new Counter('business_rejections');
export const rateLimited = new Counter('nginx_rate_limited'); // 429: 테스트 환경 limit_req 미해제 신호
export const testDataErrors = new Counter('test_data_errors'); // 401·403·404: 토큰/시드 문제 신호
export const apiDuration = new Trend('api_duration', true); // 유효 이벤트만 담는 지연(제외 이벤트 미포함)

export function errorCode(response) {
  if (!response || !response.body) {
    return '';
  }
  try {
    const code = response.json('error.code');
    return typeof code === 'string' ? code : '';
  } catch (_) {
    return '';
  }
}

// rule = { good: [201], rejected: ['ALREADY_PARTICIPATING', ...], bad: ['MATCH_BUSY'], invalid: [...] }
export function classify(response, rule) {
  const status = response.status;
  const code = errorCode(response);
  if ((rule.bad || []).includes(code)) {
    return { result: OUTCOME.BAD, code };
  }
  if ((rule.good || [200]).includes(status)) {
    return { result: OUTCOME.GOOD, code: '' };
  }
  if (status === 0 || status >= 500) {
    return { result: OUTCOME.BAD, code: code || (status === 0 ? 'TIMEOUT_OR_RESET' : `HTTP_${status}`) };
  }
  if (status === 429) {
    return { result: OUTCOME.BAD, code: 'NGINX_RATE_LIMITED' };
  }
  if ((rule.rejected || []).includes(code)) {
    return { result: OUTCOME.REJECTED, code };
  }
  if ((rule.invalid || []).includes(code) || status === 400 || status === 422) {
    return { result: OUTCOME.INVALID, code: code || `HTTP_${status}` };
  }
  if (status === 401 || status === 403 || status === 404) {
    return { result: OUTCOME.INVALID, code: code || `HTTP_${status}`, testData: true };
  }
  return { result: OUTCOME.BAD, code: code || `UNEXPECTED_${status}` };
}

export function recordOutcome(response, rule, tags) {
  const outcome = classify(response, rule);
  const labels = { ...tags, result: outcome.result, error_code: outcome.code };
  sliOutcome.add(1, labels);
  if (outcome.result === OUTCOME.GOOD || outcome.result === OUTCOME.BAD) {
    sliAvailability.add(outcome.result === OUTCOME.GOOD ? 1 : 0, tags);
    apiDuration.add(response.timings.duration, tags);
  }
  if (outcome.result === OUTCOME.REJECTED) {
    businessRejections.add(1, labels);
  }
  if (outcome.code === 'NGINX_RATE_LIMITED') {
    rateLimited.add(1, tags);
  }
  if (outcome.testData) {
    testDataErrors.add(1, labels);
  }
  return outcome;
}

// 시나리오 공통 SLO threshold. phase 태그로 warm-up 구간을 판정에서 뺀다.
export function restThresholds(phase = 'measure') {
  return {
    [`sli_availability{phase:${phase}}`]: [`rate>=${SLO.availability}`],
    [`api_duration{phase:${phase},sli_class:read}`]: [`p(95)<${SLO.readP95}`, `p(99)<${SLO.readP99}`],
    [`api_duration{phase:${phase},sli_class:write}`]: [`p(95)<${SLO.writeP95}`, `p(99)<${SLO.writeP99}`],
    [`nginx_rate_limited{phase:${phase}}`]: ['count==0'],
    [`test_data_errors{phase:${phase}}`]: ['count==0'],
  };
}

export function wsThresholds(phase = 'measure') {
  return {
    [`stomp_connected{phase:connect}`]: [`rate>=${SLO.wsConnect}`],
    [`stomp_connect_duration{phase:connect}`]: [`p(99)<${SLO.wsConnectTimeoutMs}`],
    [`chat_delivery_success{phase:${phase}}`]: [`rate>=${SLO.chatPersist}`],
    [`chat_delivery_seconds{phase:${phase}}`]: [`p(99)<${SLO.chatDeliveryP99}`],
    ws_unexpected_close: ['count==0'],
  };
}

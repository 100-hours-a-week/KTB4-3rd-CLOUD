// 실서버(모여타 V1 Spring Boot) 부하테스트 공통 환경값.
// 기존 ../../lib/config.js의 숫자·기간 파서를 그대로 재사용하고,
// 실서버 접속 규칙(HTTP/WS 허용 여부, 대상 호스트 확인)만 이 파일에서 정의한다.
import {
  confirmLoadTestTarget,
  durationToMilliseconds,
  envBool,
  envDuration,
  envFloat,
  envInt,
} from '../../lib/config.js';

export { durationToMilliseconds, envBool, envDuration, envFloat, envInt };

function isPrivateHost(host) {
  return host === 'localhost' ||
    host.startsWith('127.') ||
    host.startsWith('10.') ||
    host.startsWith('192.168.') ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
}

// 현재 V1 nginx는 인증서가 없어 80(HTTP)만 열려 있을 수 있다.
// 평문 대상은 ALLOW_PLAIN_TRANSPORT=true일 때만 허용해 실수로 운영 도메인에 쏘는 것을 막는다.
export function targetUrl(name, secure, plain) {
  const raw = __ENV[name];
  if (!raw) {
    throw new Error(`${name} is required (예: ${secure}://moyeota.example.com)`);
  }
  const match = new RegExp(`^(${secure}|${plain})://([^/:]+)`, 'i').exec(raw);
  if (!match) {
    throw new Error(`${name} must start with ${secure}:// or ${plain}://; received ${raw}`);
  }
  if (match[1].toLowerCase() === plain && !envBool('ALLOW_PLAIN_TRANSPORT', false)) {
    throw new Error(`${name} uses ${plain}://. Set ALLOW_PLAIN_TRANSPORT=true only for the HTTP-only V1 test server.`);
  }
  if (isPrivateHost(match[2]) && !envBool('ALLOW_NON_PUBLIC_TARGET', false)) {
    throw new Error(`${name} must be the public endpoint that goes through nginx. Set ALLOW_NON_PUBLIC_TARGET=true only for a local dry run.`);
  }
  return raw.replace(/\/$/, '');
}

export function httpBase() {
  const base = targetUrl('BASE_URL', 'https', 'http');
  confirmLoadTestTarget(base);
  return base;
}

export function wsBase() {
  const explicit = __ENV.WS_URL;
  const ws = explicit
    ? targetUrl('WS_URL', 'wss', 'ws')
    : targetUrl('BASE_URL', 'https', 'http').replace(/^http/i, 'ws');
  confirmLoadTestTarget(ws);
  return ws;
}

export function runId(prefix) {
  return __ENV.RUN_ID || `${prefix}-${Date.now()}`;
}

export function commonOptions(testType, currentRunId) {
  return {
    discardResponseBodies: false,
    insecureSkipTLSVerify: envBool('INSECURE_SKIP_TLS_VERIFY', false),
    summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    tags: { run_id: currentRunId, test_type: testType },
  };
}

export function arrivalVus(rate, perRequestSeconds = 1.5) {
  const pre = envInt('PRE_ALLOCATED_VUS', Math.max(20, Math.ceil(rate * perRequestSeconds)));
  const max = envInt('MAX_VUS', Math.max(pre, Math.ceil(rate * 6)));
  return { preAllocatedVUs: pre, maxVUs: max };
}

// "45,91,137,180" 형태의 단계 RPS 목록.
export function parseSteps(name, fallback) {
  const raw = __ENV[name] || fallback;
  const steps = String(raw).split(',').map((v) => Number(v.trim())).filter((v) => v > 0);
  if (steps.length === 0) {
    throw new Error(`${name} must be a comma separated list of positive numbers`);
  }
  return steps;
}

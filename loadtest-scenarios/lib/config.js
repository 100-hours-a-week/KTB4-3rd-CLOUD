function readNumber(name, fallback, minimum, maximum) {
  const raw = __ENV[name];
  const value = raw === undefined || raw === '' ? fallback : Number(raw);

  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}; received ${raw}`);
  }

  return value;
}

export function envInt(name, fallback, minimum = 1, maximum = Number.MAX_SAFE_INTEGER) {
  const value = readNumber(name, fallback, minimum, maximum);
  if (!Number.isInteger(value)) {
    throw new Error(`${name} must be an integer; received ${value}`);
  }
  return value;
}

export function envFloat(name, fallback, minimum = 0, maximum = Number.MAX_VALUE) {
  return readNumber(name, fallback, minimum, maximum);
}

export function envBool(name, fallback = false) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }

  const normalized = raw.toLowerCase();
  if (['true', '1', 'yes'].includes(normalized)) {
    return true;
  }
  if (['false', '0', 'no'].includes(normalized)) {
    return false;
  }
  throw new Error(`${name} must be true or false; received ${raw}`);
}

export function envDuration(name, fallback) {
  const value = __ENV[name] || fallback;
  if (!/^\d+(ms|s|m|h)$/.test(value)) {
    throw new Error(`${name} must use a k6 duration such as 30s, 5m, or 1h; received ${value}`);
  }
  return value;
}

export function durationToMilliseconds(value) {
  const match = /^(\d+)(ms|s|m|h)$/.exec(value);
  if (!match) {
    throw new Error(`Invalid duration: ${value}`);
  }

  const multipliers = { ms: 1, s: 1000, m: 60000, h: 3600000 };
  return Number(match[1]) * multipliers[match[2]];
}

function isPrivateHost(host) {
  return host === 'localhost' ||
    host === '::1' ||
    host.startsWith('127.') ||
    host.startsWith('10.') ||
    host.startsWith('192.168.') ||
    host.startsWith('169.254.') ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    host.endsWith('.local') ||
    host.endsWith('.internal');
}

export function requirePublicUrl(name, protocol) {
  const raw = __ENV[name];
  if (!raw) {
    throw new Error(`${name} is required`);
  }

  const match = new RegExp(`^${protocol}:\\/\\/([^/:]+)`, 'i').exec(raw);
  if (!match) {
    throw new Error(`${name} must start with ${protocol}://; received ${raw}`);
  }

  if (isPrivateHost(match[1]) && !envBool('ALLOW_NON_PUBLIC_TARGET', false)) {
    throw new Error(`${name} must use the public test endpoint. Set ALLOW_NON_PUBLIC_TARGET=true only for T0 generator validation.`);
  }

  return raw.replace(/\/$/, '');
}

function hostnameOf(url) {
  const match = /^[a-z]+:\/\/([^/:]+)/i.exec(url);
  if (!match) {
    throw new Error(`Cannot determine hostname from ${url}`);
  }
  return match[1].toLowerCase();
}

export function confirmLoadTestTarget(url) {
  const actualHost = hostnameOf(url);
  const confirmedHost = (__ENV.CONFIRM_TARGET_HOST || '').toLowerCase();
  if (!confirmedHost || confirmedHost !== actualHost) {
    throw new Error(
      `Refusing to generate load for ${actualHost}. ` +
      `Set CONFIRM_TARGET_HOST=${actualHost} after confirming this is an authorized load-test target.`,
    );
  }
  return actualHost;
}

export function runId(defaultPrefix) {
  return __ENV.RUN_ID || `${defaultPrefix}-${Date.now()}`;
}

export function arrivalRateVus(rate) {
  const preAllocatedVUs = envInt(
    'PRE_ALLOCATED_VUS',
    Math.max(20, Math.ceil(rate * 1.5)),
  );
  const maxVUs = envInt(
    'MAX_VUS',
    Math.max(preAllocatedVUs, Math.ceil(rate * 5)),
  );

  if (maxVUs < preAllocatedVUs) {
    throw new Error('MAX_VUS must be greater than or equal to PRE_ALLOCATED_VUS');
  }

  return { preAllocatedVUs, maxVUs };
}

export function httpThresholds(phase, scenarioName, includeDroppedIterations = true) {
  const maxErrorRate = envFloat('MAX_ERROR_RATE', 0.05, 0, 1);
  const minCheckRate = envFloat('MIN_CHECK_RATE', 0.95, 0, 1);
  const thresholds = {
    [`http_req_failed{phase:${phase}}`]: [`rate<${maxErrorRate}`],
    [`checks{phase:${phase}}`]: [`rate>${minCheckRate}`],
  };
  if (includeDroppedIterations) {
    thresholds[`dropped_iterations{scenario:${scenarioName}}`] = ['count==0'];
  }

  if (__ENV.P95_MS) {
    thresholds[`http_req_duration{phase:${phase}}`] = [
      `p(95)<${envInt('P95_MS', 1000)}`,
    ];
  }
  if (__ENV.P99_MS) {
    const key = `http_req_duration{phase:${phase}}`;
    thresholds[key] = thresholds[key] || [];
    thresholds[key].push(`p(99)<${envInt('P99_MS', 3000)}`);
  }

  return thresholds;
}

export function v2SloThresholds(phase, scenarioName, includeDroppedIterations = true) {
  // V1 초기 SLO (「V1의 핵심 사용자 여정 별로 SLI/SLO 정의」 7장): 가용성 99.9%,
  // 조회 95% ≤ 1s·99% ≤ 2.5s, 쓰기·매칭 95% ≤ 1.5s·99% ≤ 3s
  const maxErrorRate = envFloat('MAX_ERROR_RATE', 0.001, 0, 1);
  const minCheckRate = envFloat('MIN_CHECK_RATE', 0.999, 0, 1);
  const readP95 = envInt('READ_P95_MS', 1000);
  const readP99 = envInt('READ_P99_MS', 2500);
  const writeP95 = envInt('WRITE_P95_MS', 1500);
  const writeP99 = envInt('WRITE_P99_MS', 3000);
  const thresholds = {
    [`http_req_failed{phase:${phase}}`]: [`rate<${maxErrorRate}`],
    [`business_errors{phase:${phase}}`]: [`rate<${maxErrorRate}`],
    [`checks{phase:${phase}}`]: [`rate>${minCheckRate}`],
    [`http_req_duration{phase:${phase},sli_class:read}`]: [
      `p(95)<${readP95}`,
      `p(99)<${readP99}`,
    ],
    [`http_req_duration{phase:${phase},sli_class:write}`]: [
      `p(95)<${writeP95}`,
      `p(99)<${writeP99}`,
    ],
  };

  if (includeDroppedIterations) {
    thresholds[`dropped_iterations{scenario:${scenarioName}}`] = ['count==0'];
  }
  return thresholds;
}

export function commonOptions(testType, currentRunId) {
  return {
    discardResponseBodies: envBool('DISCARD_RESPONSE_BODIES', true),
    insecureSkipTLSVerify: envBool('INSECURE_SKIP_TLS_VERIFY', false),
    noConnectionReuse: envBool('NO_CONNECTION_REUSE', false),
    tags: {
      run_id: currentRunId,
      test_type: testType,
    },
  };
}

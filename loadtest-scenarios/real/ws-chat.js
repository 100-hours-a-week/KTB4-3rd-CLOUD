// S2. WebSocket 연결 증가 / S3. 채팅 메시지 처리·저장
//   MESSAGE_RATE=0  → 연결 수립·유지만 (행사 1,800연결, 첫 5분 6연결/s)
//   MESSAGE_RATE=36 → 행사 peak 36 msg/s 저장·브로드캐스트 (자기 echo로 저장+전달 성공 판정)
// 각 VU는 seed.js가 만든 채팅방의 실제 참여자 1명이다. 비참여자 구독은 서버가 조용히 버리므로
// 반드시 fixture의 방-멤버 매핑을 사용한다.
//
// k6 run -e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host> \
//        -e TARGET_CONNECTIONS=1800 -e CONNECT_RATE=6 -e HOLD=10m -e MESSAGE_RATE=36 real/ws-chat.js
import exec from 'k6/execution';
import { sleep } from 'k6';
import { wsBase, httpBase, runId, commonOptions, envInt, envFloat, envDuration, durationToMilliseconds } from './lib/env.js';
import { wsThresholds } from './lib/slo.js';
import { holdChatSession } from './lib/stomp.js';
import { loadUsers, loadFixture } from './lib/fixture.js';

httpBase();
const wsUrl = wsBase();
const users = loadUsers();
const fixture = loadFixture(true);

const members = [];
for (const room of fixture.rooms) {
  for (const userIndex of room.members) members.push({ userIndex, roomId: room.room_id });
}
const target = envInt('TARGET_CONNECTIONS', Math.min(1800, members.length));
if (target > members.length) {
  throw new Error(`TARGET_CONNECTIONS=${target} > seeded chat members ${members.length}. POOL_CHAT을 늘려 seed를 다시 실행하세요.`);
}
const connectRate = envFloat('CONNECT_RATE', 6, 0.1);
const messageRate = envFloat('MESSAGE_RATE', 0, 0);
const rampMs = Math.ceil((target / connectRate)) * 1000;
const holdMs = durationToMilliseconds(envDuration('HOLD', '10m'));
const rampDownMs = durationToMilliseconds(envDuration('RAMP_DOWN', '30s'));
const sendIntervalMs = messageRate > 0 ? Math.round((target / messageRate) * 1000) : 0;
const reconnectDelay = envInt('RECONNECT_DELAY_MS', 3000, 0) / 1000;
const currentRunId = runId(`ws-${target}c-${messageRate}mps`);

function phase() {
  const t = exec.instance.currentTestRunDuration;
  if (t < rampMs) return 'ramp';
  if (t < rampMs + holdMs) return 'measure';
  return 'rampdown';
}

export const options = {
  ...commonOptions('ws-chat', currentRunId),
  scenarios: {
    ws: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${rampMs / 1000}s`, target },
        { duration: `${holdMs / 1000}s`, target },
        { duration: `${rampDownMs / 1000}s`, target: 0 },
      ],
      gracefulRampDown: '5s',
      exec: 'chatter',
    },
  },
  thresholds: wsThresholds('measure'),
};

export function chatter() {
  const member = members[(exec.vu.idInTest - 1) % members.length];
  const user = users[member.userIndex];
  const now = exec.instance.currentTestRunDuration;
  // 연결은 hold 종료 시점까지 유지. 끊기면(예기치 않은 종료) 재접속도 측정된다.
  const lifetimeMs = Math.max(5000, rampMs + holdMs - now);
  holdChatSession({
    wsUrl,
    runIdValue: currentRunId,
    token: user.token,
    roomId: member.roomId,
    lifetimeMs,
    sendIntervalMs,
    phase,
  });
  if (exec.instance.currentTestRunDuration < rampMs + holdMs) {
    sleep(reconnectDelay);
  } else {
    sleep(rampDownMs / 1000);
  }
}

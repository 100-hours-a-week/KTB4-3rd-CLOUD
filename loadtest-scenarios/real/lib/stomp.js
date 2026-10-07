// 모여타 채팅 경로(STOMP over raw WebSocket)를 실제 서버 계약대로 재현한다.
//   endpoint  : /api/wss (SockJS 없음, WebSocketConfig.ENDPOINT)
//   CONNECT   : native header "Authorization: Bearer <JWT>" (StompAuthChannelInterceptor)
//   SUBSCRIBE : /sub/chat/{room_id}  → 활성 참여자인지 DB 조회, 비참여자는 프레임을 조용히 폐기
//   SEND      : /pub/chat/{room_id}  body {client_message_id, content} → DB 저장 후 같은 방 구독자에게 MESSAGE
//   MESSAGE   : MessageItem {id, type, sender, content, created_at} — client_message_id는 내려오지 않으므로
//               전달 확인은 고유 content로 매칭한다.
import ws from 'k6/ws';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';
import { SLO } from './slo.js';
import { envInt } from './env.js';

export const stompConnected = new Rate('stomp_connected');
export const stompConnectDuration = new Trend('stomp_connect_duration', true);
export const stompErrors = new Counter('stomp_errors');
export const wsUnexpectedClose = new Counter('ws_unexpected_close');
export const wsSessionsOpened = new Counter('ws_sessions_opened');
export const wsSessionsClosed = new Counter('ws_sessions_closed');
export const chatSent = new Counter('chat_messages_sent');
export const chatReceived = new Counter('chat_messages_received'); // 팬아웃 포함 전체 수신
export const chatDeliverySuccess = new Rate('chat_delivery_success');
export const chatDeliverySeconds = new Trend('chat_delivery_seconds');

const HEARTBEAT_MS = envInt('STOMP_HEARTBEAT_MS', 0, 0);
const SEND_DELAY_MS = envInt('SEND_DELAY_AFTER_SUBSCRIBE_MS', 200, 0);
const MESSAGE_BYTES = envInt('MESSAGE_BYTES', 64, 16, 500); // messages.content VARCHAR(500)

function frame(command, headers = {}, body = '') {
  const lines = [command];
  for (const [k, v] of Object.entries(headers)) {
    if (v !== undefined && v !== null && v !== '') {
      lines.push(`${k}:${v}`);
    }
  }
  lines.push('', body);
  return `${lines.join('\n')}\0`;
}

function parseFrames(payload) {
  return String(payload)
    .split('\0')
    .map((p) => p.replace(/^[\r\n]+/, ''))
    .filter((p) => p.length > 0)
    .map((p) => {
      const sep = p.indexOf('\n\n');
      const head = sep >= 0 ? p.slice(0, sep) : p;
      const body = sep >= 0 ? p.slice(sep + 2) : '';
      const lines = head.split('\n');
      const command = lines.shift();
      const headers = {};
      for (const line of lines) {
        const i = line.indexOf(':');
        if (i > 0) headers[line.slice(0, i)] = line.slice(i + 1);
      }
      return { command, headers, body };
    });
}

export function uuid() {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 36; i += 1) {
    if (i === 8 || i === 13 || i === 18 || i === 23) out += '-';
    else if (i === 14) out += '4';
    else if (i === 19) out += hex[(Math.random() * 4) | 8];
    else out += hex[(Math.random() * 16) | 0];
  }
  return out;
}

function messageBody(roomId) {
  const id = uuid();
  const head = `lt ${id}`;
  const content = head.length >= MESSAGE_BYTES ? head : head + ' ' + 'x'.repeat(MESSAGE_BYTES - head.length - 1);
  // 서버 Jackson은 SNAKE_CASE. 네이밍 전략이 STOMP 컨버터에 적용되지 않는 경우를 대비해 두 키를 모두 보낸다.
  return { id, content, json: JSON.stringify({ client_message_id: id, clientMessageId: id, content }) };
}

function contentOf(body) {
  try {
    return JSON.parse(body).content;
  } catch (_) {
    return undefined;
  }
}

function hostOf(url) {
  const m = /^wss?:\/\/([^/:]+)/i.exec(url);
  return m ? m[1] : 'localhost';
}

function handshakeParams(tags, runIdValue) {
  const headers = { 'X-Load-Test-Run-Id': runIdValue };
  // 브라우저처럼 Origin을 보내려면 WS_ORIGIN=FRONT_URL. 없으면 Spring은 same-origin으로 간주해 허용한다.
  if (__ENV.WS_ORIGIN) headers.Origin = __ENV.WS_ORIGIN;
  return { headers, tags };
}

/**
 * 한 사용자가 채팅방에 접속해 lifetimeMs 동안 머무른다.
 * sendIntervalMs > 0 이면 주기적으로 메시지를 보내고 자신의 echo(MESSAGE)로 저장·전달 성공을 판정한다.
 */
export function holdChatSession({ wsUrl, runIdValue, token, roomId, lifetimeMs, sendIntervalMs = 0, phase = () => 'measure', tags = {} }) {
  const baseTags = { name: 'WS /api/wss', ...tags };
  const pending = {}; // content -> { sentAt, phase }
  let connected = false;
  let connectRecorded = false;
  let plannedClose = false;
  const startedAt = Date.now();
  const stopSendingAt = startedAt + lifetimeMs - SLO.chatDeliveryP99 * 1000 - 1000;

  const res = ws.connect(`${wsUrl}/api/wss`, handshakeParams(baseTags, runIdValue), (socket) => {
    socket.on('open', () => {
      wsSessionsOpened.add(1, baseTags);
      socket.send(frame('CONNECT', {
        'accept-version': '1.2',
        host: hostOf(wsUrl),
        Authorization: `Bearer ${token}`,
        'heart-beat': HEARTBEAT_MS > 0 ? `${HEARTBEAT_MS},0` : '0,0',
      }));
    });

    socket.setTimeout(() => {
      if (!connectRecorded) {
        connectRecorded = true;
        stompConnected.add(0, { ...baseTags, phase: 'connect' });
        stompErrors.add(1, { ...baseTags, reason: 'CONNECT_TIMEOUT' });
        plannedClose = true;
        socket.close();
      }
    }, SLO.wsConnectTimeoutMs);

    socket.on('message', (payload) => {
      for (const f of parseFrames(payload)) {
        if (f.command === 'CONNECTED') {
          connected = true;
          if (!connectRecorded) {
            connectRecorded = true;
            stompConnected.add(1, { ...baseTags, phase: 'connect' });
            stompConnectDuration.add(Date.now() - startedAt, { ...baseTags, phase: 'connect' });
          }
          socket.send(frame('SUBSCRIBE', { id: `sub-${roomId}`, destination: `/sub/chat/${roomId}`, ack: 'auto' }));
          if (HEARTBEAT_MS > 0) {
            socket.setInterval(() => socket.send('\n'), HEARTBEAT_MS);
          }
          if (sendIntervalMs > 0) {
            // 첫 전송은 간격 안에서 무작위로 흩어 모든 VU가 같은 순간에 보내지 않게 한다.
            socket.setTimeout(() => {
              const sendOne = () => {
                if (Date.now() > stopSendingAt) return;
                const m = messageBody(roomId);
                pending[m.content] = { sentAt: Date.now(), phase: phase() };
                socket.send(frame('SEND', { destination: `/pub/chat/${roomId}`, 'content-type': 'application/json' }, m.json));
                chatSent.add(1, { ...baseTags, phase: phase() });
              };
              sendOne();
              socket.setInterval(sendOne, sendIntervalMs);
            }, SEND_DELAY_MS + Math.floor(Math.random() * sendIntervalMs));
          }
        } else if (f.command === 'MESSAGE') {
          chatReceived.add(1, { ...baseTags, phase: phase() });
          const content = contentOf(f.body);
          const p = content && pending[content];
          if (p) {
            chatDeliverySeconds.add((Date.now() - p.sentAt) / 1000, { ...baseTags, phase: p.phase });
            chatDeliverySuccess.add(1, { ...baseTags, phase: p.phase });
            delete pending[content];
          }
        } else if (f.command === 'ERROR') {
          stompErrors.add(1, { ...baseTags, reason: (f.headers.message || 'ERROR').slice(0, 40) });
        }
      }
    });

    socket.on('error', () => stompErrors.add(1, { ...baseTags, reason: 'SOCKET_ERROR' }));

    socket.on('close', () => {
      wsSessionsClosed.add(1, baseTags);
      if (!plannedClose) {
        // nginx proxy_read_timeout(60s), 서버 재시작, OOM 등으로 계획보다 먼저 끊긴 연결
        wsUnexpectedClose.add(1, { ...baseTags, phase: phase() });
      }
      for (const p of Object.values(pending)) {
        chatDeliverySuccess.add(0, { ...baseTags, phase: p.phase });
      }
    });

    socket.setTimeout(() => {
      plannedClose = true;
      socket.send(frame('DISCONNECT'));
      socket.close();
    }, lifetimeMs);
  });

  const upgraded = res && res.status === 101;
  check(res, { 'ws upgraded (101)': () => upgraded }, baseTags);
  if (!upgraded && !connectRecorded) {
    stompConnected.add(0, { ...baseTags, phase: 'connect' });
    stompErrors.add(1, { ...baseTags, reason: `HANDSHAKE_${res ? res.status : 0}` });
  }
  return { upgraded, connected };
}

/** CUJ의 "채팅 시작" 단계: CONNECTED → SUBSCRIBE → 첫 메시지 echo 수신까지 한 번. */
export function chatRoundTrip({ wsUrl, runIdValue, token, roomId, tags = {}, timeoutMs = 8000 }) {
  const baseTags = { name: 'WS /api/wss', ...tags };
  const startedAt = Date.now();
  let connected = false;
  let delivered = false;
  let sentAt = 0;
  const m = messageBody(roomId);

  const res = ws.connect(`${wsUrl}/api/wss`, handshakeParams(baseTags, runIdValue), (socket) => {
    socket.on('open', () => {
      wsSessionsOpened.add(1, baseTags);
      socket.send(frame('CONNECT', { 'accept-version': '1.2', host: hostOf(wsUrl), Authorization: `Bearer ${token}`, 'heart-beat': '0,0' }));
    });
    socket.on('message', (payload) => {
      for (const f of parseFrames(payload)) {
        if (f.command === 'CONNECTED' && !connected) {
          connected = true;
          stompConnectDuration.add(Date.now() - startedAt, { ...baseTags, phase: 'connect' });
          socket.send(frame('SUBSCRIBE', { id: `sub-${roomId}`, destination: `/sub/chat/${roomId}`, ack: 'auto' }));
          socket.setTimeout(() => {
            sentAt = Date.now();
            socket.send(frame('SEND', { destination: `/pub/chat/${roomId}`, 'content-type': 'application/json' }, m.json));
            chatSent.add(1, baseTags);
          }, SEND_DELAY_MS);
        } else if (f.command === 'MESSAGE') {
          chatReceived.add(1, baseTags);
          if (sentAt > 0 && contentOf(f.body) === m.content) {
            delivered = true;
            chatDeliverySeconds.add((Date.now() - sentAt) / 1000, baseTags);
            socket.close();
          }
        } else if (f.command === 'ERROR') {
          stompErrors.add(1, { ...baseTags, reason: (f.headers.message || 'ERROR').slice(0, 40) });
          socket.close();
        }
      }
    });
    socket.on('close', () => wsSessionsClosed.add(1, baseTags));
    socket.setTimeout(() => socket.close(), timeoutMs);
  });

  const upgraded = res && res.status === 101;
  stompConnected.add(connected ? 1 : 0, { ...baseTags, phase: 'connect' });
  chatDeliverySuccess.add(delivered ? 1 : 0, { ...baseTags, phase: tags.phase || 'measure' });
  check(null, {
    'chat: ws upgraded': () => upgraded,
    'chat: stomp CONNECTED': () => connected,
    'chat: first message echoed': () => delivered,
  }, baseTags);
  return { upgraded, connected, delivered };
}

export function vuIndex() {
  return exec.vu.idInTest - 1;
}

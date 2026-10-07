# 실서버(V1 Spring Boot) 부하테스트 시나리오

`../`의 기존 스크립트는 `/api/lab/*` 픽스처 서버용이다. 이 폴더는 **실제 모여타 백엔드 API와 SLI/SLO 정의**에 맞춘 스크립트다.
설계 근거와 수정 목록은 `docs/406-V1-real-server-loadtest-redesign.md`를 본다.

| 파일 | 시나리오 | 부하가 들어가는 서버 코드 |
|---|---|---|
| `read.js` | S1 조회 증가 (46→91→180→226 RPS 단계) | `HomeService`(map-pins·nearby 공간 쿼리), `CompanionPostService.find`, 커뮤니티 상세·댓글 |
| `ws-chat.js` | S2 연결 증가 (`MESSAGE_RATE=0`) / S3 메시지 저장 (`MESSAGE_RATE=36`) | `/api/wss` → `StompAuthChannelInterceptor`(SUBSCRIBE마다 DB 조회) → `ChatMessageSendService`(INSERT + last_message_id UPDATE) → Simple Broker |
| `hot-row.js` | S4 좌석 경합 (`MODE=companion`/`taxi`, `DISTRIBUTE` 대조군) | `ChatParticipationService.participate` 조건부 UPDATE / `TaxiPotService.start` FOR UPDATE·`MATCH_BUSY` |
| `mixed.js` | S5 조회 단독 ↔ 조회+X, `PROFILE=event` 행사 스파이크 | 공용 JVM·HikariCP(10)·MySQL |
| `cuj.js` | 참여자·모집자·택시팟 E2E 신뢰성 완료율 (SLO 97%) | 각 CUJ의 API + STOMP 첫 메시지 |

## 준비 (테스트 서버에서만)

1. 사용자·토큰 생성 — 로그인이 Kakao OAuth뿐이라 테스트 서버 `JWT_SECRET`으로 직접 발급한다.
   ```bash
   JWT_SECRET=<테스트 서버 값> python3 real/tools/make-users.py --count 2600 --ttl-hours 12
   # real/data/seed-users.sql 을 테스트 MySQL에 적용
   ```
2. 시드 (공개 API로 계좌 등록·채팅방·게시글 생성 → `real/data/fixture.json`)
   ```bash
   k6 run -e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host> real/seed.js
   ```
3. 서버 사전조건(문서 2장): nginx `limit_req`에서 발생기 IP 제외, `/api/wss` Upgrade 헤더·타임아웃, Actuator 지표 노출.

## 실행 순서와 부하 단계

실행은 전용 테스트 환경에서만 한다. `CONFIRM_TARGET_HOST`에 `BASE_URL`의 호스트를 직접 지정해야 하며, 지정이 맞지 않으면 모든 실서버 스크립트가 시작 전에 중단된다. 테스트 사용자·토큰과 `fixture.json`은 Git에 추가하지 않는다. 시드 데이터는 다른 부하와 겹치지 않도록 별도 준비하고, 매칭/좌석 시나리오는 실행 사이에 데이터 상태를 초기화한다.

`real/run-all.sh --only 2`는 2번 WebSocket 연결 부하만 실행한다. 이 실행기도 전체 실행과 동일하게 `results/`에 summary·raw JSON과 `runs.tsv` 실행 이력을 남기며, Grafana 설정이 있으면 실행 구간 annotation을 기록한다. `--from 2`는 2번부터 8번까지 실행한다.

처음부터 목표 부하를 넣지 말고, 각 단계 결과와 서버 자원(CPU, JVM/GC, HikariCP active·pending, MySQL 연결·잠금, nginx 429)을 확인한 다음 진행한다. 아래 단기 단계는 포화점 탐색용이며, 91 RPS 4시간은 장시간 기준 부하 확인용이다.

```bash
COMMON="-e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host>"

# 0) 읽기 전용 연결 확인 및 작은 부하부터 시작
k6 run $COMMON -e STEPS=1 -e WARMUP=30s -e STEP_DURATION=1m -e STEP_GAP=15s real/read.js

# 1) 단계별 API 용량 탐색: 45.5 → 91 → 180 → 약 226 RPS
k6 run $COMMON -e STEPS=45.5,91 -e STEP_DURATION=5m real/read.js
k6 run $COMMON -e STEPS=180,226 -e STEP_DURATION=5m real/read.js

# 별도 행사 스파이크: 180 RPS, 5분 ramp-up + 5분 ramp-down,
# HTTP + 1,800 STOMP 연결 + 36 메시지/s + 경합 간섭
k6 run $COMMON -e PROFILE=event -e PEAK_RPS=180 real/mixed.js

# 기준+행사 합산 부하: 225.5를 정수 RPS로 올림해 226으로 측정
k6 run $COMMON -e PROFILE=event -e PEAK_RPS=226 real/mixed.js

# 2) 기준 통근 부하 장시간 유지 (91 RPS × 4h)
k6 run $COMMON -e STEPS=91 -e WARMUP=5m -e STEP_DURATION=4h -e STEP_GAP=30s real/read.js
```

226 RPS는 문서의 225.5 RPS 합산 부하를 k6의 정수 arrival rate에 맞춰 올림한 값이다. `read.js`의 단계별 실행은 HTTP API 용량 탐색이고, `mixed.js`는 HTTP에 STOMP 연결·메시지·경합 간섭을 더한 이벤트 시나리오다. 부하 중 SLO 또는 서버 안전 한계를 넘으면 다음 단계로 올리지 말고 중단한다.

## 실행 예

```bash
COMMON="-e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host>"
k6 run $COMMON -e STEPS=46,91,180,226 real/read.js
k6 run $COMMON -e TARGET_CONNECTIONS=100 -e CONNECT_RATE=2 -e HOLD=2m -e MESSAGE_RATE=0 real/ws-chat.js
k6 run $COMMON -e TARGET_CONNECTIONS=100 -e CONNECT_RATE=2 -e HOLD=2m -e MESSAGE_RATE=1 real/ws-chat.js
k6 run $COMMON -e MODE=companion -e LEVELS=20,50,100 real/hot-row.js
k6 run $COMMON -e MODE=companion -e LEVELS=20,50,100 -e DISTRIBUTE=10 real/hot-row.js
k6 run $COMMON -e MODE=taxi -e LEVELS=4,20,50 real/hot-row.js
k6 run $COMMON -e READ_RPS=50 -e INTERFERE=chat real/mixed.js
k6 run $COMMON -e PROFILE=event -e PEAK_RPS=226 real/mixed.js
k6 run $COMMON -e JOURNEY=participant -e JOURNEY_RATE=1 -e DURATION=2m real/cuj.js
```

낮은 단계에서 정상 동작과 생성기 여유를 확인한 뒤에만 300 → 600 → 1,200 → 1,800 연결을 단계적으로 진행한다. 목표 단계에서는 `TARGET_CONNECTIONS=1800`, `CONNECT_RATE=6`, `MESSAGE_RATE=36`을 사용한다. CUJ는 participant → host → taxi를 각각 낮은 시작률로 확인한 뒤 목표율을 올린다. 모집 글 작성과 택시 매칭은 상태를 변경하므로 전용 테스트 계정/데이터만 사용하고, `real/data/cleanup.sql` 적용 대상을 먼저 확인한다.

좌석 경합(`hot-row.js`)은 정원 초과 응답과 기술 오류를 구분하는 시나리오다. 실행마다 같은 대상 ID를 재사용하지 말고 새 시드 또는 초기화된 테스트 데이터로 비교군과 대조군을 실행한다. `MODE=taxi`는 매칭 결과/계정 상태를 바꾸므로 같은 테스트 사용자의 동시 실행을 금지한다.

HTTP(80)만 열린 서버는 `-e ALLOW_PLAIN_TRANSPORT=true`. 정리: `real/data/cleanup.sql`.
`real/data/`에는 토큰이 들어가므로 Git에 올리지 않는다(`.gitignore`).

## SLO 판정 기준 (`lib/slo.js`)

| 지표 | 기준 |
|---|---|
| `sli_availability` (good / (good+bad), 도메인 거절·입력 오류 제외, `MATCH_BUSY`·429·5xx·timeout은 bad) | ≥ 99.9% |
| `api_duration{sli_class:read}` | p95 < 1s, p99 < 2.5s |
| `api_duration{sli_class:write}` | p95 < 1.5s, p99 < 3s |
| `stomp_connected` / `stomp_connect_duration` | ≥ 99.9% / p99 < 3s |
| `chat_delivery_success` / `chat_delivery_seconds` | ≥ 99.9% / p99 < 2s |
| `cuj_reliability{cuj}` | ≥ 97% |
| `hot_row_consistency`, `taxi_state_fresh` | 100% / ≥ 99.9% |

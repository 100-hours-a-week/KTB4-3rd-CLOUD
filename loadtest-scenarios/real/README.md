# 실서버(V1 Spring Boot) 부하테스트 시나리오

`../`의 기존 스크립트는 `/api/lab/*` 픽스처 서버용이다. 이 폴더는 **실제 모여타 백엔드 API와 SLI/SLO 정의**에 맞춘 스크립트다.
설계 근거와 수정 목록은 `docs/406-V1-real-server-loadtest-redesign.md`를 본다.

| 파일 | 시나리오 | 부하가 들어가는 서버 코드 |
|---|---|---|
| `read.js` | S1 조회 증가 (46→91→180→226 RPS 단계, `RAMP=true`면 상한 탐색 선형 ramp) | `HomeService`(map-pins·nearby 공간 쿼리), `CompanionPostService.find`, 커뮤니티 상세·댓글 |
| `ws-chat.js` | S2 연결 증가 (`MESSAGE_RATE=0`) / S3 메시지 저장 (`MESSAGE_RATE=36`) | `/api/wss` → `StompAuthChannelInterceptor`(SUBSCRIBE마다 DB 조회) → `ChatMessageSendService`(INSERT + last_message_id UPDATE) → Simple Broker |
| `hot-row.js` | S4 좌석 경합 (`MODE=companion`/`taxi`, `DISTRIBUTE` 대조군) | `ChatParticipationService.participate` 조건부 UPDATE / `TaxiPotService.start` FOR UPDATE·`MATCH_BUSY` |
| `mixed.js` | S5 조회 단독 ↔ 조회+X, `PROFILE=event` 행사 스파이크 | 공용 JVM·HikariCP(10)·MySQL |
| `spike.js` | S6 이벤트 스파이크 (급증 → 최대 유지 → 급감 → 회복 관측, cold start 확장성) | `read-mix` 조회·쓰기 믹스, ECS 오토스케일링, HikariCP·MySQL |
| `cuj.js` | 참여자·모집자·택시팟 E2E 신뢰성 완료율 (SLO 97%) | 각 CUJ의 API + STOMP 첫 메시지 |
| `migration-v1-direct.js` | DB 이관 중 V1 API 고정 부하·쓰기 원장 | V1 API → Spring → ProxySQL → 현재 writer |
| `scheduler-flow.js` | 동기 스케줄러 작업 생성 (택시팟·카풀 출발/도착, 푸시) — 판정은 처리 지연 | `@Scheduled` 8개 (`*RideStart/RideEnd/AutoCancelScheduler`, `ChatRoomCloseScheduler`, `NotificationPushScheduler`) + `@Async` ETA·푸시 |

## 이벤트 스파이크 (`spike.js`)

행사 직전 한가한(cold) 상태에서 부하가 순식간에 몰렸다 사라질 때 서버 반응과 회복을 본다. 오토스케일링이 적시에 도는지, 병목·연쇄 장애가 생기는지, scale-in 뒤 평시 수준으로 돌아오는지가 목적이다. 단일 `ramping-arrival-rate`(도착률 고정이라 서버가 느려져도 부하가 줄지 않는다)로 아래 순서를 만든다.

| 구간 (`window` 태그) | 부하 | 길이 (기본) | 판정 |
|---|---|---|---|
| `pre` | `BASELINE_RPS` 5 | `PRE_DURATION` 1m | SLO |
| `surge` | 기준선 → `PEAK_RPS` 226 급증 + 스케일아웃 허용 | `SURGE_DURATION` 10s + `SURGE_GRACE` 2m | 가용성 ≥ `SURGE_AVAILABILITY` 0.95 (지연은 리포트로 확인) |
| `peak` | `PEAK_RPS` 유지 | `PEAK_DURATION` 5m (surge 직후부터, grace 포함) | SLO (가용성·읽기/쓰기 지연) |
| `drop` | `PEAK_RPS` → 0 | `DROP_DURATION` 10s | 없음 |
| `recovery` | `RECOVERY_RPS` 2 탐침 (0이면 요청 없음) | `RECOVERY_DURATION` 10m | SLO (탐침이 있을 때) |

```bash
COMMON="-e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host>"
k6 run $COMMON real/spike.js                                              # 5→226 rps, 약 17분
k6 run $COMMON -e PEAK_RPS=450 -e SURGE_DURATION=5s real/spike.js          # 더 가파르고 더 큰 스파이크
k6 run $COMMON -e RECOVERY_RPS=0 -e RECOVERY_DURATION=15m real/spike.js    # 회복은 태스크 수·DB 지표로만 관측
```

- **cold start**: 직전 실행의 scale-in이 끝난 뒤(또는 REST 서비스 desired count가 최소일 때) 시작한다. 시작 시 `rest_running`을 기록해 두면 surge 이후 증가 곡선을 비교할 수 있다.
- **시간축**: 모든 요청에 `window`와 `bucket`(30초 단위 `t00030`, `BUCKET_SECONDS`) 태그가 붙는다. raw JSON을 `bucket`으로 묶으면 급증 후 처리량·지연·오류가 몇 초 뒤부터 안정되는지 나온다. 시작·종료 UTC 시각이 로그에 찍히므로 Grafana·ECS 이벤트(`scheduler-tasks.sh`)와 같은 축으로 읽는다.
- **VU**: 급증 즉시 목표 RPS가 나가도록 피크 기준 VU를 미리 확보한다(`VU_PRE_SECONDS` 1, `VU_MAX_SECONDS` 6). 지연이 SLO 안인데 `dropped_iterations`가 나오면 서버가 아니라 VU 상한이므로 `VU_MAX_SECONDS`를 올린다.
- **안전장치**: `peak` 가용성이 `ABORT_AVAILABILITY`(0.5) 아래로 내려가면 중단한다. `surge`는 cold start 오류를 관측하려고 중단하지 않는다. `ABORT_ON_FAIL=false`로 끈다.
- 읽는 지표: surge의 오류·지연·`dropped_iterations`(cold start), peak 말미의 Hikari pending·RDS CPU/연결(병목·연쇄 장애), drop 뒤 `rest_running` 감소와 recovery 탐침 지연(회복).
- 쓰기 트래픽(댓글·모집글)이 포함되므로 끄려면 `WRITE_TRAFFIC=false`. 사용자·fixture 준비는 아래 "준비"와 같다.

## 상한 탐색 ramp (`read.js` `RAMP=true`)

오토스케일링이 켜진 stg에서 서버 상한을 찾을 때 쓴다. 평탄 단계 대신 `RAMP_START`→`RAMP_TARGET`을 `RAMP_STEP`(rps) 폭 구간으로 쪼개 `ramping-arrival-rate`로 선형 증가시킨다(구간 경계에서 부하가 끊기지 않는다).

```bash
k6 run $COMMON -e RAMP=true -e RAMP_START=20 -e RAMP_TARGET=300 -e RAMP_STEP=10 -e RAMP_SLICE_DURATION=2m real/read.js
```

| 변수 | 기본 | 의미 |
|---|---|---|
| `RAMP_START` / `RAMP_TARGET` | 20 / 300 | 시작·목표 RPS (warmup이 START까지 올린다) |
| `RAMP_STEP` / `RAMP_SLICE_DURATION` | 10 / 2m | 구간 폭·길이. 기울기 = STEP / SLICE (기본 분당 5rps). 구간 태그 `step_rps=20to30` |
| `ABORT_ON_FAIL` | true | 보호용 abort. 구간 가용성 `ABORT_AVAILABILITY`(기본 0.95) 미만 또는 `dropped_iterations` `ABORT_DROPPED_MAX`(기본 50) 초과 시 즉시 중단. `ABORT_DELAY`(30s) 이후부터 평가 |
| `VU_PRE_SECONDS` / `VU_MAX_SECONDS` | 2.5 / 5 | VU = 구간 최대 RPS × 초. 평균 지연이 아니라 매분 정각 정체(약 2초)를 견디는 값. 절대값은 `PRE_ALLOCATED_VUS`·`MAX_VUS` |

SLO(99.9%·p95 1s·p99 2.5s) 위반은 abort 없이 구간별로 끝까지 기록하고, 상한은 실행 후 "처음 위반한 구간의 직전"으로 정한다. abort 는 붕괴 보호용이다. preflight 가 `users.json` 인원(fixture 풀 최대 7,800)·토큰 잔여시간(2h)·인덱스별 `/users/me` 200 을 확인한다.

기울기는 (기울기 × 스케일아웃 소요시간)이 태스크 1개의 여유 처리량보다 작도록 잡는다. 결과는 구간별 `rest_running`(`scheduler-tasks.sh`)과 Hikari·RDS 지표를 같은 시간축으로 읽는다. `ABORT_ON_FAIL`은 단계 모드(`STEPS`)에도 적용되며, `scheduler-run.sh`의 배경 조회 부하도 SLO가 깨지면 멈춘다.

### ramp 실행기와 DB 포화 지표 (`tools/ramp-run.sh`)

preflight(AWS·Prometheus 필수 지표·`k6 inspect`) → k6 → 같은 시간 구간의 `scheduler-tasks.sh`·`scheduler-prom.sh` 수집을 `results/ramp-<run-id>/`에 남긴다.

```bash
export BASE_URL=https://<stg host> CONFIRM_TARGET_HOST=<stg host> AWS_PROFILE=moyeota-terraform
real/tools/ramp-run.sh rehearsal                      # 20→60 RPS, 10rps/1분 구간 (≈5분 + 수집 대기 90초): 수집 흐름 검증
real/tools/ramp-run.sh run -e RAMP_START=20 -e RAMP_TARGET=300 -e RAMP_STEP=10 -e RAMP_SLICE_DURATION=2m
real/tools/ramp-run.sh collect --run-id <id>          # 수집만 다시
```

`tasks/minutes.tsv`에는 기존 7개 열 뒤에 DB 포화 지표가 붙는다: `rds_connections_max`, `rds_read_latency_ms`, `rds_write_latency_ms`, `rds_read_iops`, `rds_write_iops`, `rds_disk_queue_max`, `rds_freeable_mem_mb`. Hikari 대기·획득 시간은 `prom/`(`hikari_pending_max`, `hikari_acquire_avg`)에서 본다. DB 부하(DBLoad)는 Performance Insights 전용이라 포함하지 않았다.

## 동기 스케줄러 부하 (Kafka 도입 근거 측정)

설계: `docs/KTB4-3rd-CLOUD.wiki/동기-스케줄링-부하테스트-시나리오-설계.md`. 스케줄러는 API가 직접 부르지 않으므로 API 지연이 아니라 **처리 지연(lag)** 으로 판정한다.

| 파일 | 용도 |
|---|---|
| `scheduler-flow.js` | 실제 API로 작업 생성 (`STEPS`=분당 건수, `MIX=taxi:5,carpool:3,comment:2`, `RIDE`, `OBSERVE=poll\|none`). 시작 시 백로그 시드 명령, 종료 시 lag 집계·태스크 수 수집·정리 명령을 출력 |
| `tools/scheduler-backlog-seed.sql` | 이미 처리 시각이 지난 작업 N건 시드 (12h 자동취소·48h 채팅방 종료 포함), `lt_fill_messages`로 messages 테이블 확대 |
| `tools/scheduler-lag.sql` | 시간대 점검 + 스케줄러별 lag p50/p95/p99, 미처리 backlog, 분당 처리량, 푸시 경로, ETA 미갱신, 중복 처리 |
| `tools/scheduler-tasks.sh` | 실행 구간의 REST 태스크 수(Container Insights)·스케일 이벤트·RDS CPU/크레딧을 KST 분 단위로 (lag 분당 표와 같은 시간축) |
| `tools/scheduler-cleanup.sql` | 알림·푸시·정산·카풀 요청·차량 정리. `data/cleanup.sql` 보다 먼저 실행 |
| `mocks/kakao-navi/` | Kakao 길찾기 HTTP mock. 지연·오류·경로 없음·타임아웃을 실행 중 `PUT /admin/config`로 바꾼다 (SC-5) |
| `tools/scheduler-run.sh` | **실행기**. 시나리오 하나를 preflight → 잔여 정리 → 시드 → k6 → 처리 대기 → lag·태스크 수·처리 원장·Prometheus 수집 → (수집이 모두 성공했을 때만) 정리 → 분석 순서로 끝까지 돌리고 `results/<run-id>/`에 남긴다 |
| `tools/scheduler-reset.sql` | 시나리오 사이 정리. 이전 실행의 작업만 지우고 사용자·게시글·필러 메시지(H3)는 남긴다 |
| `tools/scheduler-export.sql` | 처리 한 건 = 한 행 원장 TSV: ride-start/end 요청 메시지(중복 순번 포함), 푸시 작업(created/updated/sent/status/attempts), 자동취소·채팅방 종료 처리 시각, 미처리 backlog |
| `tools/scheduler-prom.sh` | Prometheus 수집. `--check`는 필수 지표가 실제로 나오는지(부하 전), 기본은 실행 구간 `query_range` 내보내기 |
| `tools/scheduler-sweep-split.py` | 처리 원장으로 sweep 구간을 추정하고 k6 raw JSON의 `api_duration`을 sweep/idle로 나눠 p50/p95/p99 비교 (6-9 기준 4) |
| `tools/scheduler-sc6.py` | SC-6: SC-3·SC-4 결과를 `rest_running` 구간(stable/boundary)별로 나눠 처리량·lag·중복·포화 분 처리량 증가율 (6-9 기준 5·6) |

### stg(다중 인스턴스) 실행 전 확인

| 항목 | 결정 / 확인 방법 |
|---|---|
| 태스크 수 | 오토스케일링을 켠 채 측정한다(운영과 같은 조건). 결과는 `scheduler-tasks.sh`의 `rest_running`과 맞춰 읽고, 스케일 이벤트 전후 2분은 경계 구간으로 따로 본다 |
| 배포·stg 스케줄 | 측정 중 BE 배포 정지, stg QA 스케줄과 겹치지 않는 시간 |
| Kakao Navi | mock(`mocks/kakao-navi`)의 stg 배포는 나중 작업. 그때까지 `RIDE=false`(기본)로 탑승 시작을 하지 않아 Kakao를 부르지 않고, ride-end는 백로그 시드 `@n_ride_end`로 만든다. 배포 후: REST 태스크 환경변수 `MOYEOTA_KAKAONAVI_DIRECTIONSURI=http://<mock>:8080/v1/directions`, mock `DURATION_SECONDS` = k6 `ETA_SECONDS`, `RIDE=true` |
| FCM | stg는 `MOYEOTA_NOTIFICATION_PUSH_ENABLED=true`. 실제 FCM에 테스트 토큰으로 호출 → `INVALID_ARGUMENT`로 1회 시도 후 FAILED (Google 왕복 지연이 들어간 처리 지연은 측정됨, 재시도 경로는 안 탐). FCM 호출을 빼려면 `PUSH_TOKENS=false` |
| H7(SC-5) | 잠정 보류. 다른 지표에서 근거가 나오면 하지 않는다 (설계 문서 6-9) |
| RDS | `db.t4g.small` 그대로. `scheduler-tasks.sh`의 `cpu_credit_balance`·`surplus_credits_charged`를 같이 본다. `lt_fill_messages`는 측정 전에 미리 돌린다 |
| 사용자 id | 아래 절차로 실제 QA 계정과 겹치지 않는 시작 id를 고른다 |

```bash
# 0) stg users 의 id 사용 현황 확인 → 시작 id 는 MAX(id)와 AUTO_INCREMENT 보다 충분히 큰 값
mysql <stg DB> -e "SELECT MAX(id), (SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='users') AS next_id FROM users;"
#    명시 id 로 넣으면 AUTO_INCREMENT 가 그 뒤로 밀린다. 이후 가입한 QA 계정이 테스트 범위 바로 뒤 id 를 받으므로,
#    다음 실행에서 --count 를 늘리면 그 계정과 겹친다. 실행마다 새 시작 id 를 쓰거나 범위를 처음부터 넉넉히 잡는다.
JWT_SECRET=<stg 값> python3 real/tools/make-users.py --start-id 9000001 --count 8000 --ttl-hours 12
# real/data/seed-users.sql 적용

COMMON="-e BASE_URL=https://<stg host> -e CONFIRM_TARGET_HOST=<stg host>"
# 택시팟을 COMPLETED까지 진행하면 계정을 재사용할 수 없다(정산 대기). 부족하면 스크립트가 필요 인원을 알려준다.
k6 run $COMMON -e STEPS=10,50,200 real/scheduler-flow.js
#   시작 로그: 백로그 시드 명령(@uid_to 포함) / 종료 로그: lag 집계·scheduler-tasks.sh·정리 명령 — 그대로 실행한다

# backlog 시드 (SC-1·2·4) — @uid_to 는 users.json 마지막 id (필수)
{ echo "SET @uid_to=9008000, @n_ride_start=1000, @n_ride_end=1000, @n_auto_cancel=1000, @n_chat_close=1000, @n_push=1000;"; cat real/tools/scheduler-backlog-seed.sql; } | mysql <stg DB>

# SC-3 ride-end 부하 (Kakao mock 배포 전): 단계 시작 시각에 분당 R건 × T분을 T분에 걸쳐 고르게 due 로
{ echo "SET @uid_to=9008000, @n_ride_end=1000, @due_at='<단계 시작 KST>', @due_spread_s=600;"; cat real/tools/scheduler-backlog-seed.sql; } | mysql <stg DB>

# (SC-5 진행 시에만) mock 지연 단계 전환 — 실행 중
curl -X PUT -H "X-Admin-Token: $TOKEN" -d '{"latency_ms":1000}' http://<mock>:8080/admin/config
```

`@uid_from`/`@uid_to`(lag·정리)와 `@uid_to`(시드)는 필수다. 빠지면 SQL이 바로 멈춘다. 백로그 시드는 `@uid_to`부터 거꾸로 `SEED_USERS`(200)명을 쓰므로 `scheduler-flow.js`는 그 앞 구간만 쓴다.

### 실행기로 돌리기 (10/27~ 순서)

10/26 첫 실행에서 드러난 문제를 실행기 순서로 막았다.

| 10/26 문제 | 실행기에서 바뀐 것 |
|---|---|
| 정리를 먼저 해 원본 DB 행이 사라져 재집계 불가 | 정리는 lag·태스크 수·처리 원장(export)·Prometheus 내보내기가 **모두 성공하고 파일이 비어 있지 않을 때만** 한다. 하나라도 실패하면 정리하지 않고 멈춘다 → 고친 뒤 `collect` → `reset` |
| `sched_rate.json` 이 비어 있음 | 쿼리가 없는 이름(`spring_scheduled_tasks_seconds_count`)을 조회했다. `tasks_scheduled_execution_seconds_*` 로 고치고, preflight 에서 이름을 실제로 확인한다 |
| `tomcat_busy.json` 이 비어 있음 | `server.tomcat.mbeanregistry.enabled`(기본 false) 때문에 노출되지 않는다(아래 "지표 노출"). 대체로 `http_active`(진행 중 요청 수)를 함께 받는다 |
| Hikari pending 이 0인데 acquire max 2.7~3.4s | stg 스크레이프 간격이 30s라 순간 대기를 못 본다. 획득 시간 평균(`hikari_acquire_avg` = sum/count rate)·`hikari_timeout`·`hikari_pending_max`(1분 max_over_time)를 더했다. 간격 단축은 아래 "수집 간격" |
| sweep 구간/비구간 API 지연을 나눌 sweep 시각이 없음 | `scheduler-export.sql` 처리 원장 + `scheduler-sweep-split.py` 로 sweep 구간을 추정해 나눈다 |
| ride-end 시드를 단계 시각에 손으로 맞춤 | `sc3` 가 k6 raw JSON 에서 첫 measure 요청 시각을 찾아 단계마다 `@due_at`·`@due_spread_s` 로 자동 시드 |

준비 (터미널에서 터널 2개를 연다)

```bash
# stg DB: 127.0.0.1:13306 (사용자가 여는 SSM 포트포워딩)
# Prometheus: 모니터링 EC2 9090 → 127.0.0.1:19090 (10/26 대상: i-051f42a98fde6ccb3)
aws ssm start-session --target <monitoring EC2 id> --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=9090,localPortNumber=19090

export MYSQL_PWD=<stg admin 비밀번호> STG_DB=<stg DB 이름>
export AWS_PROFILE=moyeota-terraform AWS_REGION=ap-northeast-2
export BASE_URL=https://<stg host> CONFIRM_TARGET_HOST=<stg host>
# 기본값: DB_HOST=127.0.0.1 DB_PORT=13306 DB_USER=admin UID_FROM=9000001 UID_TO=9008000 SEED_USERS=200
#         PROM_URL=http://127.0.0.1:19090 PROM_JOB=stg-rest, users.json=real/data/users.json (토큰 만료 1h 이상 남아야 함)

# 지표 노출만 먼저 확인 (부하 없음): 필수 지표 표 + 실제 지표 이름 목록
real/tools/scheduler-prom.sh --check --out results/prom-check-$(date +%Y%m%d)
```

실행기는 시작할 때 preflight(터널·`MYSQL_PWD`/`STG_DB`·테스트 사용자 8,000명·users.json 범위와 토큰 만료·`scheduler-lag.sql` 시간대 점검(DB 오프셋 540분, gap_hours)·Prometheus 필수 지표·AWS 자격 증명)를 돌리고, 하나라도 실패하면 부하 전에 멈춘다. BE 설정 반영 전에 `tasks_scheduled_execution_*`·`tomcat_threads_*` 가 없으면 `--allow-missing sched,tomcat` 으로 **명시적으로** 건너뛴다(결과 `window.env`·`preflight/check.tsv` 에 남는다).

```bash
# 0) 기준선 먼저: 조회 91 RPS 만 15분 (작업 생성 0). stg 가 배경 조회 부하를 견디는지 확인한다.
#    10/26 재수집은 이 단계를 건너뛰고 SC-3 에 배경 조회를 섞었다가, 동행 지도 핀·주변 글 쿼리가 공간 인덱스를 쓰지 않아
#    RDS CPU 99% 로 무효가 됐다 (issues/troubleshooting/2026-10-26-v2-stg-scheduler-loadtest-recollect-db-saturation.md).
#    SC-0 이 SLO 를 넘으면 BE 공간 인덱스 힌트 적용 전까지 스케줄러 시나리오는 --read-rps 0 으로 돌린다.
real/tools/scheduler-run.sh sc0                                   # 기준선: 조회 91 RPS 15분, 작업 생성 0

# 1) 재수집: 10/26 SC-3 과 같은 단계로 다시 (새 수집 항목·처리 원장·sweep 분리 포함, 배경 조회 91 RPS)
real/tools/scheduler-run.sh sc3 --steps 10,50,200

# 2) 신규 수집 (현재 동기 A)
# SC-1 × H3: stg 에는 10/26 필러 messages 500만 행이 남아 있다(필러는 늘리기만 가능) → 500만부터
real/tools/scheduler-run.sh sc1 --n 10000 --messages 5000000
real/tools/scheduler-run.sh sc1 --n 50000 --messages 5000000
#   → 최종 정리(아래) + real/data/seed-users.sql 재적용 후 0행
real/tools/scheduler-run.sh sc1 --n 10000 --messages 0
real/tools/scheduler-run.sh sc1 --n 50000 --messages 0
#   → 100만 적재는 측정 전에 따로 (RDS 크레딧 회복 후 측정)
real/tools/scheduler-run.sh sc1 --messages 1000000 --fill-only
real/tools/scheduler-run.sh sc1 --n 10000 --messages 1000000
real/tools/scheduler-run.sh sc1 --n 50000 --messages 1000000
real/tools/scheduler-run.sh sc2                                   # 자동취소 10,000 + ride-start 200/분 25분 (H1)
real/tools/scheduler-run.sh sc3 --steps 10,50,200,500             # 500/분 단계 추가 (H4·H6)
real/tools/scheduler-run.sh sc4 --n 1000
real/tools/scheduler-run.sh sc4 --n 3000
real/tools/scheduler-run.sh sc4 --n 5000
# SC-6: 별도 실행 없음. SC-3·SC-4 결과를 태스크 수 구간별로
python3 real/tools/scheduler-sc6.py --run results/<sc3 run-id> --run results/<sc4 run-id> ... --out results/sc6-A

# 3) 튜닝 동기(B, 설계 7장) 빌드를 stg 에 배포한 뒤 같은 명령을 --variant B 로 반복 → SC-6 도 sc6-B
real/tools/scheduler-run.sh sc3 --steps 10,50,200,500 --variant B

# 실패·중단 시 (정리하지 않고 멈춘 경우)
real/tools/scheduler-run.sh collect --run-id <run-id>   # window.env 구간으로 lag·tasks·export·prom 다시 수집 → 성공하면 정리
real/tools/scheduler-run.sh reset                       # 시나리오 사이 정리만
# 최종 정리 (사용자·필러 메시지까지)
{ echo "SET @uid_from=9000001, @uid_to=9008000;"; cat real/tools/scheduler-cleanup.sql real/data/cleanup.sql; } | mysql ...
```

시나리오 인자 기본값

| 시나리오 | 하는 일 | 기본값 |
|---|---|---|
| `sc0` | `read.js` 조회 부하만 | `--read-rps 91 --duration 15m` |
| `sc1 --n N` | 스케줄러 5종(ride-start·ride-end·자동취소·채팅방 종료·푸시)에 N건씩 시드 → 미처리 0 또는 `--max-wait`까지 대기 (`drain.tsv`가 drain 곡선) | `--max-wait 40m`, `--messages M`이면 필러를 M행까지 먼저 적재(줄이지는 않음) |
| `sc2` | 자동취소 `--n` 시드 + `scheduler-flow.js MIX=taxi:1 STEPS=--rate` | `--n 10000 --rate 200 --duration 25m` (10분 스케줄러 2주기 이상) |
| `sc3 --steps` | `scheduler-flow.js` + 단계마다 ride-end 시드(분당 = 단계 × `--ride-end-ratio`, 단계 동안 고르게) + 배경 `read.js` | `--step-duration 10m --step-gap 2m --ride-end-ratio 0.8 --read-rps 91` |
| `sc4 --n N` | 택시팟·카풀 N건을 `--lead-min`분 뒤 같은 분에 출발하도록 시드 → 그 분이 지나 미처리 0 까지 | `--lead-min 3 --read-rps 91 --max-wait 20m` |

공통: `--variant A|B`, `--run-id`, `--k6-env K=V`(여러 번), `--settle 60`, `--poll 30`, `--no-final-reset`, `--skip-pre-reset`, `--dry-run`. 처리 대기 중 미처리 확인 쿼리(`drain.tsv`)가 `--poll` 초마다 DB를 읽으므로 SC-1 처럼 큰 backlog 에서는 간격을 늘려도 된다.

결과 (`results/<run-id>/`)

| 파일 | 내용 |
|---|---|
| `window.env` | 실행 구간(서버 LocalDateTime·epoch), 사용자 범위, 인자 — `collect`·분석 스크립트가 읽는다 |
| `steps.tsv`, `run.log`, `cmd.txt` | 단계별 rc·시각, 전체 로그, 실행 명령 |
| `preflight/` | `check.tsv`(필수 지표), `metric-names.txt`·`sched-metric-candidates.txt`(실제 노출 이름), `timezone.tsv` |
| `seed-*.txt`, `ride-end-seeds.tsv`, `messages-total.txt` | 시드 결과, SC-3 단계별 ride-end 시드, messages 전체 행 수(H3) |
| `k6.log`, `summary.json`, `raw.json`, `read-*.json` | k6 (`raw.json` 은 수백 MB 가능) |
| `drain.tsv` | 처리 대기 중 스케줄러별 미처리 수 곡선 |
| `lag.txt` | `scheduler-lag.sql` |
| `tasks/` | `scheduler-tasks.sh` (`minutes.tsv`, `events.tsv`) |
| `sched-events.tsv` | `scheduler-export.sql` 처리 원장 |
| `prom/` | `scheduler-prom.sh` (`<key>.json`, `manifest.tsv`) |
| `sweep/`, `sweep-read/` | `api-split.tsv`(sweep/idle p95 비교, `flag=over20`), `sweeps.tsv` |
| `sc6/` | 이 실행만의 SC-6 표 (여러 실행을 묶으려면 `scheduler-sc6.py --run ... --run ...`) |
| `reset-before.txt`, `reset-after.txt` | 정리 전후 행 수 |

### 지표 노출 (stg 에서 확인할 것 · BE 변경 필요 사항)

`scheduler-prom.sh --check` 가 아래를 확인한다. 10/26 prom-sc* 에서 이미 나온 것: `hikaricp_connections_{active,pending,acquire_seconds_max}`, `executor_{active_threads,queued_tasks}`(`taskScheduler`·`notificationPushExecutor`·`applicationTaskExecutor` 포함), `http_server_requests_seconds_*`, JVM.

| 지표 | 상태 | 없을 때 BE 변경 (BE 레포는 이 작업에서 고치지 않음) |
|---|---|---|
| `tasks_scheduled_execution_seconds_{count,sum,max}`, `tasks_scheduled_execution_active_seconds_{count,sum,max}` | **stg 노출 확인 (2026-10-26 `--check`)** — 태스크 2개 × 스케줄러 8개 = 16 시계열. 메서드 이름(`code_function`)이 8개 모두 `sweep` 이라 **클래스(`code_namespace`)로 나눈다**(`scheduler-prom.sh` 반영) | 없음 |
| `tomcat_threads_busy_threads`, `tomcat_threads_current_threads` | **stg 미노출 확인** (`server.tomcat.mbeanregistry.enabled` 기본 false, `tomcat_sessions_*`만 나옴) | `application-prod.yaml` 에 `server.tomcat.mbeanregistry.enabled: true`. 반영 전에는 `--allow-missing tomcat` 으로 실행하고 `http_active` 로 대체 |
| `http_server_requests_seconds_*`, `http_server_requests_active_seconds_*` | job 에 이름은 있지만, 태스크 재시작 뒤 요청이 없으면 시계열이 없다(첫 요청 때 생성). `--check` 는 `no-traffic-yet` 로 표시하고 막지 않는다 | 없음 |
| `hikaricp_connections_acquire_seconds_{sum,count}`, `hikaricp_connections_timeout_total`, `hikaricp_connections_usage_seconds_*` | Hikari 기본 지표라 노출 예상 (stg 미확인) | 없음 |
| `executor_pool_size_threads`, `executor_queue_remaining_tasks`, `executor_completed_tasks_total` | `executor_*` 가 나오므로 노출 예상 (stg 미확인) | 없음 |
| `http_server_requests_active_seconds_active_count` | Boot 관측 기본 (stg 미확인). Tomcat busy 대체 | 없음 |
| Hikari pending 의 순간 값 | 스크레이프 간격(30s)에 묶임 | BE 변경 없음. 판단은 `hikari_acquire_avg`·`hikari_timeout` 으로 하고, 순간 값이 꼭 필요하면 아래 수집 간격을 줄인다 |

### 수집 간격 (stg-rest 30s → 5s, 적용하지 않음)

`v2/modules/monitoring/templates/prometheus.yml.tftpl` 은 `global.scrape_interval: 30s` 이고 ECS 대상(`scrape_targets`) job 에 개별 간격이 없다(정적 대상만 15s). 측정 기간에만 stg-rest 를 5s 로 줄이는 방법:

1. `modules/monitoring/variables.tf` 의 `scrape_targets` 객체에 `scrape_interval = optional(string)` 추가
2. 템플릿 ECS 루프의 `metrics_path` 아래에 `%{ if try(t.scrape_interval, null) != null ~}scrape_interval: ${t.scrape_interval}` / `scrape_timeout: 4s` `%{ endif ~}` 추가 (`scrape_timeout` 은 간격보다 짧아야 한다)
3. 루트 `monitoring.tf` 가 만드는 stg rest 항목에만 `scrape_interval = "5s"` → `terraform plan` 확인 → apply → 모니터링 호스트의 Prometheus 설정 재적재(`sync.sh`)
4. 측정 뒤 되돌린다. 시계열 저장량이 해당 job 만 6배가 되고, 5s 에서도 순간 pending 은 놓칠 수 있다
5. 바꾼 뒤에는 `PROM_STEP=5` 로 `scheduler-prom.sh` / `scheduler-run.sh` 를 돌린다 (기본 15)

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

## DB 이관 중 V1 운영 API 직접 부하

`migration-v1-direct.js`는 k6에서 지정한 **V1 API origin**으로만 요청한다. V2 URL·ALB 라우팅·DNS 비율 전환은 스크립트에 없다. S2~S9 동안 V1 backend가 계속 ProxySQL을 사용하므로, ProxySQL writer를 바꾸는 동안 같은 V1 API 호출이 현재 writer에 도달하는지 확인하는 용도다. 이 스크립트는 ProxySQL 컷오버 명령을 실행하지 않는다.

`V1_DIRECT_API_URL`에는 ALB 도메인이 아니라 V1 EC2의 직접 접근 주소(또는 그 주소로 연결되는 V1 전용 host)를 지정하고, WebSocket도 같은 origin의 `/api/wss`를 쓴다. 현재 문서의 `moyeota.com`, `dev.moyeota.com`, `stg.moyeota.com`은 ALB 경로이므로 이 스크립트가 거부한다. 정확한 V1 origin은 배포 환경에서 확인해 넣는다.

운영 API 쓰기 부하에는 전용 테스트 계정과 해당 계정이 만든 `users.json`·`fixture.json`이 필요하다. `fixture.json.base_url`은 직접 V1 origin과 일치해야 한다. 기존 `make-users.py`의 운영 JWT 비밀키 사용이나 일반 사용자 데이터 사용을 이 스크립트가 요구하지 않는다. 기본 쓰기·채팅 부하를 실행하려면 아래 두 승인 문자열을 명시해야 하며, `WRITE_RPS=0`과 `CHAT_MSG_RATE=0`을 함께 주면 읽기 전용으로 실행할 수 있다.

```bash
k6 run \
  -e ALLOW_PLAIN_TRANSPORT=true \
  -e V1_DIRECT_API_URL=http://<v1-ec2-direct-host> \
  -e CONFIRM_TARGET_HOST=<v1-ec2-direct-host> \
  -e CONFIRM_V1_PROD_LOAD=I_UNDERSTAND_V1_PROD_LOAD \
  -e ALLOW_PROD_MUTATIONS=I_UNDERSTAND_PROD_TEST_WRITES \
  -e RUN_ID=mig-r1 -e DURATION=20m -e READ_RPS=30 -e WRITE_RPS=15 \
  -e CHAT_ROOMS=20 -e CHAT_MSG_RATE=10 \
  real/migration-v1-direct.js
```

이관 리허설(binlog 복제·ProxySQL 컷오버)의 소스도 같은 V1 Prod EC2다. 컷오버 명령은 `v2/templates/migration/cutover-switch.sh`(V1 Prod에 `cutover-switch`로 설치)가 실행하고, 이 스크립트는 그동안 V1 API 쪽 요청만 만든다. 실행 순서는 `v2/MIGRATION_REHEARSAL.md`를 따른다.

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

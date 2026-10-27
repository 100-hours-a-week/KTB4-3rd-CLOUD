# 대규모 Flooding 테스트 실행 런북

> 작성 2026-10-27. 설계는 `v2/FLOODING_SCENARIO.md`, 코드는 `loadtest-scenarios/flooding/`, 기존 실행 절차는 `loadtest-scenarios/real/README.md`를 따른다.
> 대상은 **stg 전용**이다. 운영(Prod) DB의 `JWT_SECRET`으로는 어떤 단계도 실행하지 않는다.

---

## 1. 실행 단계 요약

| 순서 | 단계 | 누가 | 산출물 |
|---|---|---|---|
| 0 | 승인과 사전 공지 | 팀 | 실행 시간대, 중단 기준 합의 |
| 1 | 서버 사전 조건 확인 | 인프라 | nginx 제한 제외, WebSocket 설정, 지표 노출 |
| 2 | 설계 수치 검증 (dry-run) | 테스트 | 확률·요청 수·계산 결과 |
| 3 | 테스트 계정·토큰 생성 | 테스트 | `real/data/users.json` |
| 4 | 시드 적용과 fixture 생성 | 테스트 | `real/data/fixture.json` |
| 5 | 1 VU 스모크 | 테스트 | 흐름 정상 여부 |
| 6 | 기준선 (평시 91 RPS) | 테스트 | 단계 전 기준 SLO와 자원 |
| 7 | Flooding 본 실행 | 테스트 | k6 결과 JSON, 로그 |
| 8 | 정리 | 테스트 | 참여·모집 해제, 테스트 데이터 정리 |
| 9 | 분석과 리포트 | 테스트 | 임계점, Failback, 병목 |

> 현재 구현 상태: 1~8은 실행 가능하다. 9(임계점 판정, Failback 계산, 리포트, 리소스 수집기)는 아직 없다. 5(스모크)를 위한 축소 실행 옵션도 없다. 아래 9장을 참고한다.

---

## 2. 환경 설정

### 2.1 k6 실행 환경 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BASE_URL` | 필수 | 대상 HTTPS 주소. HTTP만 열린 V1이면 `http://`와 `ALLOW_PLAIN_TRANSPORT=true`를 같이 쓴다 |
| `CONFIRM_TARGET_HOST` | 필수 | `BASE_URL`의 호스트와 정확히 같아야 한다. 다르면 실행을 막는다 |
| `WS_URL` | `BASE_URL`에서 유도 | WebSocket 주소. 필요할 때만 지정한다 |
| `ALLOW_PLAIN_TRANSPORT` | `false` | `http://` 대상을 허용한다. 테스트 서버에서만 |
| `ALLOW_NON_PUBLIC_TARGET` | `false` | 사설 IP를 허용한다. 로컬 드라이런에서만 |
| `INSECURE_SKIP_TLS_VERIFY` | `false` | 인증서 검증을 끈다. 테스트 서버 인증서가 임시일 때만 |
| `RUN_ID` | `flood-<시각>` | 실행 식별자. 모든 요청 헤더와 태그에 들어간다 |
| `REQUEST_TIMEOUT` | `10s` | HTTP 요청 제한 시간 |
| `USERS_FILE` | `real/data/users.json` | 계정·토큰 파일. 남은 만료 시간이 10분 미만이면 실행을 막는다 |
| `FIXTURE_FILE` | `real/data/fixture.json` | 계정 풀 범위가 들어 있다. 실행 시 cuj 풀 크기를 검사한다 |
| `VIEWPORT_LAT_SPAN` | `0.02` | 지도 화면 높이(위도). 설계 문서 기본값과 같아야 한다 |
| `VIEWPORT_LNG_SPAN` | `0.025` | 지도 화면 폭(경도). 설계 문서 기본값과 같아야 한다 |
| `POINT_JITTER` | `0.008` | 거점 중심 주변 시작 좌표 지터 |

`flood.js`는 프로파일(`config/profile.js`)과 혼합(`config/mix.js`)을 코드에서 읽는다. 실행 때 단계 크기를 바꾸는 환경 변수는 없다. 바꾸려면 설정 파일을 고치고 dry-run을 다시 돌린다.

### 2.2 계정 풀 설정 (시드 시점에 결정)

계정 풀은 시드 단계에서 정해지고 `fixture.json`에 기록된다. `flood.js`는 이 기록을 읽는다.

| 풀 | 기본 크기 | Flooding 사용 | 설정 변수 |
|---|---:|---|---|
| chat | 1,800 | 사용 안 함 (cuj 풀과 별도) | `POOL_CHAT` |
| hotrow | 200 | 사용 안 함 | `POOL_HOTROW` |
| taxi | 200 | 사용 안 함 | `POOL_TAXI` |
| **cuj** | 300 | **사용 (VU 배정)** | `POOL_CUJ` |
| writer | 100 | 사용 안 함 | `POOL_WRITER` |

- Flooding의 최대 VU는 **5,472**다(512 RPS 단계, 1.2배). 따라서 `POOL_CUJ ≥ 5,472`가 필요하다. 여유를 두어 **5,500**을 권장한다.
- 전체 계정 수는 풀 합계와 같아야 한다: `1,800 + 200 + 200 + 5,500 + 100 = 7,800`.
- `flood.js`는 cuj 풀이 모자라면 실행 전에 멈춘다(`lib/accounts.js`).
- cuj 풀은 기존 CUJ 테스트와 공유한다. 두 테스트를 동시에 돌리지 않는다.

### 2.3 토큰 수명

- 토큰은 `--ttl-hours 4`로 만든다. 본 실행은 약 85분이고(3장), 60분 관찰과 재실행 여유를 더한다.
- 만료된 토큰은 401을 내며 `test_data_errors`로 집계된다. 실행 중에 만료되지 않게 한다.

### 2.4 테스트 서버 사전 조건 (README 준비 3)

- nginx `limit_req`에서 생성기 IP를 제외한다. 그렇지 않으면 429가 쏟아져 결과가 무효가 된다.
- `/api/wss`의 Upgrade 헤더와 타임아웃을 확인한다.
- Actuator 지표(HikariCP, JVM, 요청 지표)를 노출한다.
- ECS 서비스 설정(`v2/locals.tf`)이 설계 문서 2.4와 같은지 확인한다. 특히 WebSocket 서비스의 scale-in 금지.
- 로컬 DB 접속이 필요하면 SSM 포트포워딩을 쓴다(README 규칙): `127.0.0.1:13306`.

### 2.5 생성기(k6 머신)

- 최대 VU 5,472, 512 RPS, 세션 도착 75.6/s를 감당할 머신이 필요하다. 한 머신에서 힘들면 실행 세그먼트로 나눈다.
- 머신의 파일 디스크와 네트워크 한도를 미리 확인한다.

---

## 3. 단계별 실행

### 3.1 0단계: 승인과 공지

- 실행 날짜, 시간, 대상 호스트, 담당자, 중단 권한자를 정한다.
- 연동 시스템(알림, 결제 mock 등)에 영향이 없는지 확인한다.

### 3.2 2단계: 설계 수치 검증 (dry-run)

```bash
node loadtest-scenarios/flooding/dry-run.js
```

- 기대 결과: `OK`, 종료 코드 0.
- 평시 세션당 HTTP 6.22, 행사 6.77, 지도 평균 조회 3.95 / 4.50.
- 실패하면 설정을 고친 뒤 다시 돌린다. 실행하지 않는다.

### 3.3 3단계: 계정·토큰 생성 (테스트 서버)

```bash
JWT_SECRET=<테스트 서버 값> python3 loadtest-scenarios/real/tools/make-users.py --count 7800 --start-id 900001 --ttl-hours 4
```

- `--count`는 2.2의 풀 합계와 같아야 한다.
- `--start-id`는 기존 사용자 ID와 겹치지 않게 정한다. 시드 SQL의 AUTO_INCREMENT도 확인한다(README 실행 전 확인).
- 산출물: `real/data/users.json`(Git에 올리지 않는다).

### 3.4 4단계: 시드와 fixture 생성

1. 계정 SQL을 테스트 MySQL에 적용한다: `loadtest-scenarios/real/data/seed-users.sql`.
2. 시드 실행 (풀 크기는 같은 환경 변수로 정한다):

```bash
POOL_CUJ=5500 k6 run -e BASE_URL=https://<host> -e CONFIRM_TARGET_HOST=<host> loadtest-scenarios/real/seed.js
```

- 산출물: `real/data/fixture.json`(풀 범위가 들어 있다).
- 주의: `POOL_CUJ`는 시드 시점에만 쓴다. 실행 시점에는 `fixture.json`의 범위를 읽는다.

### 3.5 5단계: 1 VU 스모크

- 현재 `flood.js`에는 축소 실행 옵션이 없어서, 스모크는 설정을 임시로 바꿔야 한다. 이 단계는 **구현 전 상태에서 막혀 있다**(9장 1번).
- 임시 방법을 쓴다면 `profile.js`의 rps를 1~2로 낮춘 사본으로 돌리고, 원본으로 되돌린 뒤 dry-run을 다시 돌린다.
- 확인 항목: 인증 200, 지도 조회 200, 상세 조회 정상, 쓰기 1건 성공, 채팅 진입과 메시지 전송, 정리 후 참여 인원 0.

### 3.6 6단계: 기준선 (평시 91 RPS)

- Flooding의 1단계(warmup)는 91 RPS까지 5분 올린다. 기준선으로 따로 15분 돌리는 것을 권장한다(README 기준선 방식).
- 기준: SLO 충족(`lib/slo.js`), 가용성 99.9% 이상, nginx 429 없음.
- SLO를 넘으면 본 실행을 하지 않는다. README의 "공간 인덱스 힌트" 사례처럼 DB 병목이 원인일 수 있다.

### 3.7 7단계: Flooding 본 실행

```bash
mkdir -p loadtest-scenarios/flooding/results
RUN_ID=flood-$(date +%Y%m%d-%H%M)
k6 run \
  -e BASE_URL=https://<host> \
  -e CONFIRM_TARGET_HOST=<host> \
  -e RUN_ID=$RUN_ID \
  --out json=loadtest-scenarios/flooding/results/$RUN_ID.json \
  loadtest-scenarios/flooding/flood.js
```

단계 일정 (시나리오 시작 시각 기준, `flood.js`가 만든 값):

| 시각 | 단계 | 목표 세션/s | 목표 HTTP RPS | 혼합 | 측정 |
|---|---|---:|---:|---|---|
| 0~5분 | warmup (램프) | 15 | 91 | normal | 제외 |
| 5~17분 | step1 (램프 2분 + 유지 10분) | 25 | 171 | event | 뒤 5분 |
| 17~29분 | step2 | 38 | 259 | event | 뒤 5분 |
| 29~41분 | step3 | 56 | 377 | event | 뒤 5분 |
| 41~53분 | step4 | 76 | 512 | event | 뒤 5분 |
| 53~85분 | recovery (램프 2분 + 유지 30분) | 15 | 91 | normal | 전 구간 |

- 본 실행 후 **60분 관찰**을 따로 둔다(FLOODING_SCENARIO 2.3). `flood.js`는 85분 뒤 자동으로 끝난다.
- 최대 VU: step4에서 5,472.

**중단 기준 (수동, 아직 자동화되지 않음)**

| 신호 | 기준 | 조치 |
|---|---|---|
| 가용성 | 99.9% 미만이 2분 이상 | 해당 단계에서 중단하고 임계점으로 기록 |
| 오류 급증 | 5xx 또는 429가 한 단계에서 급증 | 원인 확인 후 중단 여부 결정 |
| 자원 포화 | CPU 85% 이상이 지속 | 기록만 하고 계속 (확장 반응을 보는 것이 목적) |
| 테스트 데이터 | 401·403·404 급증 | 토큰 만료 또는 시드 문제이므로 즉시 중단 |

중단하려면 k6에서 `Ctrl+C`를 누른다. 중단 시각과 사유를 기록한다.

### 3.8 8단계: 정리

- 실행 후 남은 참여와 모집은 세션 내부 정리가 끝나지 않으면 남는다. 정리 대상을 확인한 뒤 `real/data/cleanup.sql`을 적용한다(README 규칙: 적용 대상을 먼저 확인).
- 확인: 참여 인원, 채팅방 상태, 택시 팟 상태가 실행 전 값으로 돌아왔는지.
- 다음 실행 전에는 계정 풀을 다시 시드하거나 정리 결과를 검사한다.

### 3.9 9단계: 분석 (미구현)

- 목표 산출물: 단계별 표(목표 RPS, 달성 RPS, p95·p99, 오류율, CPU, 태스크 수), 임계점, Failback 시간, 병목 자원.
- 필요한 입력: k6 JSON(`results/`), Prometheus 지표(CPU, 메모리, HikariCP, MySQL 연결, ECS 태스크 수), 단계 태그(`stage`, `measure`).
- 기존 도구 참고: `real/tools/scheduler-prom.sh`(Prometheus 조회), `scheduler-run.sh`(실행 기록).

---

## 4. 실행 체크리스트

| 항목 | 확인 |
|---|---|
| 대상 호스트와 `CONFIRM_TARGET_HOST`가 일치한다 | ☐ |
| dry-run이 `OK`다 | ☐ |
| `POOL_CUJ`와 `--count`가 풀 합계와 같다 | ☐ |
| 토큰 만료가 실행 종료 + 60분 이후다 | ☐ |
| nginx 제한 제외와 WebSocket 설정을 확인했다 | ☐ |
| 기준선이 SLO를 충족했다 | ☐ |
| 중단 권한자와 기준을 공유했다 | ☐ |
| 결과 디렉터리(`flooding/results/`)가 있다 | ☐ |
| 정리 대상을 확인한 뒤 `cleanup.sql`을 적용했다 | ☐ |

---

## 5. 실행 전 알려진 한계

1. **스모크 축소 옵션 없음:** `flood.js`는 프로파일을 그대로 쓴다. 축소 실행 환경 변수를 추가해야 한다.
2. **자동 중단 없음:** 임계 조건을 만족해도 k6는 계속 돈다. 수동 기준만 있다.
3. **분석 계층 없음:** 임계점 판정, Failback, 리포트, 리소스 수집기가 없다.
4. **측정 구간 자르기 없음:** `measure` 태그는 단계 단위다. 앞 5분 제외는 분석에서 해야 한다.
5. **채팅 체류 시간은 근사치:** `writeChat`의 lifetime은 스모크에서 확인해야 한다.
6. **VU 번호 재사용:** 단계가 바뀌면 번호가 되풀이되어 직전 세션 꼬리와 계정이 겹칠 수 있다. 풀을 최대 VU보다 크게 잡아 줄인다.
7. **README와 불일치 가능성:** README의 행사 피크 180 RPS와 설계의 171/259 단계가 다르다. 실행 전에 기준을 하나로 정한다.

---

## 6. 결정 필요

- 축소 실행(스모크) 옵션을 추가할지
- 중단 기준을 자동화할지(임계 2분 규칙을 k6 `abortOnFail`로 옮길지, 분석 후 판정할지)
- 1,800 WebSocket 목표와 계산값(512 RPS에서 약 980)을 어느 쪽으로 쓸지
- 행사 종료 후 60분 관찰을 자동 단계로 넣을지

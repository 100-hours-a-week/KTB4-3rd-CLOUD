# 이관 리허설(ProxySQL 컷오버) — V1 Prod → Stg

런북(시나리오·단계·명령): `v2/MIGRATION_REHEARSAL.md`
V1 Prod 실행 도구: v2/templates/migration/mig.sh(`mig`), cutover-switch.sh(`cutover-switch`) — `sudo mig render`가 V1 Prod에 설치한다
소스는 V1 Prod EC2와 MySQL이다 (새 EC2 없음). 테스트 종료 후 V1 Prod DB를 복원하지 않는다. Stg RDS는 S1에서 대체되므로 시작 전 스냅샷을 확보하고 종료 후 복원한다.

## 파일

| 파일 | 역할 |
|---|---|
| tools/gen-testdata.py | 합성 테스트 데이터와 fixture/token, reconcile.sql, ledger.sql 생성. 현재 Prod 소스 데이터의 fixture를 자동 생성하지 않는다 |
| tools/build-fixture.py | `real/seed.js`의 API 생성 결과와 사용자 token 파일을 `cutover.js` 입력 형식으로 결합 |
| cutover.js | 읽기·쓰기·STOMP 채팅 부하, V1/V2 URL 비율 전환, 쓰기 원장 기록 |
| tools/ledger-diff.py | k6 원장과 DB 키를 대조해 누락·중복·응답 불명 분류 |

out/, 토큰, fixture, DB dump는 Git에 올리지 않는다.

## 현재 Prod 소스 리허설 흐름

1. V1 Prod에서 binlog 설정·버전·복제 경로를 확인한다. 설정한 기존 V1 API HTTPS host의 인증서 검증도 통과해야 한다.
2. Stg RDS 수동 스냅샷을 생성하고 available을 확인한다. Stg DB와 엔드포인트 기준 정보를 manifest에 기록한다.
3. V1에 준비된 테스트 전용 계정으로 `real/seed.js`를 실행해 API 경유 시드 데이터와 fixture를 만든다. 실사용자에게 알림이나 채팅이 전달되지 않도록 수신 범위를 제한한다.
4. V1 Prod MySQL의 실제 데이터를 Stg RDS로 초기 적재하고 binlog 좌표를 기록한다. S1은 시드 데이터를 포함해 Stg의 기존 moyeota DB를 대체한다.
5. V1→Stg 정방향 복제, ProxySQL writer 전환, Stg→V1 역방향 복제, Stg V2 DDL·앱 기동을 단계별 게이트에 따라 수행한다.
6. k6는 검증된 V1 API HTTPS host와 https://stg.moyeota.com 을 호출한다. ROUTE=schedule은 k6 URL 요청 비율만 바꾸며 Route 53 레코드나 DNS 캐시를 변경하지 않는다.
7. 부하와 롤백 판단 결과를 저장한다. V1 Prod 데이터는 복원하지 않으며 테스트 시드도 V1에 남는다. Stg는 사전 스냅샷에서 새 RDS로 복원하고 Stg 앱 DB endpoint를 전환한다.

## TLS·DNS 사전 확인

`v1.moyeota.com`은 예시 호스트다. 사용하려는 V1 API host가 이미 V1 HTTPS endpoint로 연결되고, 인증서 SAN 또는 `*.moyeota.com` wildcard로 검증돼야 한다. 이 리허설 Terraform은 V1 DNS 레코드나 TLS 인증서를 생성·변경하지 않는다.

~~~bash
V1_API_HOST=v1.moyeota.com # P3에서 검증한 기존 V1 HTTPS host로 바꾼다.
openssl s_client -connect "$V1_API_HOST:443" \
  -servername "$V1_API_HOST" -verify_return_error </dev/null
curl --fail --show-error --silent "https://${V1_API_HOST}/nginx-health"
~~~

인증서 체인·호스트명·만료 검증이 실패하면 k6 실행을 보류한다. 인증서 검증 생략 옵션을 판정용 리허설에 쓰지 않는다. DNS와 TLS 종료 지점은 이 리허설 범위 밖이며, 기존 승인된 V1 HTTPS endpoint를 사용한다. AWS wildcard 인증서는 한 단계 하위 도메인만 포함한다: https://docs.aws.amazon.com/acm/latest/userguide/acm-certificate-characteristics.html

## k6 fixture와 토큰

현재 cutover.js는 한 fixture와 한 users.json의 토큰을 V1·V2 양쪽에 함께 사용한다. 따라서 실행 전 다음을 확인한다.

- fixture가 V1 Prod 및 S1 후 Stg 양쪽에 실제로 존재하는 테스트 전용 사용자·게시물·댓글·참여 대상·채팅방만 참조한다.
- 토큰이 양쪽 API에서 모두 유효해야 한다. V1 Prod의 JWT secret을 Stg로 복사하지 않는다. 별도 테스트 토큰을 양쪽에서 쓸 수 없다면 cutover.js에 V1/V2 별도 토큰 파일 지원을 추가하기 전까지 API 부하를 진행하지 않는다.
- gen-testdata.py는 합성 DB 데이터와 synthetic ID를 만든다. 생성 SQL에는 DROP DATABASE 옵션이 들어갈 수 있으므로 V1 Prod에서 실행하지 않는다. 이 생성 결과는 이미 양쪽 DB에 같은 fixture가 안전하게 적재된 로컬 검증 외에는 Prod 리허설 입력으로 사용하지 않는다.
- V1 Prod DB에서 테스트 데이터를 새로 만들 때는 애플리케이션의 승인된 준비 절차와 전용 ID를 사용하고, 테스트 후 데이터는 사용자 결정에 따라 V1에 남긴다.

### 리허설 전용 fixture 생성

`real/seed.js`는 사용자 SQL이 적용되고 전용 테스트 토큰이 준비된 환경에서 API를 통해 계좌·채팅방·게시글·댓글 조회 대상을 만든다. cutover 리허설 입력으로 바꾸는 도구는 DB에 접속하거나 데이터를 생성하지 않고 두 JSON 파일을 결합한다.

```bash
cd loadtest-scenarios
k6 run -e BASE_URL="https://${V1_API_HOST}" \
  -e CONFIRM_TARGET_HOST="$V1_API_HOST" \
  -e USERS_FILE=real/data/users.json \
  -e FIXTURE_OUT=out/seed-fixture.json \
  real/seed.js
python3 migration/tools/build-fixture.py \
  --seed-fixture out/seed-fixture.json \
  --users real/data/users.json \
  --base-url "https://${V1_API_HOST}" \
  --fixture-out out/prod-test-fixture.json \
  --users-out out/prod-test-users.json
```

`users.json` 안의 ID는 테스트 DB 사용자와 일치해야 하며, 같은 토큰이 V1과 Stg 양쪽 API에서 유효해야 한다. 토큰 유효성 조건이 준비되지 않으면 API 부하를 시작하지 않는다. 생성된 fixture에는 시나리오가 참조할 조회 대상 ID와 채팅방 멤버·참여 대상만 포함되며, 개인 데이터는 복사하지 않는다. 생성 파일은 `out/` 아래에 두어 Git에 추가하지 않는다.

## 첫 요청 부하

현재 V1 Prod 환경은 simulator보다 자원과 실제 요청 제한의 영향을 받는다. 기본값 READ_RPS=30, WRITE_RPS=15, CHAT_MSG_RATE=10을 바로 사용하지 않는다. TLS와 fixture 확인 후 낮은 부하로 smoke를 시작한다.

~~~bash
: "${V1_API_HOST:=v1.moyeota.com}" # 검증한 기존 V1 HTTPS host로 바꾼다.
k6 run --log-format raw --console-output out/ledger-prod-smoke.log \
  -e V1_URL="https://${V1_API_HOST}" \
  -e V2_URL=https://stg.moyeota.com \
  -e CONFIRM_TARGET_HOSTS="$V1_API_HOST,stg.moyeota.com" \
  -e RUN=prodsmoke1 -e ROUTE=v1 \
  -e READ_RPS=2 -e WRITE_RPS=1 \
  -e CHAT_ROOMS=1 -e CHAT_MSG_RATE=1 -e DURATION=2m \
  -e FIXTURE_FILE=out/prod-test-fixture.json \
  -e USERS_FILE=out/prod-test-users.json \
  migration/cutover.js
~~~

첫 smoke 결과와 V1 EC2 CPU·CPU credit·memory·MySQL connection·5xx·timeout이 정상일 때만 합의된 단계로 올린다. RUN은 실행마다 새 영숫자 1~16자로 바꾼다. fixture/users 파일은 전용 테스트 대상이어야 한다.

## 전환 반복

- ROUTE=v1: 모든 요청이 V1 Prod로 간다. V1 API 쓰기는 V1 DB에 남는다.
- ROUTE=schedule: SWITCH_AT부터 SWITCH_SECONDS 동안 k6 요청 비율을 V1→Stg로 바꾼다. 실제 DNS 전환 테스트가 아니다.
- ROUTE=v2: 모든 요청을 Stg로 보낸다.
- 역전환은 별도 실행 RUN과 초기 Stg 상태에서 수행한다. SWITCH_DIRECTION=reverse 사용 전에 전환 방향과 테스트 DB 상태를 확인한다.
- S3–S5의 쓰기 보류는 k6 요청 분배가 아니라 ProxySQL writer 변경 절차다. 둘을 동일한 단계로 기록하지 않는다.
- 실제 Route 53 전환·TTL·resolver cache를 재현하려면 k6 URL 비율 전환과 분리한 변경 계획, 기존 레코드 기록, 되돌릴 레코드 및 관측 구간이 필요하다.

## 판정

k6 원장, DB ledger, 정지 상태 reconciliation을 같은 RUN 키로 비교한다. V1과 RDS 데이터 쿼리는 Stg RDS credential/SSL 환경에 맞춘 승인된 Prod runner에서 수행한다.

| 지표 | 판정 |
|---|---|
| lost (ACK됐지만 최종 DB에 없음) | 0 |
| dup (같은 키가 2건 이상) | 0 |
| unknown 응답 | 원장과 DB를 대조해 결과를 설명하고 미해결 0 |
| replica_missing | 역방향 복제 지연이 0으로 수렴한 뒤 0 |
| schema/business reconcile | 불일치 원인을 모두 설명 |
| chat | 송신 ACK·같은 세션 echo·별도 수신자 수신을 각각 구분. 현재 cutover.js echo만으로 다중 소비자 전달은 통과 판정하지 않음 |

## 구현 주의

컷오버 도구는 v2/templates/migration/로 옮겼다 (tools/cutover-switch.sh 삭제). V1 Prod에는 기존 Compose 프로젝트(moyeota)를 건드리지 않는 별도 프로젝트(moyeota-migration)로 proxysql·relay·migcli만 띄운다. 테스트 전용 fixture/token과 이미 승인된 V1 HTTPS endpoint가 준비되기 전에는 부하 명령을 실행하지 않는다.

Stg RDS 수동 snapshot restore는 기존 인스턴스를 대체하지 않고 새 인스턴스를 만든다. 복원 완료 후 Stg ECS DB_HOST를 새 endpoint로 전환하고 스모크 확인 후 리허설 RDS를 정리한다. V1 Prod 데이터 복원 단계는 없다.


# 이관 리허설 1회차 준비 중 발견한 이슈 (부하 중 컷오버)

작성 2026-10-24. 기준 런북: [MIGRATION_REHEARSAL.md](<../v2/MIGRATION_REHEARSAL.md>)
브랜치: `worktree-rehearsal-load-first`

## 배경

1회차 리허설을 무부하 컷오버(SC-2) 대신 k6 쓰기 부하 중 컷오버(SC-3)로 시작하도록 순서를 바꿨다(`26af1a6`). 실제 Prod 컷오버는 쓰기가 들어오는 중에 일어나므로, 보류 시간과 lost/dup을 처음부터 그 조건에서 재기 위해서다. 이 변경으로 T0 시드·fixture와 V1 HTTPS 검증이 1회차 시작 전 필수 게이트가 됐고, 준비 과정에서 아래 이슈가 나왔다. 2026-10-24 03:40 기준 리허설은 T1(V1 부트스트랩) 직전에서 멈춰 있다.

## 이슈 요약

| # | 이슈 | 영향 | 상태 |
|---|---|---|---|
| 1 | V1 backend가 이 repo 밖에서 띄운 `moyeota-v2-prod-proxysql` 경유 (`DB_HOST=proxysql`) | 리허설 S0와 충돌, 테스트 사용자 조회 실패 원인 | 정리 스크립트 준비, **V1 실행 대기** |
| 2 | `v1.moyeota.com` 인증서 SAN 불일치 | 부하 시작 불가 (runbook 5장) | 해결 |
| 3 | V1 Prod에서 유효한 테스트 토큰 없음 | 시드·부하 불가 | 예외 결정 후 해결 중 |
| 4 | 시드 스크립트가 backend와 다른 스키마(`moyeota`)를 확인 | 시드 쓰기 1,193건 500 | 수정, 재실행 대기 |
| 5 | 테스트 사용자 id 900001~900100이 `moyeota` 스키마에 이미 존재 | 정리 SQL 오실행 시 기존 데이터 삭제 | 확인 필요 |
| 6 | V1 컨테이너 전체가 02:40 KST쯤 함께 재시작 | 원인 불명 | 확인 필요 |
| 7 | stg RDS 연결 수가 10/24 00:00 KST부터 약 30 → 40 | 출처 불명 연결 | 확인 필요 |
| 8 | SC-5·SC-7은 같은 토큰으로 stg API도 호출 | stg `JWT_SECRET`이 V1과 다르면 401 | 확인 필요 |
| 9 | V2 Prod ASG instance refresh 실패 (general-od·rest-od) | 리허설과 별개, On-Demand vCPU 32 한도 공유 | 별도 처리 |
| 10 | V1 MySQL이 V2 Prod RDS의 replica로 설정됨 (SQL thread 오류로 정지) | `repl-smoke reverse`·S6 진행 불가 | **정리 결정 필요** |
| 11 | V1 compose가 `APP_ENV=dev`로 실행 중 (`moyeota-app-dev`·`moyeota-db-dev`) | 이관 설정 기본값(`-prod`)과 불일치 | `mig` 자동 탐지로 우회 |
| 12 | `mig` 버그: ProxySQL admin 쿼리의 `CONCAT`, 같은 크기 파일을 건너뛰는 S3 sync | `mig check` FAIL 2건 | 수정 (`a2bf7f4`, `7dd4116`) |

## 1. V1 backend가 V2 Prod 실이관용 ProxySQL을 거침

- 현상: V1 `moyeota-backend-1`의 `DB_HOST=proxysql`. V1 호스트에 `moyeota-v2-prod-proxysql`, `moyeota-v2-prod-migration-relay`가 compose 라벨 없이 떠 있다. 이 repo의 리허설 프로젝트(`moyeota-migration`)나 git 이력에는 이 이름이 없고, `cutover-switch`·`mig`도 설치돼 있지 않았다.
- ProxySQL 설정(`/etc/proxysql.cnf`): hostgroup 10 writer = `moyeota-mysql-1` **ONLINE**, `moyeota-v2-prod` RDS **OFFLINE_HARD**. 실사용자 쓰기는 V1 MySQL로 간다(설정 파일 기준, 런타임 값은 미확인).
- 영향: 리허설 S0(`mig endpoint proxysql`)가 backend를 리허설 ProxySQL로 다시 묶으면 이 경로가 끊긴다. 두 relay가 같은 3307을 쓰려 한다.
- 결정 (2026-10-24): `moyeota-v2-prod-proxysql`은 V2 Prod 실이관과 끊어도 된다.
- 조치: `loadtest-scenarios/migration/tools/v1-switch-to-rehearsal.sh` (`04e0a79`, 이관 버킷 `config/tools/`에 업로드).
  - B1 상태 기록 → B2 `mig` 설치 → B3 `mig endpoint mysql`(backend 재생성, 순단) → B4 V2 Prod용 컨테이너 설정 백업(`/var/backups/moyeota-v2-prod-migration-*`) 후 제거 → B5~B7 `mig render`·`users`·`check`
  - B4 이후 `moyeota-v2-prod` RDS의 외부 복제는 끊긴다.
- 상태: 첫 실행 시 SSM 세션(`sh`)에 여러 줄을 붙여넣어 실행되지 않았다. 한 줄씩 다시 실행해야 한다.

## 2. `v1.moyeota.com` 인증서 SAN 불일치 — 해결

- 현상: V1 nginx가 `CN=moyeota.com` Let's Encrypt 인증서만 제시. `moyeota.com`은 이제 V2 Prod ALB(ACM)를 가리킨다. 10/22 로그에도 같은 오류가 있었다.
- 조치: PC에서 Route53 DNS-01로 `v1.moyeota.com` 단일 SAN 인증서 발급(`v1-cert-issue.sh`) → V1 nginx에 설치·reload(`v1-cert-install.sh`, 재시작 없음, 기존 인증서 백업). `stg.moyeota.com`은 stg ALB의 ACM 인증서(SAN `dev`·`stg`, 만료 2027-05-03)가 따로 맡으므로 넣지 않았다.
- 결과: 02:37 KST 설치, SAN `v1.moyeota.com`, 만료 2027-01-21, `/nginx-health` 200·검증 통과. S3 `config/tls/` 키 사본 삭제 확인.
- 과정의 버그: 스크립트가 버킷을 `moyeota-migration-<account>`로 적어 업로드 실패. 실제 이름은 `moyeota-v2-migration-<account>`(`project_name = moyeota-v2`). runbook 4.4 예시와 함께 수정(`01c16f8`).

## 3. V1 Prod용 테스트 토큰 — runbook 예외

- 현상: `real/data/users.json` 토큰은 테스트 서버 `JWT_SECRET`으로 만들어졌고 2026-10-06 11:07에 만료. 로그인은 Kakao OAuth뿐이다.
- 결정 (2026-10-24): runbook 4.4.1 예외로 V1 Prod `JWT_SECRET`으로 테스트 전용 사용자 100명(id 900001~900100), TTL 6시간 토큰만 발급. runbook에 기록(`cd96f9c`).
- 조치: `v1-test-users.sh`가 SSM으로 V1 안에서 서명하고 토큰만 받아 온다. `JWT_SECRET`은 출력·전송하지 않는다. 풀 크기는 `POOL_CHAT=40 HOTROW=10 TAXI=20 CUJ=10 WRITER=20`.

## 4. 시드 쓰기 500 — 스키마 불일치, 수정

- 현상: `POST /api/companion-posts`·`/api/community-posts` 각 600건이 5회 재시도 후 전부 500. backend 로그는 `EntityNotFoundException: User with id '9000xx'`(커뮤니티 글 593건).
- 원인: 스크립트가 DB 이름을 `moyeota`로 하드코딩해 사용자 존재를 확인했다. 그 스키마에는 예전 테스트 사용자가 있어 INSERT를 건너뛰었지만, backend는 다른 경로·스키마를 보고 있었다.
- 같이 고친 버그: 사용자가 이미 있을 때 V1 단계가 `cleanup.sql` 부재로 exit 1(`2576667`). precheck가 fixture를 메인 체크아웃에서 찾던 문제(`3d5f9c7`).
- 수정(`b042aef`): backend 컨테이너의 `DB_HOST`·`DB_NAME`을 읽어 그 스키마에 확인·INSERT한다(`mig`의 `v1_db_name`과 같은 방식). `DB_HOST`가 `mysql`이 아니면 중단한다 → 이슈 1 해소 뒤 재실행.
- 부수 영향: 실패한 쓰기 요청 약 1,200건이 V1 Prod에 들어갔다(저장된 행 없음).

## 5~8. 확인 필요

- 5: `moyeota` 스키마의 id 900001~900100은 이번 작업 전부터 있었다. `out/v1-lt-cleanup.sql`은 이 범위의 사용자와 그들이 만든 데이터를 지우므로, 실행 전에 대상 스키마와 기존 데이터 처리 방침을 정한다.
- 6: 03:40 KST 시점 `moyeota-mysql-1`을 포함한 V1 컨테이너가 모두 "Up About an hour". 인증서 설치는 `nginx -s reload`만 하므로 원인이 아니다. 호스트·Docker 재시작 여부를 확인한다.
- 7: stg RDS `DatabaseConnections`가 10/24 00:00 KST부터 약 30 → 40으로 늘어 유지된다. 어떤 클라이언트인지 확인한다.
- 8: `cutover.js`는 한 토큰 세트로 V1·stg 양쪽을 호출한다. SC-5·SC-7 전에 stg `JWT_SECRET`이 V1과 같은지 확인한다.

## 9. V2 Prod ASG instance refresh (리허설과 별개)

- ws-od refresh는 50%에서 draining 진행 중이었다(10/23 23:43).
- general-od·rest-od refresh는 10/22에 실패했다. 사유는 scale-in protection(`i-01627e165623ae1ac`, `i-09863e6f132ee5941`)과 반복된 `VcpuLimitExceeded`다.
- ws-od가 끝난 뒤 protection 처리를 정하고 다시 시작해야 한다. 리허설과 같은 On-Demand vCPU 32 한도를 쓴다.

## 10. V1 MySQL이 V2 Prod RDS의 replica

- 현상 (`mig status`, 10/24 08:4x UTC): V1 `SHOW REPLICA STATUS`의 `Source_Host`가 `moyeota-v2-prod` RDS다. `Replica_IO_Running: Yes`, `Replica_SQL_Running: No`. `mysql-bin-changelog.000085` end_log_pos 9020 트랜잭션에서 worker가 실패해 SQL thread가 멈췄다. V2 Prod 실이관 때 걸어 둔 역방향(V2 Prod → V1) 복제로 보인다.
- 영향: 지금 V2 Prod 변경은 V1에 적용되지 않는다(SQL 정지). `mig repl-smoke reverse`는 "V1에 이미 복제 설정이 있다"로 중단되고, 리허설 S6는 같은 채널을 stg RDS로 덮어쓴다.
- 처리안: 설정과 오류를 기록한 뒤 `STOP REPLICA; RESET REPLICA ALL;`. V2 Prod의 V1 쪽 롤백 경로를 없애는 결정이므로 운영자가 승인한다.

## 11. V1 compose `APP_ENV=dev`

- V1 Prod 호스트의 네트워크가 `moyeota-app-dev`, `moyeota-db-dev`다(compose 규칙상 볼륨도 `moyeota-mysql-dev`). Terraform 기본값 `moyeota-app-prod`·`moyeota-db-prod`와 다르다.
- `mig`가 설정 이름이 없으면 실행 중인 컨테이너 기준으로 네트워크를 찾도록 고쳤다(`a642828`). `terraform.tfvars`의 `migration_v1_compose`에 실제 이름을 적어 두는 것이 맞다. 이 인스턴스가 이관 원본으로 맞는지 운영자가 확인한다.

## 12. `mig` 버그 (수정)

- ProxySQL 관리 인터페이스(6032)는 SQLite 문법이라 `CONCAT()`이 없다. `mig check`의 런타임 상태·monitor 쿼리를 `||` 연결로 바꿨다(`a2bf7f4`).
- 고친 `mig`가 이전 버전과 같은 크기(23,980바이트)여서, `mig render`의 `aws s3 sync`가 받지 않고 옛 파일을 다시 설치했다. sync에 `--exact-timestamps`를 붙였다(`7dd4116`).
- 브랜치의 `mig.sh`를 S3에 직접 올려 쓰고 있다. 머지 전에 메인 체크아웃에서 `terraform apply`를 하면 `config/bin/mig`가 옛 버전으로 돌아간다.

## 다음 순서

1. [V1] `sudo MIG_BUCKET=moyeota-v2-migration-486152170229 bash /tmp/v1-switch-to-rehearsal.sh` (한 줄 단독 실행) → `mig check` 전 항목 PASS
2. [V1] `sudo mig repl-smoke forward`, `sudo mig repl-smoke reverse`
3. [PC] `v1-test-users.sh` 재실행 → `precheck.sh`에서 T0-4 PASS
4. T2(S1 적재·S2 복제·행 수 대사) → T3(S0) → T4(SC-3, k6 부하 중 `cutover-switch switch`)

## 1회차 범위 결정 (2026-10-24 16:50)

- [ ] 1회차는 역방향 복제(S6)를 하지 않는다 — SC-1 → S0 → SC-4 → SC-3 → S7 → `revert` 순서, SC-5·SC-6·SC-7은 2회차
- [ ] S7 V2 스키마는 수동 SQL로 RDS에만 적용 — V1 Prod로 DDL이 넘어가지 않음
- [ ] `V2_DDL_FILE` 승인본 확정 (출처 커밋·sha256 기록)
- [ ] stg 이미지 Flyway 실행 여부 확인, 켜져 있으면 stg `SPRING_FLYWAY_ENABLED=false`
- [ ] `mig schema-diff` 추가 — S1 뒤 SCHEMA_MATCH, S7 뒤 차이 = V2 DDL
- [ ] `cutover-switch revert` 추가 — S5 뒤 역방향 없이 V1 writer 복귀, 버린 RDS binlog 구간 기록
- [ ] 수정한 `mig`·`cutover-switch` 반영 — `v2` terraform apply(이관 버킷 `config/bin` 갱신) 후 V1에서 `mig render`로 재설치
- [ ] T1 게이트에서 `repl-smoke reverse` 제외
- [ ] V1 Prod에 S5 이후 실사용자 쓰기가 없는지 확인 (`revert` 때 RDS 쪽 쓰기는 V1으로 돌아가지 않음)

## 진행 방식 제약

Claude Code 자동 모드 권한 분류기가 운영 서버 SSM 명령, Route53·인증서 변경, Prod 쓰기를 막는다. 이런 단계는 단계별 출력 스크립트로 만들어 운영자가 직접 실행했다. 모든 스크립트는 `loadtest-scenarios/migration/tools/`에 있다.

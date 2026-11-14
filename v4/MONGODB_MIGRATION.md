# V3 prod MongoDB → v4 데이터 호스트 이관 런북

전환 설계 `v3/docs/ECS_MINIMAL_OPS_TRANSITION.md`의 D2(9절 데이터 이관, 10절 전환 절차)에서 MongoDB 부분을 실행하는 절차다.

## 1. 개요

| 항목 | V3 (원본) | v4 (대상) |
|---|---|---|
| 위치 | replica set `rs0` 3대 (데이터 서브넷 2a·2c·2b, t3.small) | 데이터 호스트 1대의 `mongo` 컨테이너 (v4 app 서브넷 2a) |
| 접속 정보 | `/moyeota/v2/prod/backend/MONGODB_URI`, `/moyeota/v2/prod/mongo/ROOT_PASSWORD` | `/moyeota/v4/prod/backend/MONGODB_URI`, `/moyeota/v4/prod/mongo/ROOT_PASSWORD` |
| 데이터 | `moyeota` DB의 혼잡도 도메인(spots, signals, 혼잡도 이력, 작업). signals는 시계열 + TTL 7일 | 같은 DB로 복원 |

- **방식:** 데이터 호스트가 V3 replica set에 직접 접속해 `mongodump --archive --gzip | mongorestore --drop`으로 옮긴다. S3 같은 중간 저장소를 쓰지 않는다.
- **범위:** `moyeota` DB의 컬렉션과 인덱스(시계열, TTL, 2dsphere 포함). 사용자·역할은 옮기지 않는다. 양쪽 앱 계정 `moyeota`는 각 호스트가 부팅 때 만든다.
- **도구:** `v4/scripts/mongo-migrate.sh` (운영자 PC에서 실행, SSM Run Command로 데이터 호스트에서 작업)
- **비밀번호:** 데이터 호스트가 SSM에서 직접 읽는다. SSM 명령 기록과 운영자 화면에 남지 않는다.
- **소요 시간:** 데이터가 수십 MB 수준이라 이관 자체는 1~2분 예상. 전체 절차는 worker 중지와 lag 확인을 포함해 약 15분.

## 2. 사전 준비 (D1 또는 D2 전)

1. v4가 apply되어 데이터 호스트가 떠 있다 (`terraform output data_host`).
2. v4 tfvars에 `mongo_migration_enabled = true`로 apply한다. 바뀌는 것은 두 가지뿐이다.
   - V3 SG `moyeota-v3-prod-mongodb`에 v4 데이터 호스트 SG → 27017 인바운드
   - 데이터 호스트 Role에 V3 MongoDB URI·root 비밀번호 SSM 읽기
3. 운영자 PC에 `aws`, `jq`가 있고, `ssm:SendCommand`, `ssm:GetCommandInvocation` 권한이 있다.
4. 사전 점검 (읽기 전용):

   ```bash
   AWS_PROFILE=moyeota-terraform v4/scripts/mongo-migrate.sh precheck
   ```

   - 데이터 호스트 컨테이너(kafka, mongo, redis)가 Up이다
   - `mongodump`/`mongorestore` 버전이 나온다
   - V3 replica set `setName: rs0`, `primary`가 보인다
   - v4 MongoDB `ping: ok`
   - V3 `moyeota` DB 크기가 데이터 디스크 여유보다 충분히 작다
5. (권장) 리허설: D2 전에 `migrate --yes`를 한 번 돌려 시간과 문서 수를 확인한다. `--drop`이라 D2에 다시 돌리면 덮어쓴다. 이때 v4 rest가 `APP_ROLE=rest`면 v4에서 혼잡도 쓰기가 없어 리허설 데이터가 섞이지 않는다.

## 3. D2 실행 절차

| 순서 | 할 일 | 명령·확인 |
|---|---|---|
| 1 | EKS worker·matching 중지 (혼잡도 쓰기와 outbox 발행 중단) | `kubectl -n prod scale deploy worker matching --replicas=0` → `kubectl -n prod get deploy worker matching` 0/0. ArgoCD prod 앱은 수동 sync라 되돌아가지 않는다 |
| 2 | Kafka consumer lag 0 확인 | 설계 9절. 남은 메시지가 처리됐는지 확인한다 |
| 3 | 이관 전 문서 수 기록 | `v4/scripts/mongo-migrate.sh count` |
| 4 | 이관 | `v4/scripts/mongo-migrate.sh migrate` → 확인 질문에 `migrate` 입력. 끝나면 문서 수 비교 표가 나온다 |
| 5 | 검증 | `v4/scripts/mongo-migrate.sh verify` → "검증: 문서 수 일치" |
| 6 | v4 전환 계속 | v4 tfvars `rest_app_role = "rest,worker,matching"`, `cutover_enabled = true` apply → rest `update-service` (v4 README 전환 런북) |
| 7 | 이관 권한 닫기 | v4 tfvars `mongo_migration_enabled = false` apply. **V3 destroy(D3) 전에 반드시 끈다** (V3 SG를 조회하므로 V3가 사라지면 plan이 실패한다) |

- 4번에서 V3에 쓰기가 남아 있으면 문서 수가 어긋날 수 있다. 1·2번을 확인한 뒤 진행하고, 어긋나면 원인을 확인하고 4번을 다시 실행한다(`--drop`이라 다시 실행해도 된다).
- signals는 TTL 7일 컬렉션이다. 이관과 검증 사이에 만료 문서가 지워지면 V3와 v4 수가 몇 건 다를 수 있다. 그 경우 `count`를 다시 돌려 차이가 TTL 만료 범위인지 본다.

## 4. 확인 (전환 후)

- 혼잡도 화면(지도 핀, 최신 혼잡도)이 이전 데이터로 보인다
- v4 rest·worker 로그에 Mongo 연결 오류가 없다
- 혼잡도 분석 흐름(worker → Kafka → fastapi → 결과 → MongoDB)이 새 문서를 만든다: `count`를 몇 분 간격으로 돌려 v4 쪽 수가 늘어나는지 본다

## 5. 롤백

| 시점 | 방법 | 데이터 |
|---|---|---|
| 6번 전 (v4 전환 전) | EKS worker·matching을 1로 되돌린다 (`kubectl -n prod scale deploy worker matching --replicas=1`) | V3는 덤프만 했으므로 그대로다 |
| 6번 후 (v4 전환 후, D3 전) | v4 README 롤백(`cutover_enabled = false` 등) 후 EKS worker·matching 1 | v4에서 새로 쌓인 혼잡도 데이터는 V3로 돌아가지 않는다. 혼잡도는 7일 TTL 시계열이라 영향이 작다. 필요하면 이 스크립트의 원본·대상을 바꿔 역이관한다 |
| D3 후 | V3 MongoDB는 destroy 전 EBS 스냅샷(14일 보관, V3 DLM)으로 복원 | — |

## 6. 문제 해결

| 증상 | 확인 |
|---|---|
| precheck에서 V3 접속 시간 초과 | `mongo_migration_enabled = true`로 apply했는지, V3 SG에 데이터 호스트 SG 규칙이 생겼는지 |
| `AccessDeniedException` (SSM) | 데이터 호스트 Role에 `read-v3-mongo-parameters` 정책이 붙었는지 |
| `mongodump: command not found` | mongo 이미지 버전 확인. 데이터 호스트의 `data-host-apply` 이미지 값 |
| 원격 실행이 `TimedOut` | 데이터가 예상보다 크다. `executionTimeout`(3600초)을 늘리거나 데이터 크기를 precheck로 다시 확인 |
| 문서 수 DIFF | V3 쓰기 중단(1·2번) 확인 후 다시 `migrate`. TTL 만료 차이인지 확인 |

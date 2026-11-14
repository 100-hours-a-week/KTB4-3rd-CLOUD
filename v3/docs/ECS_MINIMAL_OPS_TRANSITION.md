# V3 → v4 (ECS 최소 운영) 전환 설계

작성일: 2026-11-14
범위: V3(EKS) prod를 새 Terraform root `v4/`의 ECS 최소 구성으로 옮겨, 남은 AWS 예산(약 $500)으로 운영 기간을 최대한 늘린다.
기준: CLOUD `origin/main` (9495050, 2026-11-13), BE·AI `origin/main` (v3.0.0, 2026-11-10)

> 상태: **설계 (실행 전).** BE 확인 항목(14절)과 사전 확인(10절 D0)이 끝나면 1일차 코드 작업을 시작한다.
> 로컬 작업 트리의 untracked `v3/` 파일은 main보다 오래된 버전이다. V3 구성은 반드시 `origin/main`으로 확인한다.

## 1. 배경과 목표

- 실제 트래픽은 거의 없고, 운영 환경을 유지하는 것이 목적이다.
- 현재 V3 prod는 월 약 $1,500이다. 이대로면 $500은 약 10일 만에 소진된다.
- 목표
  1. V3 기능(Kafka 매칭, 혼잡도 분석, worker 스케줄러, 채팅)을 유지한다.
  2. 월 약 **$165**로 운영한다.
  3. **3일 안에** 전환한다. 전환이 하루 늦어질 때마다 최소 구성 운영 약 9일치가 사라진다.
  4. 새 운영 환경은 **별도 폴더 `v4/`, 별도 state**로 만든다. V2 코드는 참고만 하고 수정 범위는 최소로 둔다.
  5. 정리 전까지는 EKS로 되돌릴 수 있게 한다. EKS 코드는 리허설용으로 보관한다.

## 2. 현재 V3 prod 구성 (origin/main)

### 2.1 서비스 (`v3/argocd/prod/*`, namespace `prod`)

| 서비스 | 역할 | 레플리카 | 노드 | 리소스 (req=limit) | 노출 |
|---|---|---|---|---|---|
| rest-api | BE, `APP_ROLE=rest` | HPA 3~4 | core (OD) | 500m / 1Gi | ALB TG `moyeota-v3-eks-prod-rest` |
| websocket | BE, `APP_ROLE=websocket` | HPA 2~4, 축소 금지 | realtime (OD) | 250m / 1Gi | ALB TG `…-websocket` (드레이닝 120초) |
| worker | BE, `APP_ROLE=worker` | 1 고정, Recreate | core | 500m / 1.5Gi | 없음 |
| matching | BE, `APP_ROLE=matching`, Kafka Streams | 1 고정, Recreate | core | 500m / 1.5Gi | 없음 |
| frontend | FE | HPA 2~3 | burst (Spot) | 100m / 768Mi | ALB TG `…-frontend` |
| fastapi | AI | HPA 2~3 | burst (Spot) | 250m / 768Mi | 내부 전용 |

- rest, worker, matching은 `prod/kafka-client.yaml`로 `MOYEOTA_TAXIPOT_MATCHING_MODE=kafka`가 켜져 있다.
- 이미지 digest: BE `0a3085…`, FE `933eb4…`, AI `de8c12…`

### 2.2 기능과 데이터 의존성 (BE·AI 코드 기준)

| 기능 | 담당 | 필요한 구성 |
|---|---|---|
| API, 인증, 정산, 커뮤니티 | rest | RDS MySQL, Redis(캐시), S3 |
| 채팅 fan-out | websocket | Redis Pub/Sub |
| 스케줄러 10개, outbox 발행 | worker | RDS(ShedLock), Kafka |
| 혼잡도 분석 | worker → Kafka → fastapi → Kafka → worker | Kafka, MongoDB(`congestion` 도메인) |
| 택시팟 매칭 | rest → outbox → matching(Streams) → worker | Kafka |
| 정산 이미지 분석 | rest → fastapi | HTTP (기본값) |
| 알림 푸시 | rest, worker | RDB 모드 (기본값), FCM |
| AI 서버 모니터링 봇 | fastapi 내부 별도 프로세스 | AI DB, Qdrant. 실패해도 fastapi는 동작 |

- 세션은 `moyeota.auth.session-store: jpa`(기본값)라 **MySQL에 있다.** Redis에는 웹소켓 relay와 캐시(지도 핀, 혼잡도 최신값)만 있다.
- Kafka 토픽: `matching.request`, `matching.decision`, `community.post.changed`, `congestion.analysis.request`, `congestion.analysis.result`, `settlement.image-analysis.request`, `settlement.image-analysis.result`, `notification.push.request`, `notification.bulk-push.request`

### 2.3 인프라와 월 비용 (서울 정가 추정)

| 항목 | 구성 | 월 비용 |
|---|---|---|
| EKS + prod 노드 | 컨트롤 플레인, system 2·realtime 2·core 4 (OD t3.medium), burst Spot 2 | 약 $427 |
| MSK | kafka.m7g.large × 3 | 약 $560 |
| MongoDB | 레플리카 셋 3대 (2026-11-13 t3.small로 축소, `PROD_MONGODB_T3_SMALL.md`) + Interface Endpoint 5종 × 2 AZ | 약 $160 |
| RDS, Redis | db.t4g.small Multi-AZ, ElastiCache primary + replica | 약 $141 |
| NAT 2, ALB 2, 모니터링 EC2, 기타 | | 약 $177 |
| **prod 합계** | | **약 $1,465** |
| (stg 노드 Spot 6, Qdrant nonprod) | | (약 +$110) |

## 3. 결정 사항

| # | 결정 | 근거 |
|---|---|---|
| 1 | 새 Terraform root **`v4/`**를 만든다 (별도 state). V2 모듈은 복사해 단순화하고 `../v2`를 참조하지 않는다 | V2는 dev·stg·prod, 이관 리소스가 섞여 있고 apply 때 ALB 규칙이 되돌아간다. 새 환경을 독립된 단위로 관리한다 |
| 2 | **공유형:** VPC·public 서브넷·prod ALB·RDS·모니터링 EC2·Route53·ACM·ECR·앱 시크릿은 V2 것을 data source로 참조한다 | MySQL 이관과 DNS 전환이 없다. 대신 V2는 기반(foundation)으로 계속 남는다 |
| 3 | rest 서비스를 `APP_ROLE=rest,worker,matching`으로 합친다 | worker·matching은 원래 1개 고정이다. `APP_ROLE`은 쉼표로 여러 역할을 허용한다(websocket·all 제외) |
| 4 | 앱 호스트는 전부 Spot t3.medium 2대 | 트래픽과 무관하게 회수는 생기지만 영향이 작다. ECS Spot ASG는 3주간 회수 1건이었다(6절) |
| 5 | rest와 websocket은 서로 다른 호스트에 둔다 | 호스트 1대가 회수돼도 API와 채팅이 동시에 멈추지 않는다 |
| 6 | Kafka·MongoDB·Redis는 On-Demand 데이터 호스트 1대의 컨테이너로 | MSK·레플리카 셋·ElastiCache를 합쳐 월 약 $780 → $43 |
| 7 | RDS는 V2 것을 그대로 쓰되 Single-AZ + db.t4g.micro | 유일하게 지켜야 할 데이터라 관리형 백업(PITR)을 남긴다 |
| 8 | NAT는 v4 서브넷 전용 NAT 인스턴스로 바꾼다 | 월 약 $39 절감. 전환이 안정된 뒤 적용한다 |
| 9 | 모니터링 EC2는 유지한다 (V2 공유) | 운영 환경 유지 근거(대시보드, 로그)를 남긴다 |
| 10 | dev·stg는 삭제한다 | 리허설이 필요하면 EKS를 잠깐 띄운다 (14절 확인 필요) |

## 4. 책임 경계 (V2 / v4 / V3)

| 리소스 | 소유 (state) | v4에서의 사용 | 전환 후 |
|---|---|---|---|
| VPC, IGW, public 서브넷 (public_a·b) | V2 | data source | V2에 유지 |
| prod ALB, HTTPS 리스너, ACM, Route53 | V2 | data source. **리스너 규칙과 TG는 v4가 소유** | V2에 유지 |
| RDS MySQL (`moyeota-v2-prod`) | V2 | data source. RDS SG 인바운드 규칙은 v4가 추가 | V2에서 Single-AZ·micro로 변경 |
| 모니터링 EC2 (Grafana, Prometheus, Loki) | V2 | data source. 모니터링 SG 인바운드(3100, 9090)는 v4가 추가 | V2에 유지 |
| 앱 시크릿 SSM `/moyeota/v2/prod/{backend,frontend,ai}/*` | V2 (값은 콘솔 입력) | ARN으로 참조 | V2에 유지 |
| ECR `moyeota/{be,fe,ai}` | Terraform 밖 | data source | 유지 |
| S3 이미지 버킷 `moyeota-prod-images` | V2 | data source (Task Role 권한) | 유지 |
| GitHub OIDC Provider | V2 | data source | 유지 |
| **v4 private 서브넷 2개 + 라우팅 테이블** | **v4** | 앱 호스트, 데이터 호스트 | — |
| **NAT 인스턴스** | **v4** | v4 라우팅 테이블 기본 경로 | — |
| **ECS 클러스터, ASG, Capacity Provider, Service Connect 네임스페이스, 서비스, TG, 리스너 규칙** | **v4** | | — |
| **데이터 호스트, SG, v4 SSM 파라미터 (`/moyeota/v4/prod/*`)** | **v4** | | — |
| **IAM (실행 Role, Task Role, 배포 Role), 알람** | **v4** | | — |
| V2 ECS prod·dev·stg, MSK, ElastiCache, nonprod ALB, dev EC2, Qdrant, NAT Gateway | V2 | 사용 안 함 | **삭제** (NAT Gateway는 15절 확인 후) |
| EKS 전체, MongoDB 레플리카 셋, NAT-c, EKS TG | V3 | 사용 안 함 | **destroy** (코드는 보관) |

- v4의 Kafka·Redis·MongoDB 접속 정보는 V2가 쓰는 `/moyeota/v2/prod/broker/*`와 겹치지 않게 **`/moyeota/v4/prod/*`**에 둔다.
- state backend: 기존 버킷 `moyeota-v2-tfstate`에 별도 key `infra-v4/terraform.tfstate`.

## 5. 목표 구성

```
Route53 → prod ALB (moyeota-v2-alb, V2 소유) ─ HTTPS 리스너
  ├─ [v4 규칙 10] /api/wss → v4 websocket TG
  ├─ [v4 규칙 11] /api/*   → v4 rest TG
  ├─ [v4 규칙 13] /*       → v4 frontend TG
  └─ [V2 규칙 100+] 기존 V2 prod 규칙 (ECS·EKS 가중치) ← 롤백 경로

v4 ECS 클러스터 moyeota-v4-prod (앱 호스트: Spot t3.medium 2대, v4 서브넷 2a + 2c)
  호스트 A: rest(rest,worker,matching) + [fastapi 또는 frontend] + Alloy
  호스트 B: websocket                  + [frontend 또는 fastapi] + Alloy
  (On-Demand 폴백 ASG: min 0 대기)

v4 데이터 호스트 (On-Demand t3.medium, v4 서브넷 2a, 고정 사설 IP)
  Kafka(KRaft, RF 1) · MongoDB · Redis  + 데이터 EBS 일일 스냅샷

V2 RDS MySQL (db.t4g.micro, Single-AZ)      V2 모니터링 EC2 ← Alloy
v4 NAT 인스턴스 (t4g.nano, V2 public_a)       ※ 전환 직후에는 V2 NAT Gateway 경유
```

### 5.1 v4 폴더 구조

```
v4/
  README.md
  versions.tf             # provider, backend (moyeota-v2-tfstate / infra-v4/terraform.tfstate)
  variables.tf
  terraform.tfvars.example
  locals.tf               # 서비스 스펙, 이미지 digest, 태그
  shared.tf               # V2 리소스 data source (VPC, public 서브넷, ALB·리스너, RDS·SG, 모니터링 SG, OIDC, SSM ARN)
  network.tf              # v4 private 서브넷 2개, 라우팅 테이블, NAT 인스턴스(스위치)
  security.tf             # 태스크·호스트·데이터 호스트 SG, V2 RDS·모니터링 SG 인바운드 규칙
  iam.tf                  # 실행 Role, 서비스별 Task Role, GitHub 배포 Role
  cluster.tf              # ECS 클러스터, Service Connect 네임스페이스, Alloy 데몬
  capacity.tf             # Spot ASG, OD 폴백 ASG, Capacity Provider
  services.tf             # Task Definition, 서비스, TG, 리스너 규칙
  data_host.tf            # 데이터 호스트 EC2, EBS, DLM
  ssm.tf                  # /moyeota/v4/prod/* 파라미터
  alarms.tf               # CloudWatch 알람, Spot 회수 EventBridge, Discord
  outputs.tf
  templates/
    alloy.alloy.tftpl     # Alloy 로그 수집 설정 (v2 템플릿 복사)
    data-host/            # user_data, data-host-apply(Kafka·MongoDB·Redis), topics.sh
    nat/                  # NAT 인스턴스 user_data
# 모듈은 두지 않는다. prod 스테이지 하나라 V2 모듈(ecs-service, ecs-asg, ecs-cluster)을 참고해 리소스를 직접 둔다.
.github/workflows/v4/     # be·fe·ai prod CD (ecs-deploy 액션 재사용)
```

### 5.2 서비스 매핑

| V3 | v4 ECS | 태스크 크기 | 개수 | 비고 |
|---|---|---|---|---|
| rest-api + worker + matching | **rest** (`APP_ROLE=rest,worker,matching`) | 1 vCPU / 2GiB | 1 | Kafka Streams 로컬 상태(RocksDB) 포함. OOM이면 2.5GiB |
| websocket | websocket | 0.5 vCPU / 1GiB | 1 | 자동 축소 금지 |
| frontend | frontend | 0.25 vCPU / 768MiB | 1 | |
| fastapi | fastapi | 0.5 vCPU / 768MiB | 1 | Qdrant 모니터링 봇 끔(관련 값 미주입) |

- 배포: 레플리카 1개, ENI 여유 없음 → 기존 태스크를 먼저 내리고 새 태스크를 띄운다 (`deploy_min = 0`, `deploy_max = 100`). 배포마다 약 2~3분 중단된다.
- 태스크 메모리에는 Service Connect 사이드카(권장 예약 약 256MiB)를 포함해 잡는다. rest → fastapi 호출(`http://fastapi:8000`)에 Service Connect를 쓴다.
- **테스트 단계(D1)에는 rest를 `APP_ROLE=rest`로만 띄운다.** EKS worker와 동시에 스케줄러가 돌면 같은 RDS에서 중복 실행되기 때문이다. D2에 EKS worker·matching을 멈춘 뒤 `rest,worker,matching`으로 바꾼다.

### 5.3 앱 호스트

| 항목 | 설계 |
|---|---|
| 구매 옵션 | Spot 100% (Capacity Provider 전략) |
| 후보 타입 | `t3.medium`, `t3.large`, `t3a.medium`, `c5.large`만 명시. m5·m6i·c6i·r5 계열 제외 |
| 할당 전략 | `price-capacity-optimized` |
| ASG 크기 | min 2 / max 3. 회수 예고 때 `capacity_rebalance`로 대체 인스턴스를 먼저 띄울 여유 1대 |
| AZ | v4 서브넷 2a + 2c |
| 회수 대응 | `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true`, `ECS_CONTAINER_STOP_TIMEOUT` 120초 미만 |
| OD 폴백 | On-Demand ASG min 0 / max 2 대기(평소 $0). 용량 부족 알람이 오면 런북으로 Capacity Provider 전략을 OD로. 같은 `role = shared` 속성 |
| 호스트당 태스크 | t3.medium은 ENI 3개 → awsvpc 태스크 2개. Alloy는 host 네트워크라 ENI를 쓰지 않는다 |

**배치 제약 (rest·websocket 분리)**

`distinctInstance`는 같은 서비스의 태스크끼리만 적용되므로, 서비스 간 반대 배치는 `memberOf` + `task:group`으로 건다.

| 서비스 | memberOf expression |
|---|---|
| rest | `attribute:role == shared and not(task:group == service:websocket)` |
| websocket | `attribute:role == shared and not(task:group == service:rest)` |
| frontend, fastapi | `attribute:role == shared` |

| 회수된 호스트 | 멈추는 기능 (3~6분) | 계속 동작 |
|---|---|---|
| A (rest) | API, 스케줄러, 매칭, outbox, fastapi 또는 frontend | 채팅 연결 |
| B (websocket) | 채팅(재연결), frontend 또는 fastapi | API, 스케줄러, 매칭 |

### 5.4 데이터 호스트

| 항목 | 설계 |
|---|---|
| 인스턴스 | t3.medium On-Demand, v4 서브넷 2a, 고정 사설 IP |
| 디스크 | 루트 EBS + 데이터 EBS 30GB(gp3), DLM 일일 스냅샷 7일 |
| 컨테이너 (compose) | Kafka(KRaft 단일 노드, heap 768MiB), MongoDB(인증, WiredTiger 캐시 0.25GB), Redis(128MiB, 디스크 저장 안 함) |
| 토픽 | V2 `local.msk_topics`와 같은 목록을 RF 1로 생성 (`v2/templates/kafka/topics.sh.tftpl` 참고) |
| 접근 | v4 태스크 SG에서만 9092, 27017, 6379. 관리는 SSM Session Manager |
| 비밀값 | MongoDB root·app 비밀번호는 부팅 시 생성해 `/moyeota/v4/prod/mongo/*` SecureString에 직접 쓴다 (`v3/eks/mongodb_prod.tf` 방식). Terraform state에 남기지 않는다 |
| 참고 코드 | `v2/kafka_dev.tf`, `v2/kafka/compose.yaml`, `v2/templates/kafka/*`, `v3/eks/templates/mongodb-replica/*` |
| Spot 금지 | 단일 인스턴스에 데이터가 있으므로 On-Demand로 고정 |

### 5.5 RDS (V2 소유)

- 같은 인스턴스를 그대로 쓴다(이관 없음). v4는 RDS SG에 v4 태스크 SG 인바운드(3306)만 추가한다.
- D3 정리 때 V2에서 Multi-AZ → Single-AZ, db.t4g.small → db.t4g.micro를 **한 번에** 바꾼다. 재시작으로 몇 분 중단된다. 변경 전 수동 스냅샷.
- micro 최대 연결 수 약 85개. rest·websocket HikariCP 풀(기본 10개씩)을 합쳐도 충분하다.
- T4g RDS는 기본 unlimited 모드라 CPU 크레딧 알람을 건다.

### 5.6 네트워크 (v4 소유)

| 항목 | 설계 |
|---|---|
| private 서브넷 | `10.20.60.0/24`(2a), `10.20.61.0/24`(2c). V2·V3가 쓰는 30·31·40·41·43·50·51·100·101·102와 겹치지 않음 |
| 라우팅 | v4 전용 라우팅 테이블. 기본 경로는 **변수 스위치** (`nat_mode = "v2_gateway" \| "instance"`) |
| 전환 직후 | V2 NAT Gateway(data source)로 라우팅. 전환과 NAT 변경을 분리한다 |
| NAT 인스턴스 (D4~D5) | AL2023 arm64 t4g.nano, V2 public_a 서브넷, 새 EIP. user_data로 `ip_forward`, iptables MASQUERADE, `source_dest_check = false`. 전용 ENI로 라우팅. CloudWatch 자동 복구 알람(`StatusCheckFailed_System` → recover) |
| 공인 IP | NAT 인스턴스는 새 EIP를 쓰므로 나가는 IP가 바뀐다. 외부에 서버 IP 허용 목록(카카오 등)이 있는지 확인한다(14절) |
| 롤백 | `nat_mode`를 `v2_gateway`로 되돌린다 |

### 5.7 시크릿·설정

| 항목 | V3 | v4 |
|---|---|---|
| 앱 시크릿 | External Secrets가 `/moyeota/v2/prod/*` 동기화 | Task Definition `secrets`로 같은 V2 경로 ARN 참조 |
| `KAFKA_BOOTSTRAP_SERVERS` | MSK | `/moyeota/v4/prod/broker/KAFKA_BOOTSTRAP_SERVERS` (데이터 호스트) |
| `REDIS_HOST`, `REDIS_PORT` | ElastiCache | `/moyeota/v4/prod/broker/*` (데이터 호스트) |
| `MONGODB_URI` | 레플리카 셋 | `/moyeota/v4/prod/backend/MONGODB_URI` (데이터 호스트가 부팅 시 기록) |
| 매칭 모드 | `prod/kafka-client.yaml` | 환경변수 `MOYEOTA_TAXIPOT_MATCHING_MODE=kafka` |
| `MOYEOTA_CONGESTION_WINDOW_DEFAULT_MINUTES` | `10` | 환경변수 |
| `CONGESTION_AUTHOR_KEY_SECRET` | backend-common | V2 경로 ARN 참조 |
| fastapi 키 (OpenAI 1·2, Anthropic, Modal ID·SECRET 2) | prod/fastapi | V2 경로 ARN 참조. SSM에 값이 있는지 먼저 확인 |
| 모니터링 봇 값 | prod/fastapi | 주입하지 않음 |

### 5.8 관측·알람

- Alloy ECS 데몬(host 모드)을 v4 클러스터에 둔다 (`v2/alloy.tf`, `v2/templates/alloy.alloy.tftpl` 참고). 목적지는 V2 모니터링 EC2.
- 알람 (v4 `alarms.tf`): V3 `alarms.tf` 기준(5xx 비율, rest p95, websocket 연결 오류, RDS 연결 수) + `RunningTaskCount < desired` 10분 이상 + EventBridge `EC2 Spot Instance Interruption Warning` + 데이터 호스트·NAT 인스턴스 상태 검사 + RDS·t3 CPU 크레딧. Discord 연결은 V3 `alarms.tf` 방식을 옮긴다.
- 비용 설정: Container Insights `disabled`, 앱 로그 보관 14일, ECS Exec 로그 30일.

### 5.9 배포(CD)

- `.github/workflows/v4/{be,fe,ai}-prod-cd.yaml`을 만든다. `.github/actions/ecs-deploy` 액션을 재사용하고 클러스터·서비스를 v4로 지정한다.
- 배포 Role은 v4 `iam.tf`에서 새로 만든다 (V2 OIDC Provider 참조).
- 첫 배포 이미지는 V3 prod digest(2.1절). 이후 BE·FE·AI 레포의 prod 트리거를 v4 워크플로로 연결한다.
- `v3-*-prod-cd`는 트리거를 끈다. 파일은 리허설용으로 남긴다.
- ECR lifecycle 정책은 콘솔·CLI로 설정한다. 쓰는 digest에 tag가 있는지 먼저 확인하고 untagged 삭제 규칙을 맞춘다.

### 5.10 ALB 라우팅과 전환 방식

prod HTTPS 리스너 규칙 (2026-11-14 조회):

| 우선순위 | 조건 | 대상 |
|---|---|---|
| 1 | `/api/wss` | V3 EKS 100 / V2 ECS 0 |
| 2 | `/api/*` | V3 EKS 100 / V2 ECS 0 |
| 4 | `/*` | V3 EKS 100 / V2 ECS 0 |
| 10, 20 | `/api/wss`, `/api/*` | 옛 V2 규칙 (`moyeota-v2-websocket`, `moyeota-v2-rest`, `v2/locals.tf`). 앞 규칙에 가려져 동작하지 않는다 |
| default | — | `moyeota-v2-frontend` |

- **prod 트래픽은 이미 100% EKS로 가고 있다.**
- V2/EKS 가중치 규칙을 10 뒤로 옮기면 옛 V2 규칙이 먼저 걸려 트래픽이 옛 대상으로 빠진다. 그래서 1·2·4 → **5·6·8**(`priority_base` 1 → 5)로만 옮기고, v4는 **1·2·3**을 쓴다.

| 단계 | V2/EKS 규칙 | v4 규칙 | 트래픽 |
|---|---|---|---|
| D1 준비 | 1·2·4 → **5·6·8** | 1·2·3, **조건에 헤더 `X-Moyeota-Target: v4` 추가** | 일반 요청은 V2/EKS 규칙(EKS 100%), 헤더 요청만 v4 |
| D2 전환 | 그대로 | **헤더 조건 제거** | 전부 v4 |
| 롤백 | 그대로 | 헤더 조건 다시 추가 | V2 규칙(EKS)으로 복귀 |
| D3 이후 | V2 prod ECS 스테이지 삭제와 함께 제거 | 유지 | v4 |

- **V2 apply는 ALB 가중치를 ECS 100%로 되돌린다**(`alb-weight.sh` 주석). 지금 EKS 100%인 prod 트래픽이 옛 V2 ECS로 간다. 그래서 V2-1은 `aws elbv2 set-rule-priorities`로 **우선순위만** 바꾸고(가중치 유지), V2 코드(`priority_base = 5`)는 state를 맞추려고만 고친다. V2 apply는 D3(V2 prod ECS 삭제)까지 하지 않는다.

## 6. 근거 데이터

### 6.1 Spot 회수 기록 (CloudTrail `BidEvictedEvent`, ASG 활동, 2026-11-14 조회)

| 출처 | AZ | 평소 대수 | 11/10~11/13 회수 |
|---|---|---|---|
| EKS `stg` | 2a | 3 | 13 |
| EKS `stg-c` | 2c | 3 | 7 |
| EKS `burst-a` | 2a | 1 | 5 |
| EKS `burst-c` | 2c | 1 | 1 |
| V2 ECS `dev-shared-spot` | dev | 2~4 | 10/24 이후 1건 (11/7) |
| FIS 실험 | — | — | 10/24 1회 (무관) |

- 회수는 전부 EKS 관리형 노드 그룹에서 났다. 풀에 서울 회수율 >20% 타입(m5·m5a·m6i.large)과 10~15%(c6i.large)가 섞여 있다. 새로 뜬 노드가 6~90분 만에 다시 회수된 사례가 있다.
- 2a가 2c보다 2~5배 많이 회수됐다. 그래서 v4 앱 호스트는 2a·2c 두 AZ에 둔다.
- Spot placement score: 4개 AZ 모두 9점 (용량 부족 가능성 낮음).

### 6.2 Spot Instance Advisor (서울, 최근 30일)

| 타입 | 회수 빈도 | 할인 |
|---|---|---|
| t3.medium | <5% | 59% |
| t3.large | <5% | 63% |
| t3a.medium | 5~10% | 52% |
| c5.large | 5~10% | 68% |
| c6i.large | 10~15% | 62% |
| m5.large, m5a.large, m6i.large, m7i.large, r5.large | >20% | 62~66% |

- 회수는 우리 트래픽과 무관하게 AWS 쪽 용량 사정(같은 풀의 On-Demand·예약 수요)으로 생긴다. 트래픽이 적으면 회수 **확률**은 그대로지만 **영향**이 작다.
- 후속: EKS `nodes.tf`의 `spot_instance_types`에서도 m5·m5a·m6i·c6i를 뺀다(리허설 때 같은 문제 방지).

## 7. 비용과 운영 기간

| 항목 | 구성 | 월 비용 |
|---|---|---|
| 앱 호스트 | Spot t3.medium 2대 (약 $0.021/h, EBS 포함) | $37 |
| 데이터 호스트 | On-Demand t3.medium | $43 |
| RDS | db.t4g.micro Single-AZ | $22 |
| prod ALB | | $22 |
| NAT 인스턴스 | t4g.nano + EBS (EIP는 기존 NAT Gateway EIP 삭제분과 상쇄) | $4.5 |
| 모니터링 EC2 | t3.small | $22 |
| 기타 | Route53, ECR, S3, Logs, 공인 IPv4 | $15 |
| **합계** | | **약 $165/월 (하루 약 $5.4)** |

| 전환 속도 | 전환 비용 | 남는 예산 | 운영 기간 (11/14 기준) |
|---|---|---|---|
| 3일 | 약 $155 | 약 $345 | 총 약 9.5주 (~2027-01-19) |
| 5~6일 | 약 $305 | 약 $195 | 총 약 6주 (~2026-12-26) |

- 현재 지출을 하루 약 $50으로 가정했다. 실제 값은 Cost Explorer로 확인한다.
- NAT Gateway를 지우기 전까지(15절)는 약 $43이 더 나간다.
- **$500이 남은 크레딧이라면** 11월 누적 사용액이 월말에 차감될 수 있다. Billing의 남은 크레딧과 month-to-date를 함께 확인한다(D0).
- 예산이 거의 떨어지면 "평소엔 내리고 필요할 때만 띄우는" 방식으로 바꾼다. v4가 독립 root라 `terraform destroy`/`apply`로 껐다 켜기 쉽다.

## 8. 코드 작업 목록

### 8.1 v4 (신규)

| # | 작업 | 파일 | 적용 |
|---|---|---|---|
| V4-1 | root 골격, backend, 변수 | `versions.tf`, `variables.tf`, `locals.tf`, `terraform.tfvars.example`, `README.md` | D1 |
| V4-2 | V2 리소스 참조 | `shared.tf` | D1 |
| V4-3 | 서브넷·라우팅 (V2 NAT Gateway 경유) | `network.tf` | D1 |
| V4-4 | SG, V2 RDS·모니터링 SG 인바운드 | `security.tf` | D1 |
| V4-5 | IAM (실행·Task·배포 Role) | `iam.tf` | D1 |
| V4-6 | 데이터 호스트 | `data_host.tf`, `templates/data-host/*`, `ssm.tf` | D1 |
| V4-7 | V2 모듈 참고해 직접 구현 (반대 배치 제약, 명시적 `instance_types`, `capacity_mode` 스위치) | `capacity.tf`, `services.tf` | D1 |
| V4-8 | 클러스터, Capacity, Alloy | `cluster.tf`, `capacity.tf` | D1 |
| V4-9 | 서비스, TG, 리스너 규칙 (헤더 조건) | `services.tf` | D1 |
| V4-10 | 알람 | `alarms.tf` | D1 |
| V4-11 | CD 워크플로 | `.github/workflows/v4/*` | D1~D2 |
| V4-12 | 헤더 조건 제거, rest 역할 확장 | `services.tf`, `locals.tf` (변수) | D2 |
| V4-13 | NAT 인스턴스 | `network.tf`, `templates/nat/*` | D4~D5 |

### 8.2 V2 (최소 수정)

| # | 작업 | 파일 | 적용 |
|---|---|---|---|
| V2-1 | prod 리스너 우선순위 1·2·4 → 5·6·8 (`set-rule-priorities`, 코드 `priority_base = 5`) | `v2/locals.tf` | D1, v4 apply 전 |
| V2-2 | prod ECS 스테이지 삭제 | `v2/terraform.tfvars` (`ecs_stages`, `ecs_container_images.prod` 등) | D3 |
| V2-3 | MSK·ElastiCache prod 삭제 | `v2/terraform.tfvars` (`msk_stages`, `elasticache_redis_stages`) | D3 |
| V2-4 | RDS Single-AZ·micro | `v2/rds.tf` (`multi_az` 변수화), `v2/terraform.tfvars` (`rds_instance_class`) | D3 |
| V2-5 | nonprod 정리 (dev·stg ECS, dev EC2, dev Kafka, Qdrant, nonprod ALB) | `v2/terraform.tfvars` | D3 |
| V2-6 | NAT Gateway 삭제 | `v2/network.tf` | 15절 확인 후 |

### 8.3 V3

| # | 작업 | 적용 |
|---|---|---|
| V3-1 | EKS Spot 풀에서 m5·m5a·m6i·c6i 제외 (`v3/eks/nodes.tf`) | 리허설 전 |
| V3-2 | `terraform destroy` (v3/eks), `v3-*-prod-cd` 트리거 끄기 | D3 |

## 9. 데이터 이관

| 저장소 | 방법 | 영향 |
|---|---|---|
| MySQL | 이관 없음 (V2 RDS 공유). D3에 Single-AZ·micro로 변경 (수동 스냅샷 후) | 변경 중 몇 분 중단 |
| MongoDB | EKS worker를 0으로 → V3 primary에서 `mongodump` → S3 → v4 데이터 호스트에서 `mongorestore` | 혼잡도 데이터만. 수 분 |
| Kafka | outbox 패턴이라 DB가 원본이다. EKS worker 중지로 발행을 멈추고 consumer lag 0 확인 후 전환. 미발행 outbox는 v4 rest(worker 역할)가 새 Kafka로 보낸다 | 진행 중이던 매칭 Streams 상태는 사라진다 |
| Redis | 이관 없음 (relay와 캐시만) | 재로그인 불필요, 캐시는 다시 채워진다 |

## 10. 전환 절차

| 날 | 할 일 |
|---|---|
| **D0 사전** | Billing(남은 크레딧, month-to-date), AWS Budgets 알림($300·$400·$450). `alb-weight.sh prod status`로 현재 가중치 기록, V2 ECS prod 상태 확인. BE 확인(14절). 원하면 EKS stg 노드 0대·V2 nonprod 정리 |
| **D1 구축** | v4 코드(V4-1~V4-11) 작성 → `terraform plan` 검토 → **v4 apply** (rest는 `APP_ROLE=rest`, 리스너 규칙은 헤더 조건). v4 apply 전에 V2-1(`set-rule-priorities`로 5·6·8, 가중치 유지). 헤더 요청으로 v4 스모크 테스트(로그인, API, websocket, fastapi 호출) |
| **D2 전환** (트래픽 적은 시간) | ① EKS worker·matching 0 → ② lag 0 확인 → ③ MongoDB 덤프·복원 → ④ **v4 apply** (V4-12: rest `rest,worker,matching`, 헤더 조건 제거) → ⑤ 검증(11절) → ⑥ 관찰 |
| **D3 정리** (24시간 이상 정상 후) | V3-2 (ArgoCD 앱 삭제 → 플랫폼 Helm 제거(TargetGroupBinding 먼저) → `terraform destroy` v3/eks) → V2-2~V2-5 apply (V2 prod ECS·규칙, MSK, ElastiCache 삭제, RDS Single-AZ·micro, nonprod 정리) |
| **D4~D5** | V4-13 NAT 인스턴스 (`nat_mode = "instance"`) → 하루 관찰 → V2-6 (15절 확인 후) |

- D2 ④에서 v4 태스크가 역할을 바꿔 다시 뜨는 2~3분 동안 API가 중단될 수 있다.
- D3의 destroy와 삭제는 되돌릴 수 없으므로 실행 직전에 따로 승인한다.

## 11. 검증 체크리스트

- [ ] 모든 서비스 health check 통과, v4 TG healthy
- [ ] rest·websocket이 서로 다른 호스트에 배치됨
- [ ] 카카오 로그인, 기존 세션 유지
- [ ] 채팅 송수신 (websocket + Redis relay)
- [ ] 택시팟 매칭 요청 → 결정 반영 (rest → outbox → Kafka → matching → worker)
- [ ] 혼잡도 분석 흐름 (worker → Kafka → fastapi → 결과 → MongoDB)
- [ ] 정산 이미지 분석 (rest → fastapi, Service Connect)
- [ ] 푸시 알림, 스케줄러 실행 로그 (`[SERVER_ROLE]` 로그에 REST, WORKER, MATCHING)
- [ ] Grafana 지표·로그 수신, 알람 테스트
- [ ] v4 CD로 이미지 1회 배포 성공

## 12. 롤백

| 시점 | 방법 | 시간 |
|---|---|---|
| D1~D2 (D3 전) | v4 리스너 규칙에 헤더 조건 다시 추가(v4 apply) → V2 규칙(EKS)으로 복귀. EKS worker·matching 1, v4 rest `APP_ROLE=rest` | 수 분 |
| D3 이후 | `terraform apply`(v3/eks) → `install-platform.sh` → ArgoCD 동기화 → MongoDB 스냅샷 복원 → V2 prod 규칙 복원 | 약 1시간 |
| NAT 인스턴스 | `nat_mode = "v2_gateway"` (Gateway 삭제 전) | 수 분 |
| 보관 | RDS 수동 스냅샷, MongoDB EBS 스냅샷, 이미지 digest 기록 | — |

## 13. 위험과 대응

| 위험 | 대응 |
|---|---|
| V2 apply 시 ALB 가중치가 ECS 100%로 되돌아감 | V2-1은 CLI로 우선순위만 변경. V2 apply는 D3(V2 prod ECS 삭제)에만 |
| v4와 EKS가 동시에 같은 RDS에서 스케줄러 실행 | D1에는 v4 rest를 `APP_ROLE=rest`로만. D2에 EKS 중지 후 확장 |
| V2·v4 state가 같은 리소스를 건드림 | 4절 책임 경계 준수. v4는 V2 리소스를 data source로만 읽고, 추가하는 것은 v4 소유 리소스(SG 규칙, 리스너 규칙)뿐 |
| 호스트당 태스크 2개 (ENI 한도) | 태스크 4개 = 호스트 2대. 배포는 기존 태스크를 먼저 내림 |
| Spot 회수 | 저위험 타입, 2개 AZ, max 3 + capacity_rebalance, rest·websocket 분리, 알람 |
| Spot 용량 부족 | OD 폴백 ASG 대기 + 런북 |
| 데이터 호스트 장애 | On-Demand, EBS 스냅샷, 재생성 런북(약 30분), Kafka는 outbox로 재발행 |
| NAT 인스턴스 장애 | 자동 복구 알람, `nat_mode` 롤백 |
| 배포·회수 때 스케줄러 중복·중단 | BE 확인 (ride-start·ride-end 락 없음, 자동 취소 약 121초) |
| 옛 V2 리스너 규칙(10·20)이 V2/EKS 규칙보다 앞서게 됨 | V2/EKS 규칙은 5·6·8까지만 옮긴다. v4 변수 검증으로 v4 규칙을 1~4로 제한 |
| `alb-weight.sh` TLS 조건 (Redis 전송 암호화) | 데이터 호스트 Redis는 VPC 내부 평문. 위험 수용으로 기록 |
| t3·RDS CPU 크레딧 초과 요금 | 크레딧 알람 |

## 14. 확인 필요

**BE**
1. `rest,worker,matching`을 한 JVM(2GiB)으로 운영해도 되는가 (Kafka Streams + 스케줄러)
2. 배포·회수로 스케줄러가 겹치거나 중간에 끊겨도 안전한가 (ride-start·ride-end 락 없음, 자동 취소 약 121초)

**팀**
3. 배포마다 2~3분, 전환 때 2~3분 중단 허용 여부와 D2 시간대
4. dev·stg 삭제 (리허설은 EKS를 잠깐 띄워 대신)
5. 외부 서비스에 서버 공인 IP 허용 목록이 있는가 (NAT 인스턴스 EIP가 바뀜)

**사실 확인 (AWS 접근 필요)**
6. ~~현재 ALB 가중치~~ → **확인 (2026-11-14): prod 트래픽은 EKS 100%** (5.10절). V2 ECS prod 실행 여부는 남음
   - 같은 날 v4 `terraform plan` 성공(127개 추가), 서브넷 CIDR 비어 있음, 필요한 SSM 키 33개 모두 있음, 리스너 우선순위 10·20에 옛 V2 규칙 발견
7. 실제 일별 비용, 남은 크레딧과 11월 누적 사용액
8. prod 이미지 digest의 ECR tag 유무 (lifecycle 정책 전)
9. Service Connect 사이드카를 포함한 실제 태스크 메모리
10. fastapi 키(Anthropic, Modal)가 `/moyeota/v2/prod/ai/*`에 있는지

## 15. V2 NAT Gateway 삭제 조건

V2 NAT Gateway는 V2 private 서브넷(app, dev, ops)의 기본 경로다. D3 정리 뒤 V2 private 서브넷에 남는 워크로드가 없어야 지울 수 있다.

- 모니터링 EC2가 V2 private 서브넷(ops 등)에 있으면 NAT가 계속 필요하다. 이때는 (a) NAT Gateway를 유지하거나(월 약 $43), (b) 모니터링 EC2가 있는 서브넷의 라우팅을 V2 코드에서 v4 NAT 인스턴스 ENI로 바꾼다.
- D3 이후 V2 private 서브넷의 실행 중 인스턴스를 확인하고 결정한다.

## 16. 참고

- V3 구성: `v3/argocd/prod/*`, `v3/helm/app-values/{services,prod}/*`, `v3/eks/*.tf` (origin/main)
- V2 ECS 참고: `v2/locals.tf`(`ecs_service_specs`, prod 스테이지, `priority_base`), `v2/ecs.tf`, `v2/modules/ecs/{ecs-service,ecs-asg,ecs-cluster}`, `v2/alloy.tf`
- 데이터 호스트 참고: `v2/kafka_dev.tf`, `v2/kafka/compose.yaml`, `v2/templates/kafka/*`, `v3/eks/mongodb_prod.tf`, `v3/eks/templates/mongodb-replica/*`
- 공유 리소스 참조 방식 참고: `v3/eks/security.tf` (V2 SG에 규칙만 추가), `v3/eks/targets.tf` (V2 ALB에 TG·규칙 추가)
- 전환 도구: `v3/scripts/alb-weight.sh`, `v3/scripts/cutover-check.sh`
- 관련 문서: `v2/STG_ECS_SCALE_DOWN.md`, `v2/STG_DATA_LAYER_TOGGLE.md`, `v3/docs/PROD_MONGODB_T3_SMALL.md`

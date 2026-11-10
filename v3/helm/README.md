# V3 EKS Helm 플랫폼

앱 차트가 올라가기 전에 필요한 플랫폼 구성이다. 설치는 `install-platform.sh`로 한다.

## 구성

| PR | 경로 | 내용 |
| --- | --- | --- |
| 6 | `platform-base` namespaces, serviceaccounts | `prod`, `stg`, `external-secrets` Namespace와 스테이지별 ServiceAccount 6개 |
| 7 | `platform-base` networkpolicy-prod | prod 인바운드 기본 차단, 같은 Namespace와 ALB 대역만 허용 |
| 8 | `values/aws-load-balancer-controller.yaml`, `values/metrics-server.yaml` | LB Controller 차트 3.6.2, Metrics Server 차트 3.14.0 |
| 9 | `values/external-secrets.yaml`, `platform-secrets` | External Secrets 차트 2.14.0, 스테이지별 SecretStore |

설치 순서: platform-base → LB Controller → Metrics Server → External Secrets → platform-secrets

## 설계

- **자체 차트와 외부 차트 분리:** `v3/scripts/validate.sh`는 `helm dependency build`를 하지 않으므로 umbrella 차트를 쓰지 않는다. 외부 차트는 values와 고정 버전으로 설치한다.
- **차트 2개:** SecretStore는 External Secrets CRD가 있어야 설치되므로 `platform-base`와 나눴다.
- **Namespace 보존:** release를 지워도 앱과 Secret이 사라지지 않도록 `helm.sh/resource-policy: keep`을 둔다.
- **ALB 무중단 연결:** 스테이지 Namespace에 readiness gate 주입 라벨을 둬서, 새 파드가 Target Group에서 healthy가 된 뒤에 이전 파드를 내린다.
- **system 노드 고정:** 플랫폼 파드는 `role=system`과 `CriticalAddonsOnly` toleration으로 앱 노드와 분리한다.
- **메모리:** 앱과 같이 request=limit, CPU limit 없음으로 둔다.
- **NetworkPolicy 범위:** 앱 라벨에 의존하지 않도록 Namespace 전체 파드에 적용하고, ALB 포트는 노드 SG와 맞춘다.
- **External Secrets 범위:** Role 하나가 두 스테이지를 읽으므로 ClusterSecretStore, ClusterExternalSecret, PushSecret 처리를 끈다.

## 이름 계약

| 항목 | 값 | 맞춰야 하는 곳 |
| --- | --- | --- |
| 클러스터 | `moyeota-v3-eks` | `v3/eks/locals.tf`, LB Controller values, 설치 스크립트 |
| rest SA | `<stage>/rest-api` | Pod Identity 연결, 앱 Chart |
| External Secrets SA | `external-secrets/external-secrets` | Pod Identity 연결, values |
| LB Controller SA | `kube-system/aws-load-balancer-controller` | Pod Identity 연결, values |
| SecretStore | `aws-parameter-store` | 13번 ExternalSecret의 `secretStoreRef` |

앱 차트(10번)는 ServiceAccount를 만들지 않고 위 이름을 참조해야 한다.

# 앱 배포

`app` 차트 하나를 서비스마다 release로 배포한다. 설치는 `deploy-app.sh stg <service>`로 한다.

## 구성

| PR | 경로 | 내용 |
| --- | --- | --- |
| 10 | `app/templates/deployment.yaml`, `service.yaml` | 공통 Deployment와 Service |
| 11 | `v3/eks/targets.tf` | Target Group 6개와 stg 검증 규칙 3개 |
| 12 | `app/templates/hpa.yaml`, `pdb.yaml`, `targetgroupbinding.yaml` | HPA, PDB, ALB 연결 |
| 13 | `app/templates/configmap.yaml`, `externalsecret.yaml`, `app-values/services` | 서비스별 환경변수와 SSM 매핑 |
| 14 | `app-values/stg/rest-api.yaml`, `backend-common.yaml` | stg rest-api |
| 15 | `app-values/stg/websocket.yaml` | stg websocket |
| 16 | `app-values/stg/fastapi.yaml`, `frontend.yaml` | stg fastapi, frontend |

values 적용 순서: 차트 기본값 → `services/backend-common` → `services/<service>` → `<stage>/backend-common` → `<stage>/<service>`

## 설계

- **단일 Chart:** 네 서비스의 차이가 포트, Probe, 종료 시간, HPA 값뿐이라 values로 나눈다. BE 두 서비스의 Secret은 `backend-common`으로 묶어 어긋나지 않게 한다.
- **Secret을 map으로 관리:** Helm이 list는 교체하고 map은 병합하므로, stg에만 있는 `GOOGLE_APPLICATION_CREDENTIALS`를 stg 파일에 추가할 수 있다.
- **종료 순서:** Kubernetes는 ALB 대상 제거와 SIGTERM이 동시에 진행되므로 `preStop` sleep으로 맞춘다.

| 서비스 | preStop | grace | Target Group 지연 |
| --- | --- | --- | --- |
| rest-api | 10초 | 30초 | 20초 |
| websocket | 125초 | 180초 | 120초 |
| fastapi | 10초 | 30초 | 없음 |
| frontend | 10초 | 30초 | 20초 |

- **HPA 환산:** HPA 목표는 request 대비 비율이므로 V2의 절대 CPU 사용량을 유지하도록 환산했다.

| 서비스 | V2 목표 | 절대값 | request | HPA 목표 |
| --- | --- | --- | --- | --- |
| rest-api | 1 vCPU의 60% | 600m | 500m | 120% |
| websocket | 0.5 vCPU의 60% | 300m | 250m | 120% |
| fastapi | 0.5 vCPU의 70% | 350m | 250m | 140% |
| frontend | 0.5 vCPU의 70% | 350m | 100m | 350% |

- **replicas 생략:** HPA를 쓰는 Deployment는 `replicas`를 두지 않아 `helm upgrade`가 HPA 값을 되돌리지 않게 한다. 첫 설치는 1개로 시작하고 HPA가 최소값까지 올린다.
- **첫 설치와 readiness gate:** Helm이 TargetGroupBinding을 Deployment 뒤에 만들어 첫 파드에는 gate가 주입되지 않는다. 트래픽이 없는 상태라 문제없고 다음 rollout부터 적용된다.
- **V2와 다른 환경변수 2건:** `JAVA_TOOL_OPTIONS`에 `-XX:ActiveProcessorCount=2`를 추가했고, rest-api에 Spring 종료 시간 15초를 추가했다.

## 작업 리스트

### 구현 완료 (커밋 전)

- [x] 공통 앱 Chart, HPA, PDB, TargetGroupBinding
- [x] 서비스별 ConfigMap, ExternalSecret
- [x] stg values 4개 서비스, 배포 스크립트

### 결정 필요

- [ ] stg 부하 테스트 종료 확인 후 stg Pod 배포 승인
- [ ] stg 검증 이미지: 현재 stg digest 유지 또는 prod digest로 교체
- [ ] CPU request 제안값(`rest-api` 500m, `websocket` 250m, `fastapi` 250m, `frontend` 100m)과 설계 문서 값(500m, 500m, 500m, 250m) 중 기준
- [ ] `fastapi` 메모리: 768Mi 유지 또는 설계 문서의 1GiB
- [ ] prod OTLP: V2 prod에 없는 `OTLP_METRICS_*`를 EKS prod에 켤지

### 검토 필요

- [ ] BE 이미지의 graceful shutdown 설정과 `SPRING_LIFECYCLE_TIMEOUTPERSHUTDOWNPHASE` 적용 여부
- [ ] `websocket`이 쓰는 rest 호출 주소가 이미지 기본값으로 `http://rest:8080`인지
- [ ] `fastapi`의 `/health`가 이미지 처리 중 liveness 3초 안에 응답하는지
- [ ] `frontend` HPA 350%가 노드 CPU 경합을 만들지 않는지
- [ ] rest-api 최대값을 DB 연결 기준 120 안에서 확정 (20번)
- [ ] 전환 후 과제: PriorityClass, ResourceQuota, `runAsNonRoot`, KEDA cron

## Kafka 도입 이후 변경 반영

V2에서 Kafka 도입 뒤 dev에 적용된 구성을 옮겼다. 현재 stg·prod 이미지는 Kafka 코드가 없어, 기존 4개 서비스 경로와 분리해 `--kafka` overlay로 켠다.

| V2 변경 | V3 반영 |
| --- | --- |
| `worker` 서비스 (소비자, 스케줄러 10개, outbox) | `services/worker.yaml`. 1개 고정, Recreate, grace 150초, Service 없음 |
| `matching` 서비스 (Kafka Streams) | `services/matching.yaml`. 1개, Recreate, grace 60초, state용 emptyDir |
| `MOYEOTA_TAXIPOT_MATCHING_MODE=kafka` | `stg/kafka/client.yaml` (rest-api, worker, matching) |
| `KAFKA_BOOTSTRAP_SERVERS` | `stg/kafka/client.yaml`, `stg/kafka/fastapi.yaml` |
| `MONGODB_URI`, `CONGESTION_AUTHOR_KEY_SECRET` | `stg/kafka/backend-common.yaml` |
| fastapi Qdrant, AI DB, 알림 봇 Secret | `stg/kafka/fastapi.yaml` |
| MSK 9092, Qdrant 6333 접근 | 추가 변경 없음. stg 노드 SG 규칙에 이미 포함 |
| worker·matching 태스크 Role | ECS Exec 권한뿐이라 Pod Identity 없음. ServiceAccount만 추가 |

사용법: `deploy-app.sh stg rest-api --kafka`. worker와 matching은 항상 overlay를 쓴다. 스크립트는 digest가 placeholder이거나 stg `MONGODB_URI`가 없으면 중단한다.

### Kafka 결정 필요

- [ ] 11/10 prod 전환 범위: Kafka 없이 4개 서비스 유지 (권장). prod에는 MSK와 SSM 10개가 없고, release 이미지에 Kafka 코드가 없다
- [ ] BE #336 이후, AI Kafka 포함 stg release 이미지 digest 지정
- [ ] stg MongoDB 준비: SSM `MONGODB_URI`와 저장소. dev EC2를 재사용하면 stg 노드 SG → dev 27017 규칙이 추가로 필요하다
- [ ] Kafka 검증 시 stg 노드 4대: 최소 메모리 8,704MiB로 3대(약 9,450MiB)에 롤링 여유가 없다

### Kafka 검토 필요

- [ ] worker Recreate는 교체 중 소비와 스케줄러가 멈춘다. 다중화하려면 BE 락 또는 `worker-scheduler` 분리가 필요하다
- [ ] matching의 실제 `state.dir`이 `/tmp/kafka-streams`인지
- [ ] stg MSK 토픽 9개가 `kafka-init`으로 생성됐는지
- [ ] release 이미지가 `KAFKA_BOOTSTRAP_SERVERS` 없는 prod에서 `localhost:9092`로 연결하지 않는지
- [ ] worker·matching Hikari 연결을 DB 연결 예산에 포함 (Kafka 켤 때)
- [ ] 17번 Alloy에 worker·matching 8090 지표 수집 추가
- [ ] Pod 설계 문서의 `worker-consumer`, `worker-stream` 이름을 실제 `worker`, `matching`과 맞춤

## 관측과 전환

| PR | 경로 | 내용 |
| --- | --- | --- |
| 17 | `values/alloy.yaml`, `values/kube-state-metrics.yaml` | 노드별 로그·지표 수집, 파드 상태 지표 |
| 18 | `v3/eks/alarms.tf`, `v3/observability` | 롤백 기준 알람과 Discord 알림, 전환 대시보드 |
| 19 | `v3/scripts/rehearse-stg.sh` | 단기 부하, 무중단 종료, 노드 drain, 가중치 리허설 |
| 20 | `app-values/prod`, `deploy-app.sh` | prod 배포값과 안전장치 |
| 21 | `v3/scripts/alb-weight.sh`, `cutover-check.sh` | 가중치 전환, 롤백, 기준 판정 |
| 22 | `v3/docs/cutover-result-template.md` | 전환 결과 양식 |

- **지표 경로:** V2 Prometheus에 remote write 수신이 없어 Alloy가 OTLP로 보낸다. stg BE는 앱이 직접 OTLP로 보내므로 스크랩하지 않는다.
- **ECS와 구분:** EKS 지표에 `platform=eks` 라벨을 붙이고, 대시보드는 라벨이 없는 지표를 ecs로 표시한다.
- **Target Group 연결 순서:** ALB에 연결되지 않은 Target Group은 대상이 healthy가 되지 않아 readiness gate가 막힌다. prod는 `alb-weight.sh prod set 0`으로 먼저 연결한 뒤 배포한다.
- **가중치 안전장치:** prod는 1→10→50→100 한 단계씩만 올리고, 올릴 때 EKS healthy 대상을 확인한다. 롤백은 검사 없이 전체 규칙을 되돌린다.
- **알림 경로:** V2의 CloudWatch→Discord 연결은 AWS에 없어 V3 Terraform이 별도로 만든다.

### 전환 당일 순서

1. `alb-weight.sh prod set 0`으로 EKS Target Group 연결
2. `CONFIRM_PROD_DEPLOY=yes deploy-app.sh prod <service>`를 fastapi, rest-api, websocket, frontend 순서로 실행
3. `alb-weight.sh prod status`로 healthy 확인
4. 15:00부터 `alb-weight.sh prod set 1`, 15:15 `10`, 15:45 `50`, 16:30 `100`
5. 다른 터미널에서 `cutover-check.sh prod --watch` 유지
6. 기준 초과 시 `alb-weight.sh prod rollback --yes`

### 관측·전환 검토 필요

- [ ] OTLP로 들어온 지표 이름이 V2 대시보드와 같은지 stg에서 확인
- [ ] `rolling` 전에 부하 사용자 토큰 재발급 (11/9 19:52 만료)
- [ ] 임시 `aws cloudwatch set-alarm-state`로 Discord 알림 도달 확인
- [ ] p95·RDS 알람은 기준대로 1분 초과에 울린다. 저트래픽 구간 오탐 시 조정

### 실행 순서 (승인 후)

1. `terraform apply`
2. `install-platform.sh`
3. `kubectl -n stg get externalsecret`로 동기화 확인
4. `deploy-app.sh stg fastapi`
5. `deploy-app.sh stg rest-api`
6. `deploy-app.sh stg websocket`
7. `deploy-app.sh stg frontend`
8. `X-Moyeota-Target: eks` 헤더로 stg 경로 검증

## dev·stg 추가 구성

- **dev 노드:** dev 파드는 `nodeStage: stg`로 non-prod 공용 노드(`stage=stg`)에 올린다. dev와 stg는 같은 노드 SG를 쓰므로 저장소 분리는 환경별 계정으로 한다.
- **2c 노드:** `stg-c` 노드 그룹과 `dev-c` 서브넷을 추가했고, `zoneSpread`로 파드를 AZ에 고르게 분산한다. NAT는 2a를 함께 쓴다.
- **stg MongoDB:** `v3/eks/mongodb.tf`. `dev-a`의 전용 EC2이고, 비밀번호와 `MONGODB_URI`는 호스트가 만들어 SSM에 저장한다. dev는 기존 dev EC2를 쓴다.
- **worker·matching:** ECS에서 실행 중이면 스케줄러가 중복되므로 `deploy-app.sh`가 중단한다. ECS를 0으로 줄인 뒤 배포한다. Argo CD Application은 이 검사를 거치지 않으므로 `argocd/dev/worker.yaml`, `matching.yaml`도 같은 순서로 적용한다.

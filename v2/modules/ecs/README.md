# Moyeota V2 ECS 모듈 (ecs-cluster · ecs-asg · ecs-service)

`issues/` 아래 설계 문서의 결정을 Terraform 모듈 3개로 나눠 구현했습니다.

| 문서 | 구현 위치 |
|---|---|
| [스테이지 별 ECS Cluster 분리를 통한 다중 클러스터 구조](../../../issues/ecs-multi-cluster-by-stage.md) | `ecs-cluster` |
| [클러스터·서비스 격리 기반 ECS Auto Scaling Group 정의](../../../issues/ecs-asg-by-cluster-service.md) | `ecs-asg`, `ecs-service`(전략·스케일링) |
| [네트워크 · 보안 경계](../../../issues/ecs-iam-network.md) | `ecs-cluster`(인스턴스 Role·SG), `ecs-service`(태스크 SG) |
| [ECS Task·Container 용량과 배치 결정](../../../issues/ECS-Task·Container-spec.md) | `ecs-service`, 루트 `locals.tf`의 `ecs_service_specs` |

```
infra-v2/
├── ecs.tf                       # 3개 모듈 호출 (스테이지 / 스테이지×ASG / 스테이지×서비스로 펼침)
├── locals.tf                    # ecs_service_specs, ecs_stage_settings (asg_groups, services)
├── variables.tf                 # ecs_stages, ecs_services, ecs_container_images, ecs_prod_alb_cutover, ...
├── output.tf                    # ecs_* 출력
└── modules/ecs/
    ├── ecs-cluster/             # 스테이지 경계 (스테이지당 1개)
    │   ├── main.tf              #   Cluster, Service Connect 네임스페이스, Exec 로그, Capacity Provider 등록
    │   ├── instance.tf          #   인스턴스 Role(자기 클러스터에만 등록) · 인스턴스 SG(인바운드 없음)
    │   └── iam.tf               #   Task Execution Role / Task Role / Deploy Role / Exec 운영자 정책
    ├── ecs-asg/                 # 1 Launch Template = 1 ASG = 1 Capacity Provider
    │   └── main.tf
    └── ecs-service/             # 애플리케이션 경계
        ├── main.tf              #   Task Definition, 태스크 SG, ip Target Group, Listener Rule, ECS Service
        └── autoscaling.tf       #   Service Auto Scaling (CPU / 커스텀 지표 / 예약)
```

## 계층과 책임

| 계층 | 모듈 | 경계 | 핵심 설정 |
|---|---|---|---|
| Cluster | `ecs-cluster` | 스테이지 | `moyeota-v2-<stage>`, 네임스페이스 `<stage>.moyeota-v2.local`, 기본 전략(general-od / dev는 shared-spot) |
| 호스트 풀 | `ecs-asg` | 같은 스테이지 안의 서비스 용량·장애 | `ECS_CLUSTER`, `ECS_INSTANCE_ATTRIBUTES={"role","purchase"}`, Spot draining, IMDS 차단, managed scaling 100% |
| Service | `ecs-service` | 애플리케이션 | `capacity_provider_strategy` + `memberOf(attribute:role == <role>)` + `distinctInstance`, awsvpc 태스크 SG |

스케일링은 **Service Auto Scaling(태스크) → Capacity Provider managed scaling(인스턴스)** 2단계입니다. ASG는 직접 스케일링하지 않으며 `desired_capacity`는 `ignore_changes`입니다.

## 스테이지별 구성 (`locals.tf` → `ecs_stage_settings`)

### Prod (`moyeota-v2-prod`, app 서브넷)

| ASG | 서비스 | 구매 | 타입 | min/max | 서비스 전략 |
|---|---|---|---|---|---|
| `moyeota-v2-prod-rest-od` | rest | On-Demand | t3.small | 2 / 3 | base 2, weight 0 |
| `moyeota-v2-prod-rest-spot` | rest | Spot (price-capacity-optimized, Capacity Rebalance) | 속성 기반 vCPU 2–4, 2–8 GiB, x86 | 0 / 4 | weight 1 |
| `moyeota-v2-prod-ws-od` | websocket | On-Demand | t3.small | 3 / 4 | base 3, weight 1 |
| `moyeota-v2-prod-general-od` | frontend, fastapi | On-Demand | t3.small | 1 / 2 | base 1, weight 1 (각각) |

| 서비스 | 태스크 min/max | 동적 정책 | 예약 정책 (KST, 평일) | scale-in |
|---|---|---|---|---|
| rest | 2 / 6 | CPU 60% | 06:50·16:50 min 3 → 09:10·19:10 min 2 | 허용 |
| websocket | 3 / 4 | CPU 60% (STOMP 세션 커스텀 지표로 교체 예정) | 없음 | **끔** (`disable_scale_in`) |
| frontend, fastapi | 1 / 2 | CPU 70% | 없음 | 허용 |

### Stg (`moyeota-v2-stg`, dev 서브넷)

Prod와 같은 4개 ASG 구조, 대수만 축소(rest-od 1/2, rest-spot 0/2, ws-od 1/3, general-od 1/2). REST 전략은 `rest-od {base 1, weight 0}` + `rest-spot {weight 1}`로 **weight 0 배치를 검증**합니다.

websocket은 Redis Pub/Sub 크로스 태스크 검증을 위해 **2태스크(min 2 / max 3, CPU 60%, scale-in 끔)** 로 둡니다. `distinctInstance` 때문에 태스크마다 ws-od 호스트가 1대씩 필요하고, 롤링 배포(min 100 / max 200) 때 새 태스크를 놓을 1대가 더 필요해 ws-od max를 3으로 둡니다.

> `general-od`는 문서값 1/1 대신 **1/2**입니다. t3.small은 ENI 3개라 awsvpc 태스크가 호스트당 2개까지인데, frontend+fastapi 2개로 꽉 차면 롤링 배포(새 태스크 +1)가 배치되지 못합니다.

### Dev (`moyeota-v2-dev`, dev 서브넷, ALB 없음)

`moyeota-v2-dev-shared-spot` 하나(vCPU 2–4, 4–8 GiB, 0/2)를 4개 서비스가 `binpack(memory)`로 공유합니다. 호스트당 awsvpc 태스크 2개 × 최대 2대 = 4태스크로 여유가 없어서, dev 배포는 `minimumHealthyPercent 0 / maximumPercent 100`(기존 태스크를 내리고 새로 띄움)입니다.

## 네이밍 · 태그

| 리소스 | 규칙 | 예 |
|---|---|---|
| ASG | `<project>-<stage>-<role>-<purchase>` | `moyeota-v2-prod-rest-spot` |
| Launch Template | ASG + `-lt` | `moyeota-v2-prod-rest-spot-lt` |
| Capacity Provider | ASG + `-cp` | `moyeota-v2-prod-rest-spot-cp` |
| 인스턴스 SG | `<project>-<stage>-ecs-instance` | 인바운드 없음 |
| 태스크 SG | `<project>-<stage>-<service>-task` | ALB SG → 앱·헬스체크 포트만 |
| Target Group | `<project>-<stage>-<service>` | `target_type = ip` |

ASG 인스턴스에는 `common_tags` + `Stage` / `Role` / `Purchase` / `AmazonECSManaged`가 `propagate_at_launch = true`로 붙습니다.

## ECS Service 생성 조건 · ALB 컷오버

- **ECS Service는 `ecs_container_images`에 이미지가 있는 스테이지·서비스만 만들어집니다.** 비워 두면 Cluster·ASG·Capacity Provider·IAM만 생성되고 ASG는 min 대수만 뜹니다.
- Task Definition은 최초 revision만 Terraform이 만들고, 이후 revision은 CI(Deploy Role)가 digest로 등록합니다. 서비스는 `task_definition`·`desired_count` 변경을 무시합니다.
- ECS Service가 Target Group을 쓰려면 Target Group이 ALB에 연결돼 있어야 하므로 서비스마다 Listener Rule을 만듭니다.

| 스테이지 | 우선순위 | 조건 | 비고 |
|---|---|---|---|
| prod (컷오버 전, 기본) | 100–103 | 경로 + `X-Moyeota-Stage: prod` 헤더 | 실제 트래픽은 기존 Compose 규칙(10–30)이 계속 받음 |
| prod (`ecs_prod_alb_cutover = true`) | 1–4 | 경로만 | 기존 규칙보다 앞서 ECS로 전환 |
| stg | 200–203 | 경로 + host `stg.moyeota.com` (Non-Prod ALB) | |
| dev | 300–303 | 경로 + host `dev.moyeota.com` (Non-Prod ALB) | |

```bash
# 컷오버 전 Prod ECS 스모크 테스트
curl -H 'X-Moyeota-Stage: prod' http://<alb_dns_name>/api/health
```

## 적용 순서

```bash
cd v2
terraform init        # modules/ecs/ecs-cluster, ecs-asg, ecs-service 등록
terraform fmt -recursive
terraform validate
terraform plan -out=v2-ecs.tfplan
terraform apply v2-ecs.tfplan
```

- 처음에는 `ecs_container_images = {}`로 Cluster·ASG만 만들고, Stg 이미지로 서비스를 올려 검증한 뒤 Prod를 추가하는 순서를 권장합니다.
- 기존 EC2·ALB·Target Group 리소스에 `~`(변경)나 `-`(삭제)가 보이면 적용하지 마세요.
- AMI(SSM `recommended`)가 갱신되면 Launch Template이 바뀌고 **instance refresh(min/max healthy 100%)** 가 시작됩니다. `ws-od`는 연결이 끊기므로 출퇴근 시간대(07–09, 17–19시)를 피해 apply합니다.
- destroy 시 scale-in protection 때문에 ASG 삭제가 막힐 수 있습니다. 서비스 desired를 0으로 내려 인스턴스가 비워진 뒤 삭제합니다.

## 적용 후 검증 (issues/ecs-asg-by-cluster-service.md 8절)

- [ ] (Stg) rest desired 1 → 2: 첫 태스크는 `rest-od`, 두 번째는 `rest-spot`에만 뜨는지. 안 되면 `rest-od {base, weight 1}` + `rest-spot {weight 4}`로 전환
- [ ] `rest-spot` 인스턴스에 AWS FIS Spot 중단(`fis_experiment_template_ids.stg.rest_spot_interruption`) → `DRAINING` 후 대체 태스크가 다른 인스턴스에 뜨는지
- [ ] (Stg) websocket 2태스크가 서로 다른 ws-od 호스트에 뜨고, 한 태스크에 붙은 클라이언트의 메시지가 다른 태스크의 클라이언트에 도달하는지 (Redis Pub/Sub)
- [ ] FIS `websocket_task_stop` → 대체 태스크 RUNNING·ALB healthy까지 시간, 그 사이 publish된 메시지 유실 여부
- [ ] FIS `container_instance_drain` → 재배치 중 Capacity Provider가 인스턴스를 늘리는지
- [ ] (Stg 브로커) 채널 구독자 수(`PUBSUB NUMSUB moyeota:stg:chat:fanout:v1`) = websocket 태스크 수. BE 이미지에는 redis-cli가 없으므로 listener 구독 성공 로그(태스크 ID 포함)나 CloudWatch `CurrConnections`로 확인
- [ ] (Stg 브로커) REST에서 만든 시스템 메시지(택시팟 참여 등)가 모든 websocket 태스크의 구독자에게 도달하는지
- [ ] (Stg 브로커 장애) Redis 노드 재시작 → listener 재구독, 재시작 중 메시지는 이력 API로 복구되는지, 저장 성공 응답이 Redis 실패로 바뀌지 않는지

```bash
# Redis 전체 장애 시나리오 (stg 단일 노드 재시작)
aws elasticache reboot-cache-cluster \
  --cache-cluster-id moyeota-v2-stg-redis-001 --cache-node-ids-to-reboot 0001

# 재시작 전후 연결 수 (구독 연결 재수립 확인)
aws cloudwatch get-metric-statistics --namespace AWS/ElastiCache --metric-name CurrConnections \
  --dimensions Name=CacheClusterId,Value=moyeota-v2-stg-redis-001 \
  --start-time $(date -u -v-30M +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 60 --statistics Maximum
```
- [ ] websocket 태스크가 `ws-od` 외 호스트에 배치되지 않는지 (`memberOf`)
- [ ] dev 인스턴스 Role로 prod 클러스터 `RegisterContainerInstance`가 `implicitDeny`인지
- [ ] 태스크 컨테이너에서 `169.254.169.254` 호출이 막히는지 (`ECS_AWSVPC_BLOCK_IMDS`)
- [ ] 롤링 배포 중 ASG가 min + 1까지 늘었다가 15분 뒤 돌아오는지
- [ ] instance refresh(100/100) 중 태스크가 있는 인스턴스가 drain 후 교체되는지

```bash
# dev 인스턴스 Role이 prod 클러스터에 등록하면 거부되어야 한다
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<account-id>:role/moyeota-v2-dev-ecs-instance \
  --action-names ecs:RegisterContainerInstance \
  --resource-arns arn:aws:ecs:ap-northeast-2:<account-id>:cluster/moyeota-v2-prod
# → EvalDecision: implicitDeny

# dev Deploy Role로 prod 서비스를 갱신하면 거부되어야 한다
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<account-id>:role/moyeota-v2-dev-deploy \
  --action-names ecs:UpdateService \
  --resource-arns arn:aws:ecs:ap-northeast-2:<account-id>:service/moyeota-v2-prod/rest
# → EvalDecision: implicitDeny
```

## 아직 구현하지 않은 것 (문서의 미결 사항·다음 단계)

| 항목 | 현재 | 다음 단계 |
|---|---|---|
| Stg·Prod Blue/Green 배포 | 모든 스테이지 롤링(min 100 / max 200, dev 0 / 100) + circuit breaker | ECS 네이티브 Blue/Green(대체 Target Group, 테스트 리스너) 추가. Blue/Green 서비스는 `ALBRequestCountPerTarget` 스케일링 불가 |
| WebSocket 동적 지표 | CPU 60% + scale-in 끔 | 앱이 STOMP 세션 수를 발행하면 `autoscaling.custom_metric`으로 교체 (모듈은 지원) |
| Stg 서브넷 | dev 서브넷 공유 | `stg-a`(예: 10.20.42.0/24)와 NAT 경로 결정 |
| Service Connect | 모듈 지원(`service_connect`), 기본 off. `ecs_service_connect_stages`에 넣으면 fastapi 서버 / rest·websocket 클라이언트 | 앱의 FastAPI 호출 URL을 `http://fastapi:8000`으로 바꾼 뒤 스테이지별로 켠다 |
| 데이터 계층 SG | 브로커 Redis SG(stg·prod)·dev EC2 SG(3306/6379)가 rest·websocket 태스크 SG만 허용 (`broker.tf`) | RDS SG 추가 |
| 채팅 브로커 | `broker.tf`: Redis Pub/Sub(dev compose / stg 단일 / prod replica 1), 연결 값 SSM 자동 주입, 노드 알람 | BE fan-out 어댑터(발행·listener)와 `APP_ROLE` 조건부 등록 구현 후 stg 검증 |
| 앱 설정·시크릿 | `JAVA_TOOL_OPTIONS`만 | `/moyeota-v2/<stage>/<service>/*` SSM·Secrets ARN을 `secrets`로 주입 |
| WebSocket 인스턴스 타입 | ECS는 t3.small (문서), Compose 호스트 변수는 t3.medium | 하나로 통일 |
| ALB 2-AZ 대상 요건 | 단일 AZ(app-a) 태스크만 | `app-c`에 최소 대상을 둘지 결정 |

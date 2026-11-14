# v4 — ECS 최소 운영 환경

V3(EKS) prod를 비용 최소 구성으로 옮기기 위한 별도 Terraform root다. 설계는 [`v3/docs/ECS_MINIMAL_OPS_TRANSITION.md`](../v3/docs/ECS_MINIMAL_OPS_TRANSITION.md)를 따른다.

- state: `moyeota-v2-tfstate` / `infra-v4/terraform.tfstate` (V2·V3와 분리)
- 스테이지: prod 하나
- V2 코드는 참고만 한다. 모듈은 복사해 단순화하고 `../v2`를 참조하지 않는다.

## 책임 경계

| 구분 | 리소스 |
|---|---|
| V2 소유, v4는 읽기만 (`shared.tf`) | VPC, public 서브넷, NAT Gateway, S3 Gateway Endpoint, prod ALB·HTTPS 리스너, RDS, ALB·RDS·모니터링 SG, GitHub OIDC Provider, 이미지 버킷, 앱 시크릿(`/moyeota/v2/prod/*`) |
| v4 소유 | private 서브넷 2개와 라우팅 테이블, ECS 클러스터·용량·서비스·TG·리스너 규칙, 데이터 호스트, IAM, 알람, `/moyeota/v4/prod/*` 파라미터 |
| v4가 V2 SG에 추가하는 규칙 | RDS 3306 ← rest·websocket 태스크, 모니터링 3100 ← v4 인스턴스(Alloy 로그), 모니터링 9090 ← rest·websocket·fastapi 태스크(OTLP 지표) |
| v4가 V2 리소스에 추가하는 것 | prod HTTPS 리스너 규칙(우선순위 10·11·13), S3 Gateway Endpoint 라우팅 테이블 연결 |

## 파일

| 파일 | 내용 | 상태 |
|---|---|---|
| `versions.tf`, `variables.tf`, `locals.tf` | provider, backend, 변수, 서비스·ARN 패턴 | 작성 |
| `shared.tf` | V2 공유 리소스 data source | 작성 |
| `network.tf` | private 서브넷(2a·2c), 라우팅 테이블(V2 NAT Gateway 경유), S3 Endpoint 연결 | 작성 |
| `security.tf` | 인스턴스·태스크·데이터 호스트 SG, V2 RDS·모니터링 SG 인바운드 | 작성 |
| `iam.tf` | Task Execution·Task·컨테이너 인스턴스·Deploy Role | 작성 |
| `cluster.tf`, `templates/alloy.alloy.tftpl` | ECS 클러스터(Container Insights 끔), Service Connect 네임스페이스, Exec 로그, Alloy DAEMON(로그 → Loki) | 작성 |
| `capacity.tf` | Spot ASG(min 2 / max 3, 2a·2c) + On-Demand 폴백 ASG(min 0), Capacity Provider | 작성 |
| `services.tf` | 서비스 4개(rest·websocket·frontend·fastapi) Task Definition, 서비스, TG, 리스너 규칙 | 작성 |
| `data_host.tf`, `ssm.tf`, `templates/data-host/` | Kafka·MongoDB·Redis 데이터 호스트(On-Demand, 고정 IP, 데이터 EBS·일일 스냅샷·자동 복구), v4 파라미터 | 작성 |
| `alarms.tf` | CloudWatch 알람, ECS·ASG 이벤트, Discord #incident 알림 | 작성 |

## 사용

```bash
cp terraform.tfvars.example terraform.tfvars   # 값 확인
terraform init
terraform plan
```

- `terraform.tfvars`는 커밋하지 않는다.
- 이 root를 apply해도 V2 리소스는 바뀌지 않는다. 다만 V2 SG에 인바운드 규칙이 추가되고, V2 S3 Endpoint에 v4 라우팅 테이블이 연결된다.
- V2를 apply하면 V2 S3 Endpoint의 라우팅 테이블 목록이 V2 값으로 되돌아갈 수 있다. 그때는 S3 트래픽이 NAT로 우회하므로 v4를 다시 apply한다.

## 데이터 호스트 운영

| 작업 | 방법 |
|---|---|
| 접속 | `aws ssm start-session --target <data_host.instance_id>` |
| 부트스트랩 로그 | `/var/log/data-host-bootstrap.log` |
| 구성 다시 맞추기 (토픽, MongoDB 앱 계정, URI) | `sudo data-host-apply` |
| 컨테이너 교체 (이미지·설정 변경) | 스크립트의 이미지 값을 고친 뒤 `sudo data-host-apply --recreate kafka\|mongo\|redis`. 데이터는 `/mnt/data`에 남는다 |
| 상태 확인 | `sudo docker ps`, `sudo docker logs --tail 50 kafka` |

- AMI·user_data 변경은 `ignore_changes`라 기존 호스트를 교체하지 않는다. 새로 만드는 호스트에만 적용된다.
- 데이터 EBS는 `prevent_destroy`다. 호스트를 교체해도 볼륨을 다시 붙이면 데이터가 남는다.
- 하드웨어 장애(시스템 상태 검사 실패)는 CloudWatch 자동 복구로 같은 인스턴스·IP·EBS로 돌아온다.

## 서비스 구성

| 서비스 | 태스크 (vCPU / 메모리) | 노출 | 비고 |
|---|---|---|---|
| rest | 1 / 2GiB (컨테이너 1792MiB + Service Connect 여유) | `/api/*` (우선순위 11) | `APP_ROLE=var.rest_app_role`, Service Connect 클라이언트(`http://fastapi:8000`), websocket과 다른 호스트 |
| websocket | 0.5 / 1GiB | `/api/wss` (우선순위 10), 드레이닝 60초 | rest와 다른 호스트 |
| frontend | 0.25 / 768MiB | `/*` (우선순위 13) | |
| fastapi | 0.5 / 1GiB (컨테이너 768MiB + Service Connect 여유) | 내부 전용 | Service Connect 서버, 모니터링 봇 값 미주입 |

- 레플리카는 서비스마다 1개다. 배포는 기존 태스크를 먼저 내리고 새 태스크를 띄운다(약 2~3분 중단).
- Task Definition은 부트스트랩 revision이다. 서비스는 `task_definition`을 ignore하고, 이후 이미지는 CD가 digest로 반영한다.

### apply 전에 SSM에 있어야 하는 값

하나라도 없으면 태스크가 시작되지 않는다(`ResourceInitializationError`).

| 경로 | 키 |
|---|---|
| `/moyeota/v2/prod/backend/` | ACCOUNT_ENC_KEY, DB_HOST, DB_NAME, DB_PASSWORD, DB_PORT, DB_USERNAME, EXTRA_FRONT_ORIGINS, FCM_SERVICE_ACCOUNT_JSON, FRONT_CALLBACK_URI, FRONT_URL, IMAGE_PUBLIC_BASE_URL, INTERNAL_API_KEY, JWT_SECRET, KAKAO_ADMIN_KEY, KAKAO_CLIENT_ID, KAKAO_CLIENT_SECRET, KAKAO_REDIRECT_URI, MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE, MANAGEMENT_ENDPOINT_PROMETHEUS_ENABLED, MOYEOTA_AUTH_COOKIE_SAMESITE, MOYEOTA_AUTH_COOKIE_SECURE, MOYEOTA_NOTIFICATION_PUSH_ENABLED, MOYEOTA_RELAY_ENV, S3_BUCKET, SERVER_FORWARD_HEADERS_STRATEGY, SPRING_PROFILES_ACTIVE, CONGESTION_AUTHOR_KEY_SECRET |
| `/moyeota/v2/prod/broker/` | CHAT_FANOUT_CHANNEL |
| `/moyeota/v2/prod/ai/` | OPENAI_API_KEY_1, OPENAI_API_KEY_2, ANTHROPIC_API_KEY, MODAL_TOKEN_ID_2, MODAL_TOKEN_SECRET_2 |
| `/moyeota/v2/prod/frontend/` | SENTRY_DSN, SENTRY_ENVIRONMENT, SENTRY_TRACES_SAMPLE_RATE |
| `/moyeota/v4/prod/` | v4가 만든다 (broker 3개는 Terraform, MONGODB_URI는 데이터 호스트) |

확인:

```bash
for g in backend broker ai frontend; do aws ssm get-parameters-by-path --path /moyeota/v2/prod/$g/ --query 'Parameters[].Name' --output text | tr '\t' '\n'; done | sort
```

## 전환 런북 (설계 10절)

| 단계 | tfvars | 그 밖의 작업 |
|---|---|---|
| D1 구축 | `rest_app_role = "rest"`, `cutover_enabled = false` | **V2-1(V2 prod 규칙 우선순위 1 → 100)을 먼저 적용**한다. 그 전에는 V2 규칙(1·2·4)이 먼저 걸려 헤더 테스트가 v4로 오지 않는다. 테스트: `curl -H 'X-Moyeota-Target: v4' https://<도메인>/api/...` |
| D2 전환 | `rest_app_role = "rest,worker,matching"`, `cutover_enabled = true` | EKS worker·matching을 0으로 내리고 consumer lag 0, MongoDB 복원을 마친 뒤 apply. 이어서 rest를 새 revision으로 갱신한다(아래) |
| 롤백 (D3 전) | `cutover_enabled = false`, `rest_app_role = "rest"` | apply 후 rest 갱신, EKS worker·matching을 1로 |

Terraform으로 환경 변수를 바꾸면 새 revision만 등록되고 서비스는 그대로다(`ignore_changes`). 서비스를 갱신한다:

```bash
aws ecs update-service --cluster moyeota-v4-prod --service rest --task-definition moyeota-v4-prod-rest --force-new-deployment
```

- family 이름만 주면 최신 revision을 쓴다. CD가 그 사이 새 이미지를 등록했다면 그 revision의 이미지와 Terraform 환경 변수가 섞이지 않았는지 `describe-task-definition`으로 확인한다.

## Spot 용량 부족 런북

1. 알람(태스크 수 부족) 또는 `aws ecs describe-services`에서 태스크가 PROVISIONING에 머무는지 확인한다.
2. `capacity_mode = "od"`로 바꿔 apply한다. 서비스가 On-Demand ASG(t3.medium)로 다시 배치된다.
3. Spot 용량이 돌아오면 `capacity_mode = "spot"`으로 되돌린다.

## 알람과 알림 (`alarms.tf`)

모든 알림은 Discord #incident(`/moyeota/v2/monitoring/DISCORD_WEBHOOK_INCIDENT`)로 간다. Container Insights를 껐기 때문에 태스크 수 지표 대신 TG 정상 대상 수와 ECS 이벤트로 서비스 중단을 본다.

| 대상 | 알람·이벤트 | 기준 |
|---|---|---|
| rest·websocket·frontend | `<svc>-no-healthy-target` | 정상 대상 0개 3분 |
| rest·websocket·frontend | `<svc>-5xx-ratio` | 5xx 5% 초과, 5분 중 3분 (분당 요청 10건 이상일 때만) |
| rest | `rest-p95` | p95 1초 초과, 5분 중 3분 |
| websocket | `websocket-connection-errors` | 대상 연결 오류 발생 |
| 서비스 4개 | `<svc>-memory` | 메모리 사용률 90% 초과 10분 |
| RDS | `rds-connections`, `rds-cpu`, `rds-surplus-credits-charged`, `rds-free-storage` | 연결 70개, CPU 80% 15분, 크레딧 초과 과금, 남은 공간 2GiB 미만 |
| 데이터 호스트 | `data-host-system-check`(자동 복구), `data-host-instance-check`, `data-host-cpu` | 상태 검사 실패, CPU 80% 15분 |
| ECS 서비스 | 이벤트 `ECS Service Action` WARN·ERROR | 배치 실패, 태스크 시작 실패 |
| ECS 배포 | 이벤트 `SERVICE_DEPLOYMENT_FAILED` | circuit breaker 롤백 |
| 앱 호스트 ASG | 이벤트 `EC2 Instance Terminate Successful`, `EC2 Instance Launch Unsuccessful` | Spot 회수·교체, Spot 용량 부족 |

- 데이터 호스트의 메모리·디스크는 CloudWatch 에이전트가 없어 알람이 없다. `docker stats`, `df -h /mnt/data`로 확인한다.
- 알람 이름은 모두 `moyeota-v4-prod-`로 시작한다. 이 접두사의 알람 상태 변화만 Discord로 간다.

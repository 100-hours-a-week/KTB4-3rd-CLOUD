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
| v4가 V2 SG에 추가하는 규칙 | RDS 3306 ← rest·websocket 태스크, 모니터링 3100·9090 ← v4 인스턴스(Alloy) |

## 파일

| 파일 | 내용 | 상태 |
|---|---|---|
| `versions.tf`, `variables.tf`, `locals.tf` | provider, backend, 변수, 서비스·ARN 패턴 | 작성 |
| `shared.tf` | V2 공유 리소스 data source | 작성 |
| `network.tf` | private 서브넷(2a·2c), 라우팅 테이블(V2 NAT Gateway 경유), S3 Endpoint 연결 | 작성 |
| `security.tf` | 인스턴스·태스크·데이터 호스트 SG, V2 RDS·모니터링 SG 인바운드 | 작성 |
| `iam.tf` | Task Execution·Task·컨테이너 인스턴스·Deploy Role | 작성 |
| `cluster.tf`, `capacity.tf`, `services.tf` | ECS 클러스터, Spot ASG·Capacity Provider, 서비스·TG·리스너 규칙 | 예정 (V4-7~V4-9) |
| `data_host.tf`, `ssm.tf`, `templates/data-host/` | Kafka·MongoDB·Redis 데이터 호스트(On-Demand, 고정 IP, 데이터 EBS·일일 스냅샷·자동 복구), v4 파라미터 | 작성 |
| `alarms.tf` | 알람, Spot 회수 알림, Discord | 예정 (V4-10) |

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

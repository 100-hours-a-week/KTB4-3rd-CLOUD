# V2 stg 데이터 계층 끄기·켜기

작성일: 2026-11-13
범위: stg의 MSK, ElastiCache Redis, RDS. prod와 dev는 건드리지 않는다.
코드: `stg_data_layer.tf`, `msk.tf`, `broker.tf`, 변수 `stg_data_layer_enabled`
실행: `scripts/stg-data-layer.sh {status|down|up}`

## 1. 왜 끄는가

2026-11-12 기준 stg 앱은 쓰이지 않는다 (v2 stg ECS 앱 태스크 0개, v3 EKS stg 노드그룹 0대). 그런데 데이터 계층은 계속 과금된다.

| 리소스 | 사양 | 하루 비용 | 끈 뒤 남는 비용 |
|---|---|---|---|
| MSK `moyeota-v2-stg` | kafka.m7g.large × 3, 100GiB × 3 | 약 $19.2 | 0 |
| RDS `moyeota-v2-stg` | db.t4g.small, Single-AZ, 20GiB | 약 $1.3 | 스토리지·백업만 (약 $0.1) |
| ElastiCache `moyeota-v2-stg-redis` | cache.t4g.micro × 1 | 약 $0.6 | 0 |
| 합계 | | 약 $21 (월 약 $630) | 약 $0.1 |

## 2. 서비스별 방식

| 리소스 | AWS 중지 기능 | 방식 |
|---|---|---|
| MSK | 없음 | Terraform으로 클러스터 삭제, 켤 때 같은 설정으로 다시 생성 |
| ElastiCache | 없음 | Terraform으로 복제 그룹 삭제, 켤 때 다시 생성. Pub/Sub 전용이라 스냅샷은 두지 않는다 |
| RDS | 있음 | CLI로 중지·시작. Terraform 밖(stg-rds-create.sh로 만든 인스턴스)이라 삭제하지 않는다 |

### 끌 때 남기는 것과 지우는 것

| 남김 | 이유 |
|---|---|
| 보안그룹 `moyeota-v2-stg-msk`, `moyeota-v2-stg-redis`와 인바운드 규칙 | `v3/eks/security.tf`가 이름으로 조회한다. 지우면 v3 plan이 깨진다 |
| SSM `/moyeota/v2/stg/broker/KAFKA_BOOTSTRAP_SERVERS`, `REDIS_HOST` | v2 ECS 태스크 정의 secrets와 v3 External Secrets가 참조한다. 꺼진 동안 값은 `stg-data-layer-paused.invalid` |
| MSK 설정, 세 번째 AZ 서브넷, kafka-init 태스크 정의, 로그 그룹 | 다시 켤 때 그대로 쓴다. 과금이 거의 없다 |

| 지움 | 비고 |
|---|---|
| `aws_msk_cluster.kafka["stg"]`, 스토리지 오토스케일링 | 토픽·메시지·Streams 상태가 사라진다 |
| `aws_elasticache_replication_group.redis["stg"]` | Pub/Sub 전용이라 잃는 데이터가 없다 |
| stg Redis 알람 3개 (MSK 알람은 alert 설정상 없음) | 없는 노드에 알람이 울리지 않게 |

꺼진 동안에는 `moyeota-v2-stg-rds-keep-stopped` 스케줄이 매일 05:00(KST)에 stg RDS를 다시 중지한다. AWS는 중지한 RDS를 7일 뒤 자동으로 시작하기 때문이다. 이미 중지 상태면 호출이 실패하고 끝나며(재시도 없음), 상태는 바뀌지 않는다.

## 3. 끄기

1. 쓰는 사람이 없는지 확인한다. 스크립트도 확인하지만, 팀 채널에 먼저 알린다.
   ```bash
   v2/scripts/stg-data-layer.sh status
   ```
   v2 stg ECS 앱 서비스 desired와 v3 EKS stg 노드그룹 desired가 모두 0이어야 한다.
2. `v2/terraform.tfvars`에서 `stg_data_layer_enabled = false`로 바꾼다.
3. 실행한다. Terraform 확인 프롬프트에서 계획을 보고 `yes`를 입력한다.
   ```bash
   v2/scripts/stg-data-layer.sh down
   ```
   - 예상 계획: 3 to add, 2 to change, 7 to destroy (2026-11-13 plan 기준)
   - 삭제·변경 대상에 `prod`가 있으면 중단한다.
   - MSK 삭제에 15~30분 걸린다. 끝나면 stg RDS를 중지한다.
4. `status`로 MSK·Redis가 `없음`(또는 `DELETING`), RDS가 `stopping`/`stopped`인지 확인한다.

## 4. 켜기

stg를 쓰기 **40분 전**에 시작한다.

1. `v2/terraform.tfvars`에서 `stg_data_layer_enabled = true`로 바꾼다.
2. 실행한다.
   ```bash
   v2/scripts/stg-data-layer.sh up
   ```
   순서: RDS 시작 → MSK·Redis 생성(-target apply, MSK가 20~40분) → RDS available 대기 → kafka-init으로 토픽 생성.
   kafka-init은 stg ECS 클러스터에서 돈다. 호스트가 0대면 Capacity Provider가 1대를 띄울 때까지 PENDING이다.
3. 앱을 올린다. MSK·Redis 주소가 새 값으로 바뀌므로 **앱은 데이터 계층보다 나중에** 띄운다.
   - v2 stg ECS: `stg_qa_schedule` 또는 `scripts/ecs-stg-qa.sh`. 새 태스크가 시작될 때 SSM 값을 읽는다.
     이미 떠 있던 태스크가 있다면 `aws ecs update-service --force-new-deployment`로 바꿔 띄운다.
   - v3 EKS stg: External Secrets가 새 SSM 값을 가져온 뒤(refreshInterval) 파드를 재시작한다.
4. 선택: 끈 동안 반영하지 않은 Prometheus 설정(`module.monitoring` prometheus.yml)에 stg MSK 수집 대상이 다시 들어간다.
   다음 정기 apply에서 함께 반영된다.

## 5. 주의

- **전체 `terraform apply`로 토글하지 않는다.** 2026-11-13 기준 v2에는 이 작업과 무관한 미적용 변경이 있다
  (prod RDS Multi-AZ 전환, prod 태스크 정의 교체 등, plan 기준 6 add / 29 change / 4 destroy).
  스크립트는 stg 데이터 계층 리소스만 `-target`으로 적용한다.
- 꺼진 상태에서 다른 사람이 전체 apply를 해도 tfvars 값이 `false`라면 stg 클러스터가 다시 생기지 않는다.
  tfvars는 git에 없으므로(`*.tfvars` ignore) apply하는 사람의 로컬 파일 값이 기준이다. 팀에 현재 상태를 공유한다.
- Prometheus는 끈 동안에도 이전 stg MSK 주소를 수집하려다 down으로 표시될 수 있다. 신경 쓰이면
  `-target='module.monitoring[0].aws_s3_object.config["prometheus/prometheus.yml"]'`를 함께 적용한다
  (단, 그 파일의 다른 미적용 변경도 같이 반영된다).
- stg RDS 설정을 Terraform·CLI로 바꿔야 하면 먼저 시작한다. 중지 상태에서는 수정이 실패한다.
- `migration_rehearsal_enabled = true`인 동안 `migration.tf`가 stg RDS를 data source로 조회한다. 중지 상태에서도 조회는 된다.
- MSK 브로커 주소는 다시 만들 때마다 바뀐다. 주소를 하드코딩한 곳 없이 SSM만 보게 유지한다.

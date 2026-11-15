# V3 EKS 정리(D3)와 재구축 런북

v4 전환(`v3/docs/ECS_MINIMAL_OPS_TRANSITION.md`) 뒤 V3 EKS를 내리고, 필요할 때(리허설·시연) 다시 띄우는 절차다.

- 대상: `v3/eks` Terraform root(state `infra-v3-eks/terraform.tfstate`), `v3/helm`, `v3/argocd`
- 전제: 이 문서 기준 커밋의 `v3/eks` 코드는 실제 리소스와 일치한다(`terraform plan` 변경 0). 정리 전에 다시 plan으로 확인한다.
- 공통 환경: `export AWS_PROFILE=moyeota-terraform AWS_REGION=ap-northeast-2`
- EKS API는 허용 IP(`api_public_cidrs`)에서만 접근된다. 다른 네트워크에서 작업하면 IP를 먼저 추가한다.

## 1. 로컬에만 있는 입력 (정리 전에 백업)

아래 값은 레포에 없다. 잃어버리면 재구축 때 다시 만들어야 하므로 팀 비밀 저장소에 보관한다.

| 항목 | 위치 | 비고 |
|---|---|---|
| V3 tfvars | `v3/eks/terraform.tfvars` | `vpc_id`, `cluster_version`, 2c 서브넷 CIDR, `api_public_cidrs`, `stages`, `mongodb_prod_image`(ECR 미러 digest) |
| V2 tfvars | `v2/terraform.tfvars` | D3의 V2 변경에 필요 |
| v4 tfvars | `v4/terraform.tfvars` | 현재 운영값(`rest_app_role`, `cutover_enabled` 등) |
| Argo CD 알림 토큰 | `argocd` namespace `argocd-notifications-secret` | CLOUD 저장소 쓰기 토큰(`v3/argocd/README.md`) |
| MongoDB 이미지 미러 | ECR `moyeota/mongo` | 데이터 서브넷에 NAT가 없어 Docker Hub 대신 쓴다. 정리 때 지우지 않는다(3-4) |

## 2. 정리 전 조건

- [ ] v4 전환 후 24시간 이상 알람·로그 이상 없음
- [ ] 앱 레포 CD가 v4로 교체됨 (V3 prod CD 삭제)
- [ ] v4 `mongo_migration_enabled = false` apply (v4가 V3 MongoDB SG를 조회하므로 먼저 끈다)
- [ ] `cd v3/eks && terraform plan` → 변경 0

## 3. D3 정리 절차

### 3-1. MongoDB 데이터 스냅샷

V3 DLM이 매일 스냅샷(14일 보관)을 만들지만, 정리 직전 상태를 따로 남긴다.

```bash
for v in $(aws ec2 describe-volumes --filters Name=tag:Name,Values='moyeota-v3-*mongodb*-data' --query 'Volumes[].VolumeId' --output text); do
  aws ec2 create-snapshot --volume-id "$v" --description "v3 mongodb before teardown" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=v3-teardown}]' --query SnapshotId --output text
done
```

DLM 정책은 destroy 때 지워지지만, 이미 만든 스냅샷은 남는다.

### 3-2. 리스너 규칙에서 EKS Target Group 떼기

prod 리스너의 V2/EKS 가중치 규칙(5·6·8)은 가중치가 0이어도 EKS TG를 참조한다. 참조가 남아 있으면 TG를 지울 수 없다. v4 규칙(1·2·3)이 모든 요청을 먼저 받으므로 5·6·8은 트래픽이 없다.

```bash
L=$(aws elbv2 describe-listeners --load-balancer-arn "$(aws elbv2 describe-load-balancers --names moyeota-v2-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)" --query 'Listeners[?Port==`443`].ListenerArn | [0]' --output text)
for p in 5 6 8; do
  rule=$(aws elbv2 describe-rules --listener-arn "$L" --query "Rules[?Priority=='$p']" --output json)
  arn=$(jq -r '.[0].RuleArn' <<<"$rule")
  ecs=$(jq -r '.[0].Actions[0].ForwardConfig.TargetGroups[] | select(.TargetGroupArn | contains("/moyeota-v2-prod-")) | .TargetGroupArn' <<<"$rule")
  aws elbv2 modify-rule --rule-arn "$arn" --actions "Type=forward,TargetGroupArn=$ecs" --query 'Rules[0].Priority' --output text
done
```

이 규칙들은 3-6의 V2 apply(prod ECS 스테이지 삭제) 때 함께 사라진다. nonprod ALB의 stg·dev 시험 규칙(`X-Moyeota-Target: eks`)은 V3 state 소유라 destroy가 지운다.

### 3-3. 앱과 플랫폼 내리기 (권장)

Kubernetes가 만든 AWS 리소스(TargetGroupBinding의 대상 등록)를 깨끗이 정리하려고 destroy 전에 앱을 먼저 지운다.

```bash
aws eks update-kubeconfig --name moyeota-v3-eks --alias v3-eks
kubectl -n argocd delete applications --all
for ns in prod stg dev; do helm -n "$ns" list -q | xargs -r -n1 helm -n "$ns" uninstall; done
```

### 3-4. destroy를 막는 리소스 state에서 빼기

| 리소스 | 이유 | 처리 |
|---|---|---|
| `aws_ebs_volume.mongodb_prod_data`, `aws_ebs_volume.mongodb_data` | `prevent_destroy` | state에서 빼고, 3-1 스냅샷 확인 후 콘솔·CLI로 직접 삭제 |
| `aws_ecr_repository.mongodb` | 이미지가 있으면 삭제 실패, 재구축에 다시 필요 | state에서 빼고 남겨 둔다 (보관 비용 미미) |

```bash
cd v3/eks
terraform state rm 'aws_ebs_volume.mongodb_prod_data' 'aws_ebs_volume.mongodb_data' 'aws_ecr_repository.mongodb'
```

### 3-5. destroy

```bash
terraform plan -destroy -out=teardown.tfplan   # 삭제 대상 확인: 클러스터, 노드 그룹, MongoDB EC2, NAT-c, EKS TG, V2 SG에 추가한 규칙, 알람
terraform apply teardown.tfplan
```

- v4는 V2 NAT Gateway(2a)를 쓰므로 NAT-c가 사라져도 영향이 없다.
- 남은 EBS(3-4)는 스냅샷을 확인한 뒤 삭제한다: `aws ec2 delete-volume --volume-id <id>`

### 3-6. V2 정리 (설계 8.2절 V2-2~V2-5)

V2 apply는 V2 prod 리스너 규칙(5·6·8)과 prod ECS 스테이지를 지운다. v4 규칙(1·2·3)이 트래픽을 받으므로 영향이 없다.

| 변경 | tfvars·코드 |
|---|---|
| prod ECS 스테이지 삭제 | `ecs_stages`, `ecs_container_images.prod` |
| MSK·ElastiCache prod 삭제 | `msk_stages`, `elasticache_redis_stages` |
| RDS micro | `rds_instance_class = "db.t4g.micro"` (EKS가 빠져 연결 수가 줄어든 뒤. 2026-11-15 기준 EKS+v4 연결 약 80개) |
| nonprod 정리 | dev·stg ECS, dev EC2, dev Kafka, Qdrant, nonprod ALB |

정리 후 `alb-weight.sh`, `cutover-check.sh`는 대상 규칙·TG가 없어 쓰지 않는다.

## 4. 재구축 절차

D3 이후 다시 띄우면 V2 MSK·ElastiCache와 V2 prod 리스너 규칙이 없다. 아래 순서로 빈 부분을 채운다. 준비가 되어 있으면 2~3시간 걸린다.

| 순서 | 할 일 | 시간 |
|---|---|---|
| 1 | 백업한 `v3/eks/terraform.tfvars` 복원 → `terraform apply` (클러스터, 노드, MongoDB, NAT-c, TG) | 25~30분 |
| 2 | `aws eks update-kubeconfig --name moyeota-v3-eks` → `v3/helm/install-platform.sh` (congestion-logs 포함) | 10분 |
| 3 | Argo CD 알림 Secret 생성 (`v3/argocd/README.md` 공통 2번) | 수 분 |
| 4 | **브로커 준비:** (a) V2에서 `msk_stages`·`elasticache_redis_stages`에 prod를 넣고 해당 리소스만 `-target` apply(약 40분), 또는 (b) V3가 v4 데이터 호스트를 쓰도록 `/moyeota/v2/prod/broker/*` 값을 바꾸고 v4 데이터 호스트 SG에 V3 노드 SG 인바운드를 추가 | 수 분~40분 |
| 5 | **MongoDB 데이터:** 새 EBS는 비어 있다. v4 데이터 호스트에서 V3 replica set으로 역이관(`mongo-migrate.sh`의 원본·대상을 바꿔 실행)하거나, 3-1 스냅샷으로 볼륨을 만들어 교체 | 수 분~30분 |
| 6 | **TG ARN 갱신:** 새 TG ARN을 `v3/helm/app-values/prod/{rest-api,websocket,frontend}.yaml`의 `targetGroupBinding.targetGroupARN`에 넣고 main에 머지 (Argo CD는 main을 sync) | 수 분 |
| 7 | `kubectl apply -f v3/argocd/projects/prod.yaml -f v3/argocd/prod/` → Argo CD에서 수동 sync | 10분 |
| 8 | **트래픽 경로:** V2 prod 규칙(5·6·8)이 없으므로, v4 규칙의 대상을 EKS TG로 바꾸거나 EKS TG로 가는 규칙을 새로 만든다(헤더 조건으로 먼저 시험) | 수 분 |

- 시연·리허설만 할 때는 4번 (b), 5번 역이관, 8번 헤더 조건 규칙이 가장 빠르다.
- 재구축 후 비용은 하루 약 $25~50(노드, NAT-c, MongoDB 3대, 브로커 선택에 따라)이므로 끝나면 3장 절차로 다시 내린다.

## 5. 확인 목록

정리 후:

- [ ] `aws eks list-clusters`에 `moyeota-v3-eks` 없음
- [ ] EC2에 `moyeota-v3-*` 인스턴스 없음, 남은 EBS는 스냅샷 확인 후 삭제
- [ ] prod 리스너 규칙: v4 1·2·3과 옛 Compose 10·20, default만 남음 (V2 apply 후)
- [ ] v4 서비스·알람 정상, `moyeota-v4-prod-rds-connections` OK로 복귀

재구축 후:

- [ ] `terraform plan` 변경 0
- [ ] Argo CD prod 앱 Synced·Healthy
- [ ] 헤더 요청으로 EKS 응답 확인 후에만 트래픽 전환

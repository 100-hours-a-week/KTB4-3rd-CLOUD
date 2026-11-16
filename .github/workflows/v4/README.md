# v4 Prod CD 워크플로 (템플릿)

GitHub Actions는 `.github/workflows/` 바로 아래 파일만 실행하므로, 이 폴더의 파일은 **이 레포에서 실행되지 않는다.**
앱 레포의 `.github/workflows/`로 복사해서 쓴다. V2 prod CD(`../v2/v2-*-prod-cd.yaml`)를 바탕으로 대상만 v4로 바꿨다.

| 파일 | 복사 위치 | 트리거 | 배포 대상 (`moyeota-v4-prod`) |
|---|---|---|---|
| `be-prod-cd.yaml` | KTB4-3rd-BE `v4-be-prod-cd.yaml` | `workflow_run: BE CI` (main) | rest, websocket |
| `fe-prod-cd.yaml` | KTB4-3rd-FE `v4-fe-prod-cd.yaml` | `workflow_run: FE CI` (main) | frontend |
| `ai-prod-cd.yaml` | KTB4-3rd-AI `v4-ai-prod-cd.yaml` | `workflow_run: AI CI` (main) | fastapi |

배포 액션은 V2와 같은 `.github/actions/ecs-deploy/action.yml`이다. 앱 레포에 이미 사본이 있다.

## V2 prod CD와 다른 점

| 항목 | V2 | v4 |
|---|---|---|
| 클러스터 | `vars.ECS_CLUSTER` 또는 `moyeota-v2-prod` | `vars.V4_ECS_CLUSTER` 또는 `moyeota-v4-prod` |
| Deploy Role secret | `ECS_DEPLOY_ROLE_ARN` | `V4_ECS_DEPLOY_ROLE_ARN` (V2 값과 겹치지 않게 별도 이름) |
| release 이미지 | Stg CD가 남긴 `stg-vX.Y.Z-<sha>`만 | `stg-`가 있으면 그것, 없으면 release CI가 만든 `rc-vX.Y.Z-<sha>` |
| concurrency | `<app>-cd-prod` | `<app>-v4-cd-prod` |

- v4는 stg를 상시 운영하지 않으므로 release 이미지에 `stg-` 태그가 생기지 않는다. `rc-`를 승격할 때는 실행 요약에 경고가 남는다. production 승인 전에 변경 범위를 확인한다.
- hotfix 경로(`hf-`), `prod-` 태그 승격, 역병합 PR은 V2와 같다.
- BE의 rest는 `APP_ROLE=rest,worker,matching`이라 BE 배포 한 번에 worker·matching 역할도 함께 바뀐다.
- v4 서비스는 레플리카 1개라 배포마다 약 2~3분 중단된다(기존 태스크를 먼저 내린다).

## 앱 레포 설정

1. `production` environment에 secret `V4_ECS_DEPLOY_ROLE_ARN`을 넣는다. 값은 `v4/`의 `terraform output -raw deploy_role_arn`.
2. (선택) 클러스터 이름을 바꾸면 repository variable `V4_ECS_CLUSTER`를 넣는다.
3. 기존 `vars.AWS_REGION`, `vars.ECR_REGISTRY`, `vars.ECR_REPOSITORY`, `secrets.AWS_ROLE_TO_ASSUME`(resolve·promote용 CI Role)은 그대로 쓴다.

v4 Deploy Role 신뢰 정책은 BE·FE·AI 레포의 `environment:production`만 허용한다 (`v4/iam.tf`, 불변 sub 형식).

## 적용 시점 (설계 10절)

| 단계 | 앱 레포에서 할 일 |
|---|---|
| D1 구축 | 아직 추가하지 않는다. v4 첫 배포 이미지는 Terraform(`image_digests`)이 넣는다 |
| D2 전환 | v4 CD를 추가하고, 같은 PR에서 V3 prod CD(`v3-*-prod-cd.yaml`)를 지운다. 둘이 같이 있으면 main 머지마다 두 환경에 각각 승인 배포가 돈다 |
| D3 정리 | V2·V3의 dev·stg CD도 정리한다. 대상 클러스터가 사라져 실행하면 실패한다 |

## 롤백

v4 CD로 배포한 이미지를 되돌릴 때는 이전 `prod-` 태그의 digest로 같은 액션을 다시 돌리거나, ECS 콘솔에서 이전 Task Definition revision으로 서비스를 갱신한다.

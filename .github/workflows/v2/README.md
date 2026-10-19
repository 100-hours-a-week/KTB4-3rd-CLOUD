# V2 BE·FE·AI CI/CD 워크플로 (템플릿)

GitHub Actions는 `.github/workflows/` 바로 아래 파일만 실행하므로, 이 폴더의 파일은 **이 레포에서 실행되지 않는다.**
앱 레포(`KTB4-3rd-BE`, `KTB4-3rd-FE`, `KTB4-3rd-AI`)의 `.github/workflows/`로 복사해서 쓴다.

| 파일 | 복사 위치 | 트리거 |
|---|---|---|
| `v2-be-ci.yaml` | KTB4-3rd-BE `dev-be-ci.yaml` (워크플로 이름 `BE CI` 유지) | push (dev / main / release/** / hotfix/**)·PR |
| `v2-be-{dev,stg,prod}-cd.yaml` | KTB4-3rd-BE | `workflow_run: BE CI` (dev / release/** / main) |
| `v2-fe-dev-ci.yaml` | KTB4-3rd-FE `dev-fe-ci.yaml` (`FE CI` 유지) | push (develop / main / release/** / hotfix/**)·PR |
| `v2-fe-{dev,stg,prod}-cd.yaml` | KTB4-3rd-FE | `workflow_run: FE CI` |
| `v2-ai-ci.yaml` | KTB4-3rd-AI (`AI CI` 유지) | push (develop / main / release/** / hotfix/**)·PR |
| `v2-ai-{dev,stg,prod}-cd.yaml` | KTB4-3rd-AI | `workflow_run: AI CI` |
| `../../actions/ecs-deploy/action.yml` | KTB4-3rd-BE, KTB4-3rd-FE, KTB4-3rd-AI의 `.github/actions/ecs-deploy/action.yml` | CD가 로컬 action으로 사용 |

## 배포 액션

CD 워크플로는 **앱 레포 안에 복사한** composite action을 로컬 경로로 쓴다. CLOUD 레포를 원격 참조하지 않는다.

```yaml
- name: Checkout deploy action
  uses: actions/checkout@v4
  with:
    sparse-checkout: .github/actions
    persist-credentials: false

- name: Deploy to ECS
  uses: ./.github/actions/ecs-deploy
```

- 원본: [`.github/actions/ecs-deploy/action.yml`](../../actions/ecs-deploy/action.yml). 이 파일이 기준이고, 고치면 BE·FE 레포의 사본도 같이 맞춘다.
- 로컬 action은 checkout이 있어야 읽히므로 deploy job에 sparse checkout(`.github/actions`만)을 둔다.
- `workflow_run` job은 기본 브랜치(main) 커밋으로 checkout한다 → action 사본도 앱 레포 **main**에 있어야 한다.
- checkout은 작업 디렉터리를 비우므로, 그 뒤 step에서는 앞서 받은 `release-manifest/` 파일을 쓰지 않는다(값은 step output으로 넘긴다).

## 앱 레포 설정

- GitHub Environment `dev` / `staging` / `production`을 만들고, 각 environment에 `ECS_DEPLOY_ROLE_ARN` secret을 넣는다
  (값: `terraform output ecs_deploy_role_arns`의 해당 스테이지).
- Deploy Role 신뢰 정책은 `repo:100-hours-a-week/<앱 레포>:environment:<environment>`만 허용한다 (스테이지→environment 매핑은 `v2/variables.tf`의 `github_deploy_environments`)
  (`v2/variables.tf`의 `github_app_repositories`). job에 `environment:`가 없으면 AssumeRole이 거부된다.
- `vars.AWS_REGION`, `vars.ECR_REGISTRY`, `vars.ECR_REPOSITORY`, (선택) `vars.ECS_CLUSTER`

## hotfix 경로

Prod 긴급 수정은 `main`에서 만든 `hotfix/vX.Y.Z`로 Stg를 거치지 않고 Prod에 반영한다.

```
main ──▶ hotfix/vX.Y.Z ──push──▶ CI: hf-vX.Y.Z-<sha> 빌드·push
              └──PR(리뷰)──▶ main ──▶ Prod CD: hf- digest 확인 ─▶ production 승인 ─▶ 배포 ─▶ prod- 태그 ─▶ 역병합 PR
```

- **CI** (`branch-policy` job): main 대상 PR은 `release/vX.Y.Z`·`hotfix/vX.Y.Z`만 허용, hotfix에 통합 브랜치(dev/develop)에만 있는 커밋이 섞이면 실패, BE는 hotfix의 Flyway 마이그레이션(`src/main/resources/db/migration`) 변경을 막는다.
- **이미지**: hotfix 브랜치 push에서 한 번만 빌드한다. main 머지 후 재빌드하지 않고 Prod CD가 `hf-` digest를 승격한다.
- **Stg**: hotfix는 Stg에 배포하지 않는다. Stg가 release QA 중이면 rc 이미지를 덮어쓰기 때문이다.
- **역병합** (`backmerge` job): Prod 배포 후 main → dev/develop PR을 연다. hotfix면 남아 있는 `release/vX.Y.Z`에도 연다(끝난 release 브랜치는 삭제해 둔다).
  - 레포 설정 *Allow GitHub Actions to create and approve pull requests*가 필요하다. 꺼져 있으면 경고와 비교 링크만 남긴다.
  - GITHUB_TOKEN으로 만든 PR은 CI를 트리거하지 않는다. 필수 체크가 있으면 PR을 닫았다 다시 연다.
- **CI Role** 신뢰 정책에 각 앱 레포의 `ref:refs/heads/hotfix/*`가 있어야 hf- 이미지를 push할 수 있다(불변 sub 형식).
- **ECR**: `infra/ecr.tf` lifecycle rule 5가 Prod에 나가지 않은 `hf-` 이미지를 최근 10개만 남긴다.

## dev V1 병행 연결 (DNS 전환 전)

`dev.moyeota.com`이 아직 V1 dev EC2를 가리키는 동안에는 V1 `dev-cd.yaml`을 지우지 않고 V2 CD를 **추가**한다.

| 앱 레포 | 추가할 파일 | 그대로 두는 파일 |
|---|---|---|
| KTB4-3rd-BE | `v2-be-dev-cd.yaml` (BE V2 Dev CD), `.github/actions/ecs-deploy/action.yml` | `dev-cd.yaml`, `dev-be-ci.yaml` |
| KTB4-3rd-FE | `v2-fe-dev-cd.yaml` (FE V2 Dev CD), `.github/actions/ecs-deploy/action.yml` | `dev-cd.yaml`, `dev-fe-ci.yaml` |

- 두 CD가 같은 CI 실행의 `release-manifest`(dev-* digest)를 받아 V1 EC2와 V2 ECS에 각각 배포한다.
  워크플로 이름과 concurrency group(`*-v2-cd-dev`)이 V1과 달라 서로 기다리지 않는다.
- FE CI는 병행 기간 동안 V1(`dev-fe-ci.yaml`, GitHub vars 빌드)을 유지한다. 같은 이미지가 V1에도 나가므로
  SSM 빌드(`v2-fe-dev-ci.yaml`)로의 교체는 DNS 전환 때 함께 한다.
- 앱 레포 `dev` environment에 `ECS_DEPLOY_ROLE_ARN` secret 추가 (`terraform output ecs_deploy_role_arns` → dev).
- FE: Dev ECS `frontend` 서비스가 있어야 CD가 성공한다. `v2/terraform.tfvars`의 `ecs_container_images.dev.frontend`에
  최초 이미지(digest)를 넣고 apply한 뒤부터는 CD가 Task Definition을 갱신한다 (`ignore_changes = [task_definition]`).
- V2 확인은 DNS를 바꾸지 않고 `curl --resolve dev.moyeota.com:443:<Non-Prod ALB IP> https://dev.moyeota.com/...`로 한다.
- DNS 전환 시: `nonprod_dns_records`로 ALIAS 생성 → V1 `dev-cd.yaml` 삭제 → FE CI를 `v2-fe-dev-ci.yaml`로 교체.

## AI(FastAPI) 연결

BE·FE와 같은 흐름이다: `develop` → Dev, `release/vX.Y.Z` → Stg(검증 태그 `stg-*`), `main` → Prod(Stg digest 승격, 재빌드 없음).
ECS 서비스·컨테이너 이름은 `fastapi`, ECR은 `moyeota/ai`.

### CLOUD(Terraform)
- `v2/variables.tf` `github_app_repositories`에 `KTB4-3rd-AI` 추가 → apply 후 Deploy Role이 AI 레포 environment를 신뢰한다.
- `v2/ssm.tf` `ai` 그룹에 `OPENAI_API_KEY_1`(이미지용) 추가 → apply 후 값 입력:
  `aws ssm put-parameter --overwrite --type SecureString --name /moyeota/v2/dev/ai/OPENAI_API_KEY_1 --value '<key>'`
- 최초 1회: `v2/terraform.tfvars`의 `ecs_container_images.dev.fastapi`에 첫 이미지(digest)를 넣고 apply해 Dev `fastapi` 서비스를 만든다.
  이후 Task Definition은 CD가 갱신한다. (첫 digest는 AI CI가 develop에서 처음 push한 `dev-*` 태그로 확인)
- CI Role 신뢰 정책은 콘솔에서 관리되고 있어 V1 `infra/iam.tf` 코드와 다르다. 10/15 기준 AI는 `develop`만 있었으므로
  `release/*`·`main`·`hotfix/*` ref를 **추가만** 한다 (기존 항목 유지).

### AI 레포
- 복사: `.github/workflows/v2-ai-ci.yaml`(워크플로 이름 `AI CI` 유지), `v2-ai-{dev,stg,prod}-cd.yaml`,
  `.github/actions/ecs-deploy/action.yml`. CD가 쓰는 action 사본은 **main**에 있어야 한다.
- 필요 조건 (CI가 여기서 실패한다)
  - 루트 `Dockerfile` — 현재 `Dockerfile.example`만 있다. 검토 후 `Dockerfile`로 확정.
  - `GET /health` → 200 — ALB·ECS 헬스체크 경로(`fastapi_health_path`). 현재 `feat/congestion-analysis`에만 있다.
  - (모니터링) `GET /metrics` — Prometheus scrape·FastAPI 5xx 알림이 이 경로를 본다 (`prometheus-fastapi-instrumentator`).
- Environments `dev` / `staging` / `production` + 각 `ECS_DEPLOY_ROLE_ARN` secret
- Repository secret `AWS_ROLE_TO_ASSUME`(CI Role), vars `AWS_REGION`, `ECR_REGISTRY`, `ECR_REPOSITORY=moyeota/ai`

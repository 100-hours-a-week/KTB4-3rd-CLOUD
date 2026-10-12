# V2 BE·FE CI/CD 워크플로 (템플릿)

GitHub Actions는 `.github/workflows/` 바로 아래 파일만 실행하므로, 이 폴더의 파일은 **이 레포에서 실행되지 않는다.**
앱 레포(`KTB4-3rd-BE`, `KTB4-3rd-FE`)의 `.github/workflows/`로 복사해서 쓴다.

| 파일 | 복사 위치 | 트리거 |
|---|---|---|
| `v2-be-{dev,stg,prod}-cd.yaml` | KTB4-3rd-BE | `workflow_run: BE CI` (dev / release/** / main) |
| `v2-fe-dev-ci.yaml` | KTB4-3rd-FE | push·PR (develop / main / release/**) |
| `v2-fe-{dev,stg,prod}-cd.yaml` | KTB4-3rd-FE | `workflow_run: FE CI` |

## 배포 액션

CD 워크플로는 이 레포의 composite action을 직접 참조한다 (앱 레포에 복사하지 않는다).

```yaml
- name: Deploy to ECS
  uses: 100-hours-a-week/KTB4-3rd-CLOUD/.github/actions/ecs-deploy@main
```

- 이 레포가 public이어야 하고, 조직 Actions 정책이 같은 조직 레포의 action을 허용해야 한다.
- 액션 정의: [`.github/actions/ecs-deploy/action.yml`](../../actions/ecs-deploy/action.yml)

## 앱 레포 설정

- GitHub Environment `dev` / `stg` / `prod`를 만들고, 각 environment에 `ECS_DEPLOY_ROLE_ARN` secret을 넣는다
  (값: `terraform output ecs_deploy_role_arns`의 해당 스테이지).
- Deploy Role 신뢰 정책은 `repo:100-hours-a-week/<앱 레포>:environment:<stage>`만 허용한다
  (`v2/variables.tf`의 `github_app_repositories`). job에 `environment:`가 없으면 AssumeRole이 거부된다.
- `vars.AWS_REGION`, `vars.ECR_REGISTRY`, `vars.ECR_REPOSITORY`, (선택) `vars.ECS_CLUSTER`

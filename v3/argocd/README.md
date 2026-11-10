# V3 Argo CD 배포 구조

앱 저장소의 브랜치 정책은 V2와 같다. 달라지는 것은 CD의 마지막 단계뿐이다. ECS 서비스를 갱신하는 대신 CLOUD 저장소 `main`의 values에 digest를 커밋하고, Argo CD가 EKS에 반영한다.

| 앱 저장소 브랜치 | 이미지 | 스테이지 | 커밋 대상 | Sync |
| --- | --- | --- | --- | --- |
| BE `dev`, FE·AI `develop` | `dev-<sha>` | dev | `app-values/dev` | 자동 |
| `release/vX.Y.Z` | `rc-vX.Y.Z-<sha>` | stg | `app-values/stg` | 자동 |
| `main` (release에서 머지) | `stg-vX.Y.Z-<sha>` 승격 | prod | `app-values/prod` | 수동 |
| `main` (hotfix에서 머지) | `hf-vX.Y.Z-<sha>` 승격 | prod | `app-values/prod` | 수동 |

- **환경은 디렉터리로 나눈다:** CLOUD 저장소는 스테이지별 브랜치를 두지 않고 모든 Application이 `main`을 본다. 승격 기록이 digest 커밋으로 남는다.
- **재빌드 금지 유지:** CD는 CI의 digest만 커밋한다.
- **`stg-` 태그의 의미 유지:** Argo CD가 Healthy를 기록한 뒤에 태그를 남기므로, Prod CD가 받는 digest는 stg 배포가 끝난 digest다.
- **prod 게이트 2개:** GitHub `production` Environment 승인이 digest 커밋을 막고, Argo CD 수동 sync가 클러스터 반영을 막는다. 승인 게이트가 실제로 동작하려면 Environment에 required reviewers를 설정해야 한다.
- **hotfix는 stg를 건드리지 않는다:** release QA 중인 stg digest를 덮어쓰지 않는다.

## 배포 결과 전달

GitHub Actions는 클러스터에 접근하지 않는다. Argo CD Notifications가 CLOUD 커밋에 `argocd/<Application>` 상태를 기록하고, `gitops-deploy` action이 이 상태를 기다린다. prod는 수동 sync까지 포함해 240분을 기다리며, 시간이 지나면 job을 다시 실행한다.

## 활성화 순서

### 공통

1. GitHub App을 만들어 CLOUD 저장소에 설치한다. 권한은 Contents 쓰기, Commit statuses 쓰기다.
2. Secret을 만들고 `install-platform.sh`의 Argo CD 단계를 다시 적용한다.

   ```bash
   kubectl -n argocd create secret generic argocd-notifications-secret \
     --from-literal=github-appID=<앱 ID> \
     --from-literal=github-installationID=<설치 ID> \
     --from-file=github-privateKey=<개인 키 파일>
   ```

3. 이 디렉터리와 `v3/helm`을 `main`에 머지한다.
4. 앱 저장소 Environment `dev`, `staging`, `production`에 `GITOPS_APP_ID`, `GITOPS_APP_PRIVATE_KEY`를 넣는다.
5. `.github/actions/gitops-deploy`와 `.github/workflows/v3/v3-<app>-<stage>-cd.yaml`을 앱 저장소에 복사한다. action 사본은 앱 저장소 `main`에 있어야 한다.

### stg

`kubectl apply -f projects/stg.yaml -f stg/`로 적용한다. 적용 즉시 자동 sync가 시작된다. 인수 후에는 stg에서 `deploy-app.sh`를 쓰지 않고, Helm 릴리스 기록 Secret(`sh.helm.release.v1.<서비스>.*`)만 지운다. `helm uninstall`은 리소스까지 삭제한다.

stg worker와 matching은 Kafka 이미지 digest로 바꿀 때 함께 추가한다. ECS stg의 두 서비스를 0으로 줄이기 전에 적용하면 스케줄러가 중복 실행된다.

### prod

전환이 끝난 뒤 적용한다. 그 전까지는 `deploy-app.sh`로 배포한다.

- `app-values/prod`의 rest-api, websocket, frontend에 `targetGroupBinding.targetGroupARN`을 넣는다.
- sync 전에 `alb-weight.sh prod assert-attached`로 ALB 연결을 확인한다. `deploy-app.sh`의 이 검사는 Argo CD에서 실행되지 않는다.
- V3 prod CD는 ECS prod CD를 대체할 때 넣는다. 같이 두면 prod 태그와 역병합이 두 번 실행된다.

### dev

dev 파드는 `nodeStage: stg`로 non-prod 공용 노드에 올라간다. `kubectl apply -f projects/dev.yaml -f dev/`로 적용한다. worker와 matching은 ECS 서비스를 0으로 줄인 뒤에 적용한다.

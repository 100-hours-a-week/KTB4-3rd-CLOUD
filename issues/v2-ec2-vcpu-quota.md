# [Infra] EC2 On-Demand vCPU 한도(32) 대응 — 역할별 ASG를 공용 풀로 통합

## GitHub

- 이슈: (생성 후 채움)
- 구현 PR: [#124](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/pull/124)
- 브랜치: `feat/v2-ecs-shared-pool`

## 문제

stg·prod ECS 용량을 역할별 EC2 Auto Scaling Group(rest-od / rest-spot / ws-od)으로 나눠 구성했더니, 리전의 EC2 On-Demand vCPU 한도 32를 쉽게 넘었다. 역할별 ASG는 각자 최소 용량을 확보하므로 동시에 떠 있는 On-Demand 인스턴스 수가 늘어난다.

2026-10-23 instance refresh를 진행하며 ws-od ASG에서 `Terminating:Wait` 상태의 인스턴스가 오래 남는 것을 관찰했다. 당시 상태 조회 기록은 `v2/1023-terraform-vcpu32-overflow.log`에 있다(로컬 보관, 저장소에는 올리지 않음).

## 대응

- 역할별 ASG를 `general-od`(t3.medium On-Demand baseline) + `shared-spot` 공용 풀로 통합
- prod: `general-od` 3/4, `shared-spot` 0/4
- stg: `general-od` 0/4, `shared-spot` 0/2
- REST·frontend·FastAPI는 baseline 뒤 OD:Spot weight 1:4, WebSocket은 On-Demand 전용
- FIS Spot 중단 실험 대상을 shared Spot 인스턴스로 변경
- 근거 코드: `v2/locals.tf` (ECS 서비스 설정 주석), `v2/modules/ecs/README.md`

## 완료 기준

- [x] 역할별 ASG를 공용 풀 구성으로 코드 변경
- [x] stg QA 스케줄 locals의 conditional 타입 불일치로 plan이 실패하던 문제 수정
- [ ] prod plan 검토 및 적용 후 On-Demand vCPU 사용량이 한도 아래인지 확인
- [ ] 적용 후에도 한도가 부족하면 quota 상향 요청 여부 결정

## 참고

- 관련 커밋: `afbe888` (`[infra] V2 stg·prod ECS를 공용 On-Demand baseline·공용 Spot 풀로 전환`)
- V2 Prod RDS 인프라: `issues/v2-prod-rds.md`

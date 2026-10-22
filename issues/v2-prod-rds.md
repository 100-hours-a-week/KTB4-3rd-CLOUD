# [Infra] V2 Prod RDS 인프라 추가

## GitHub

- 이슈: [#115](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/115)
- 구현 PR: [#118](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/pull/118)
- 브랜치: `feat/v2-prod-rds`

## 목적

V2 prod ECS 서비스가 사용할 MySQL을 관리형 RDS로 구성하고, 운영 DB 이관 중 필요한 네트워크 경로를 제한적으로 제공한다.

## 구성

- MySQL 8.4 Single-AZ 인스턴스와 데이터 서브넷 그룹
- KST 시간대·utf8mb4 설정을 포함한 파라미터 그룹
- RDS master 암호의 Secrets Manager 관리, 스토리지 암호화, 자동 백업/PITR, 삭제 보호 및 `prevent_destroy`
- prod rest/websocket 태스크 SG 접근과 명시적으로 설정하는 이관 기간용 SG 규칙
- 암호 값을 노출하지 않는 Terraform 출력

## 완료 기준

- [x] 기본값에서는 RDS를 생성하지 않는다.
- [x] prod RDS와 이관 연결 규칙을 Terraform 코드로 관리한다.
- [ ] 운영 plan 검토, 적용 및 이관 종료 후 임시 SG 규칙 정리

## 참고

- V2 DB 인프라 설계
- V2 DB 무중단 마이그레이션 설계

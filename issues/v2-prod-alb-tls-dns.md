# [Infra] V2 Prod ALB TLS·DNS 구성

## GitHub

- 이슈: [#116](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/116)
- 구현 PR: [#120](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/pull/120)
- 브랜치: `feat/v2-prod-alb-tls-dns`

## 목적

Prod ALB에 HTTPS를 제공하고 운영 도메인의 인증서와 DNS를 관리하되, V1에서 서비스 중인 운영 DNS는 명시적 컷오버 전까지 건드리지 않는다.

## 구성

- `prod_hosts`의 ACM 인증서를 Route 53 DNS 방식으로 검증
- 기존 `alb_certificate_arn`을 지정하면 해당 인증서를 우선 사용
- TLS 활성화 시 HTTP(80)에서 HTTPS(443)로 리다이렉트
- `prod_dns_records`에 명시된 호스트에만 ALB alias A 레코드 생성
- 기본값은 빈 DNS 목록으로 두고 컷오버 시점을 별도 관리

## 완료 기준

- [x] 인증서·리스너·선택적 DNS alias를 Terraform으로 구성한다.
- [x] 기본값에서 기존 운영 DNS 레코드를 만들거나 교체하지 않는다.
- [ ] 운영 DNS 컷오버 및 실제 HTTPS 요청 확인

## 참고

- 운영 도메인: `moyeota.com`
- V2 ECS 기반 전체 아키텍처 설계

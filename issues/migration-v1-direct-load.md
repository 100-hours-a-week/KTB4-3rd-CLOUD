# V1 운영 API 직접 대상 이관 부하 시나리오

GitHub issue: https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/113

## 배경

DB 컷오버 동안 V1 backend는 유지되고 DB writer만 ProxySQL 뒤에서 V1 MySQL에서 RDS로 바뀐다. 이 구간의 애플리케이션 부하를 V1 운영 API origin으로 고정해 보내는 k6 시나리오가 필요하다. V2 ALB로 요청을 분배하거나 DNS 전환을 모사하면 V1 API → ProxySQL 경로의 컷오버 영향을 분리해 볼 수 없다.

## 제안

- `migration-v1-direct.js`는 V1 REST API와 `/api/wss`에만 요청한다.
- 조회, 커뮤니티 글·댓글 쓰기, STOMP 채팅 부하와 쓰기 원장을 제공한다.
- target host 확인 및 운영 실행 확인을 요구한다. 운영 데이터 변경은 별도 명시 승인과 전용 테스트 계정·fixture가 모두 있어야 한다.
- 테스트 목적지 URL은 V1 EC2 직접 origin으로 지정한다. ALB, V2 URL, DNS 가중치 전환은 이 스크립트의 책임이 아니다.

## 환경 구분

- `v1-sim`은 stg에서 합성 데이터로 ProxySQL, 복제, 컷오버, 롤백을 반복 검증하는 대역 환경이다.
- 운영 API 직접 부하는 V1 Prod backend가 ProxySQL을 사용하는 실제 컷오버 구간의 부하 확인용이다.
- 두 환경은 서로 대체하지 않는다. `v1-sim`은 운영 API 요청을 받지 않는다.

## 완료 기준

- k6 REST·WebSocket 요청이 하나의 지정된 V1 origin만 사용한다.
- 코드에 V2 API URL, ALB routing 또는 DNS traffic share가 없다.
- 쓰기·채팅 부하에는 명시적인 운영 변경 확인이 필요하다.
- 실행 파라미터, 준비할 계정·fixture, v1-sim과의 구분을 문서화한다.

## 확인 항목

- 운영용 전용 계정과 fixture는 별도 절차로 준비하고, 일반 사용자 계정·데이터는 쓰지 않는다.
- V1 origin 주소와 해당 경로의 네트워크 접근성을 실행 환경에서 확인한다.
- 이 스크립트는 ProxySQL 컷오버 명령을 실행하지 않으며, 부하 실행 자체도 이 변경에는 포함하지 않는다.

# [Infra] Prod Redis 노드 타입 분리

## GitHub

- 이슈: [#117](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/117)
- 구현 PR: [#119](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/pull/119)
- 브랜치: `feat/v2-prod-redis-capacity`

## 목적

Prod Redis는 WebSocket 태스크들에 채팅 Pub/Sub 메시지를 fan-out한다. 구독 태스크 수에 따라 송신량도 늘어나므로, prod 용량을 stg와 독립적으로 설정한다.

## 구성

- stg는 `redis_node_type`, prod는 `redis_prod_node_type` 사용
- prod primary와 replica에 `cache.t4g.small`을 기본값으로 설정
- prod 변경은 즉시 적용하지 않고 유지 관리 시간에 반영

## 완료 기준

- [x] 환경별 노드 타입 변수를 분리한다.
- [x] prod 기본 용량과 적용 시점을 코드에 기록한다.
- [ ] 운영 반영 후 노드별 CPU·메모리·네트워크 지표 확인

## 참고

- V2 WebSocket 메시지 버스와 Redis 도입 설계

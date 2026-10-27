# [Test] 대규모 Flooding 부하테스트 시나리오 설계와 실행 런북

## GitHub

- 이슈: [#127](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/127)
- 관련 이슈: [#125](https://github.com/100-hours-a-week/KTB4-3rd-CLOUD/issues/125) (스케줄러 부하테스트 SC-3 재수집 실패)
- 설계 문서: `v2/FLOODING_SCENARIO.md`
- 실행 런북: `v2/FLOODING_RUNBOOK.md`
- 기존 실행 절차: `loadtest-scenarios/real/README.md`

## 목적

행사·날씨 등으로 조회 트래픽이 급증할 때 V2 서비스(REST, WebSocket, DB)가 어느 RPS에서 SLO를 벗어나는지 찾고, 그 시점의 병목과 복구 과정을 기록한다.

## 현재 상태

- 트래픽 가정: 평시 피크 91 RPS 기준, 벤치마크 배수로 171 / 259 / 377 / 512 RPS 단계 설계
- 실행 절차: 승인 → 사전 조건 확인 → dry-run → 계정·fixture 생성 → 1 VU 스모크 → 기준선 → 본 실행 → 정리 → 분석 순서로 정리 (런북 1장)
- 분석 단계(임계점 판정, Failback 계산, 리포트, 리소스 수집기)는 아직 없음

## 결정 필요

- 축소 실행(스모크) 옵션을 추가할지
- 중단 기준을 k6 `abortOnFail`로 자동화할지, 분석 후 판정할지
- WebSocket 목표 1,800 연결과 계산값(512 RPS에서 약 980 연결) 중 어느 것을 기준으로 쓸지
- 행사 종료 후 60분 관찰을 자동 단계로 넣을지
- 행사 구역 비중 `f`를 얼마로 둘지 (전체 피크 = 91 × (1 + f × (배수 − 1)))

## 완료 기준

- [x] 설계 문서 작성
- [x] 실행 런북 작성
- [ ] dry-run으로 설계 수치 검증
- [ ] 1 VU 스모크 통과
- [ ] 기준선(91 RPS) 측정
- [ ] Flooding 본 실행 및 결과 기록
- [ ] 분석·리포트 작성

## 주의

- 대상은 stg 전용. 운영 DB의 `JWT_SECRET`으로는 어떤 단계도 실행하지 않는다.
- 설계 수치(배수, 확률, 시간)는 초기 가정이며 실측 또는 운영 로그가 생기면 교체한다.

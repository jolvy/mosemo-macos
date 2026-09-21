# Collector Spike Result

## 실행 환경

- 날짜:
- Git commit 또는 worktree HEAD:
- Mac model / chip:
- macOS:
- Xcode:
- Google Chrome:
- bundle ID: `io.mosemo.collector.spike`
- 손쉬운 사용: 허용 / 거부
- Chrome 자동화: 허용 / 거부
- 화면 기록 권한 요청 횟수: 0 / 기타

## 자동 검증

- Xcode build: 통과 / 실패 / 미실행
- XCTest 개수와 실패 수:
- CollectorCore line coverage:
- condition coverage 도구/결과:
- `scripts/check_collector_privacy.sh`: 통과 / 실패 / 미실행
- 실제 진단 snapshot 검사: 통과 / 실패 / 미실행
- Xcode console/process output 검사: 통과 / 실패 / 미실행

## 100회 전환

- 상세 CSV 경로:
- expected:
- matched:
- missed:
- p95 latency ms:
- 앱 전환:
- Chrome 탭:
- 같은 탭 navigation:
- SPA:
- 다중 창:
- 전체 화면:
- Chrome 재시작:
- YouTube watch → shorts:
- 일반 앱/창 복귀:
- Chrome 탭 복귀:

## 세션·보호 경계

- 세션 전 activity event 증가:
- 의도된 휴식 중 activity event 증가:
- 세션 종료 후 activity event 증가:
- 시크릿에서 domain/title/URL 노출 사례:
- 화면 기록 권한 요청 사례:

## 8시간 실행

- 시작/종료:
- 치명적 중단:
- sample 수:
- 평균 CPU %:
- 최대 RSS MB:
- 감지 지연 p95 ms:
- 전환 누락:
- Chrome restart recovery:

## 수용 기준

| 기준 | 결과 | 근거 |
| --- | --- | --- |
| 8시간 치명적 중단 0 | 미측정 | |
| 평균 CPU 3% 이하 | 미측정 | |
| 메모리 200MB 이하 | 미측정 | |
| 감지 지연 p95 2초 이하 | 미측정 | |
| 100회 중 누락 1회 이하 | 미측정 | |
| 금지 데이터 0 | 미측정 | |
| 세션 밖·휴식 중 이벤트 0 | 미측정 | |
| Chrome 내부 요구 흐름 감지 | 미측정 | |
| 복귀 시도·결과 확인 | 미측정 | |
| 화면 기록 권한 요청 0 | 미측정 | |

## 판정

- Go / Conditional Go / No-Go:
- 통과 근거:
- 남은 조건:
- 실패 시 바꿀 수집 방식 또는 제품 범위:

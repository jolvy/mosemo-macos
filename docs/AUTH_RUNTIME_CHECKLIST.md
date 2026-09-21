# Kakao 로그인 수동 runtime 검증

실제 Kakao 계정과 실행 중인 Mosemo 서버가 필요한 검증은 자동 테스트와 분리한다.
2026-09-04 구현 시점에는 아래 항목을 실행하지 않았으며 모두 `미실행`이다.

## 사전 조건

- 서버가 macOS callback `io.mosemo.app:/auth/callback`을 허용한다.
- Debug 서버는 `http://localhost:8000`, Release 서버는
  `MOSEMO_API_BASE_URL` build setting으로 주입한다.
- 앱의 bundle ID와 URL scheme이 각각 `io.mosemo.app`으로 빌드됐는지 확인한다.
- Xcode console과 macOS unified log를 열어 인증 비밀 노출 여부를 함께 확인한다.

## 검증 항목

| 항목 | 기대 결과 | 상태 |
| --- | --- | --- |
| 최초 로그인 | 시스템 브라우저 인증 뒤 계정 UUID가 메뉴에 표시됨 | 미실행 |
| 로그인 취소 | 계정이 생기지 않고 취소 상태가 표시됨 | 미실행 |
| 동시 로그인 | 첫 세션을 유지하고 두 번째 요청을 거절함 | 미실행 |
| 앱 재실행 | Debug는 SQLite, Release는 Keychain의 유효한 token으로 현재 계정을 복원함 | 미실행 |
| 만료 token | 현재 저장소를 비우고 로그인이 필요하다고 표시함 | 미실행 |
| 서버 401 | 현재 저장소를 비우고 로그인이 필요하다고 표시함 | 미실행 |
| 로그아웃 | 현재 저장소의 token을 삭제하고 로그인 화면으로 돌아감 | 미실행 |
| 비밀 로그 검사 | access token, callback code, PKCE verifier가 출력되지 않음 | 미실행 |

실행 후 상태를 `통과` 또는 `실패`로 바꾸고, 실패한 항목에는 재현 환경과 민감하지
않은 오류 범주만 기록한다. token, callback query, verifier 원문은 기록하지 않는다.

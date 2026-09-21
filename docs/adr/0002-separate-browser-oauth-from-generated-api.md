---
status: accepted
---

# 브라우저 OAuth와 generated API 호출을 분리한다

Kakao login/callback은 `AuthCoordinator`와 `ASWebAuthenticationSession`이,
token 교환과 Bearer API는 `MosemoAPI`의 generated client가 담당한다. 브라우저
redirect와 system cookie 생명주기는 일반 JSON API 호출과 다르고, PKCE verifier와
일회용 callback code를 앱 상태에서 명시적으로 관리해야 하기 때문이다.

## Considered Options

- login/callback까지 generated client로 호출: redirect와 browser session을 API
  transport 책임으로 잘못 섞게 된다.
- embedded web view: 시스템 인증 session의 callback·credential 처리 이점을 잃는다.
- system browser session과 API client 분리: 각 경계가 소유하는 상태가 명확해
  선택했다.

## Consequences

- callback은 `io.mosemo.app:/auth/callback`의 scheme, 빈 host와 path를 정확히
  검증한다.
- PKCE verifier는 로그인 처리 중 메모리에만 두고 동시 로그인은 한 개로 제한한다.
- raw token은 Release에서 Keychain에 저장한다. Debug 개발 빌드는 배포 전환을
  전제로 앱 전용 SQLite adapter를 임시 사용하며, public API는 인증 완료된
  `Account`를 반환한다.
- refresh token이 없는 동안 만료나 401은 자동 재시도하지 않고 재로그인을 요구한다.

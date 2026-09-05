---
status: accepted
---

# OpenAPI 생성 코드를 MosemoAPI 내부에 둔다

OpenAPI 생성 코드와 손으로 작성한 wrapper를 하나의 `MosemoAPI` Swift 모듈에
둔다. 생성 타입을 `internal`로 유지하면서 앱에는 안정적인 `MosemoAPIClient`,
앱 모델·오류와 인증 흐름에 필요한 API만 공개하기 위해서다. 별도 `MosemoGeneratedAPI`
모듈을 만들면 생성 타입을 다른 모듈의 wrapper가 사용하기 위해 공개해야 하므로
현재 캡슐화 목표와 맞지 않는다.

## Considered Options

- 별도 generated module: 의존성은 선명하지만 생성 타입을 module 밖에 공개해야 한다.
- 생성 타입을 앱에서 직접 사용: 코드가 적지만 서버 schema 변경이 UI와 수집
  도메인까지 전파된다.
- 같은 module의 handwritten wrapper: public 경계를 작게 유지하고 변경을 변환
  계층에서 흡수할 수 있어 선택했다.

## Consequences

- `CollectorCore`와 SwiftUI는 `Components.Schemas.*`를 사용할 수 없다.
- generated `APIProtocol` fake를 사용하는 테스트도 `MosemoAPI`의 `@testable`
  경계에서 작성한다.
- Xcode build plugin 검증이 실제 build에서 실패했으므로 command plugin으로
  미리 생성한 source를 커밋하고 CI에서 재생성 diff를 검사한다.

# 활동 인식 장애 원인과 재발 방지

작성일: 2026-10-07. 대상: macOS client, bundle ID `io.mosemo.app`.
변경 전 기준: `5654f35642297f80b5386226760fee9f9a420ec1`.
수정 브랜치: `fix/activity-window-capture`.
서버나 OpenAPI 계약은 변경하지 않았다.

## 증상과 확인 범위

앱 이름이 수집 불가로 표시됐고 Firefox 웹 활동이 기록되지 않았다. System Events
자동화 권한을 초기화하고 앱을 다시 빌드해도 Firefox 관찰 실패가 남았다.
이후 직접 Accessibility 관찰을 도입한 설치본에서는 손쉬운 사용 설정의 Mosemo
토글이 켜졌는데 앱 진단이 `앱 접근성: 거부됨`으로 표시되는 현상이 있었다.
사용자가 토글을 껐다가 다시 켠 후 진단은 `허용됨`으로 바뀌었다. Chrome 자동화도
`허용됨`이었으며 Firefox·Chrome의 `browserPage / observed`, 카카오톡의
`application / observed` 이벤트와 새 타임라인 구간을 확인했다.

이 런타임 확인은 리뷰 후 수정본 `17b8287`을 다시 설치하기 **전**의 결과다.
수정본의 자동 테스트·빌드 통과가 실제 macOS 권한이나 Firefox UI 호환성을
보장하지는 않는다. 제목과 전체 URL, 계정·토큰은 장애 문서에 기록하지 않는다.

## 확인된 원인

| 원인 | 코드 및 실행 근거 | 결과와 수정 |
| --- | --- | --- |
| 앱 이름이 저장 경로에서 빠짐 | 변경 전 `OfflineActivityCoordinator.record`는 bundle ID가 있어도 app name을 `.absent`로 구성 | 실행 앱 표시 이름 또는 bundle 표시 이름을 읽어 저장 |
| 일반 앱 창 정보가 수집·저장되지 않음 | 일반 앱 관찰에 창 읽기가 없고 `DetailedActivityContext.window`가 `.absent`로 고정 | 포커스 창을 AX API로 읽고 `captured / absent / unavailable`을 저장 |
| Firefox 읽기가 특정 UI 계층에 고정됨 | 변경 전 `SystemEventsClient`의 주소 경로가 `combo box 1 of group 2 of group 1 of toolbar 1 of group 1`이고, 실패를 빈 주소로 삼킴. 권한 초기화 뒤에도 Firefox context 실패가 남음 | 역할·주소 레이블 기반 AX 탐색으로 변경하고 권한 거부와 맥락 읽기 실패를 구분 |
| 주소 분류 실패가 활동 전체 누락으로 이어짐 | `SurfaceClassifier`는 HTTP(S) scheme이 없으면 unavailable로 분류하고, coordinator는 unavailable 일반 관찰을 저장하지 않음 | Firefox에서 URL을 해석하지 못해도 읽은 활동을 observed로 유지. 원문 주소에 scheme을 만들어 붙이지 않음 |
| 진단 권한 표시가 오래된 상태로 남을 수 있음 | 시작 시 또는 AX 읽기 결과에서만 상태를 갱신. Chrome 사용·추적 비활성 중에는 사용자가 설정을 바꿔도 갱신되지 않을 수 있음 | 관찰 poll에서 추적 허용 여부와 독립적으로 실제 `AXIsProcessTrusted()` 상태를 다시 확인 |
| 회귀 테스트가 CI에서 실행되지 않음 | 기존 workflow는 개인정보 검사·Debug build·Release archive만 실행 | `swift test`를 CI 단계로 추가 |

권한 목록의 구버전 Mosemo·CatchHabitCollector 항목이나 ad-hoc 서명이 실제 TCC
불일치를 만들었는지는 확정하지 못했다. 설정 토글과 실행 프로세스의 허용 상태가
달랐다는 관찰만 확인됐다. 구버전 앱이 유일한 원인이었다고 결론 내리지 않는다.
또한 로그인 시 localhost 서버가 다른 서비스였던 문제는 별도 장애이며,
Firefox UI 읽기 실패의 원인으로 취급하지 않는다.

## 리뷰에서 찾아 함께 막은 재발 경로

- 포커스 창이 없을 때 `AXWindows.first`로 다른 창을 대신 기록하지 않는다.
  일반 앱은 창 absent인 유효한 앱 활동을 유지한다.
- 포커스 창 조회의 AX 결과를 보존한다. `noValue`만 창 absent로 처리하고,
  `cannotComplete`, `attributeUnsupported` 등은 AX 오류 코드가 포함된 unavailable로
  기록한다. 성공 응답에 값이 없거나 AX element가 아니어도 unavailable로 처리한다.
- 이전 AX 읽기가 끝나기 전에 다른 앱이 활성화돼도 최신 `appSwitch`를 유지한다.
  늦게 도착한 이전 앱의 결과는 버린다.
- Firefox 도구막대 밖의 검색 필드와 `AXWebArea` 내부 입력은 읽지 않는다.
  주소창이 포커스됐거나 포커스 여부를 확인할 수 없으면 주소 값을 읽지 않는다.
- 주소·창 제목·앱 정보는 독립적으로 취급한다. Firefox 제목을 읽지 못하거나
  비어 있으면 비공개 여부를 확인할 수 없으므로 opaque 활동만 저장한다.
- 비공개 활동은 URL·제목·앱 상세 맥락을 대기열에 저장하지 않는다.

## 자동 회귀 검증

다음 명령은 설치된 앱이나 실제 TCC 설정을 변경하지 않는다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

CI의 `Swift regression tests` 단계에서 같은 명령을 실행한다.

| 회귀 테스트 | 잡는 문제 |
| --- | --- |
| `testApplicationWindowTitleIsPersistedForGenericAppObservation` | 카카오톡 같은 앱의 창 제목이 저장 경로에서 누락됨 |
| `testLateApplicationReadPreservesLatestAppSwitch` | 이전 창 읽기로 새 앱 전환을 잃음 |
| `testFirefoxFailureRecoveryAndLateResultAfterAppSwitch` | Firefox 실패 후 회복하지 않거나 늦은 결과를 다른 앱에 적용 |
| `testFirefoxSchemeLessAddressRemainsObservedWithoutRewriting` | 주소 scheme을 임의 추가하거나 분류 실패로 관찰 누락 |
| `testFirefoxSchemeLessAddressReachesPersistence` | 실제 암호화 대기열에 scheme 없는 주소를 저장하지 못함 |
| `testFirefoxUnknownPrivateStateSuppressesDetailedContext` | 제목이 없어 보호 여부를 판단할 수 없는데 URL을 저장 |
| `testProtectedActivityPersistsOnlyOpaqueContext` | 보호 활동의 상세 맥락 저장 |
| `testAccessibilityStatusRefreshesWhileTrackingIsDisabled` | 설정 변경 후 권한 표시가 갱신되지 않음 |
| `testFocusedWindowAXErrorsAreNotReportedAsAbsent` | 응답 불가·미지원 등 AX 오류를 창 없음으로 오인 |
| `testFocusedWindowNoValueIsAbsentButMalformedSuccessIsUnavailable` | 실제 창 부재와 비정상 응답을 혼동 |

마지막 권한 테스트는 수정 전 `denied != granted`로 실패하는 것을 확인했다.
OS의 AX 트리 탐색과 TCC 허용 자체는 이 테스트의 검증 범위가 아니다.
2026-10-07 로컬 `swift test` 결과는 215개 실행, 1개 skipped, 실패 0개다.
CI workflow는 수정했지만 원격 CI 실행 결과는 아직 확인하지 않았다.

## 설치·배포 때 수행할 실제 앱 검증

1. 실행 앱의 절대 경로와 bundle ID·서명을 확인한다. 동일 bundle ID의 여러 빌드가
   있으면 이름만으로 실행하지 말고 `/Applications/Mosemo.app` 설치본을 명시한다.
2. Debug API 주소와 해당 포트를 점유한 서버를 확인한다. 로그인 성공을
   수집 권한이나 업로드 성공의 증거로 삼지 않는다.
3. 진단에서 Firefox·일반 앱은 `앱 접근성: 허용됨`, Chrome은
   `Chrome 자동화: 허용됨`을 확인한다. 두 권한은 서로 대체하지 않는다.
4. Firefox·Chrome·카카오톡을 각각 전면화하고 관찰 간격인 5초 이상 기다린다.
   각 앱의 새 observed 이벤트, 동기화 완료, 새 타임라인 구간의 창/웹 정보 수집
   상태를 확인한다. 예전 구간이 있거나 앱 전환 이벤트만 생겼다고 통과시키지 않는다.
5. Firefox 주소창에 입력만 하고 이동하지 않은 경우 입력을 URL로 저장하지 않는지,
   창을 최소화한 경우 다른 창 제목을 대신 기록하지 않는지 확인한다.
6. 일반·비공개 창, 권한 끄기/켜기, 빠른 앱 전환, Firefox 버전·언어 변경을 확인한다.
   비공개 검증에는 실제 비밀이나 개인 페이지를 사용하지 않는다.
7. 설정은 켜졌는데 진단이 거부라면 실행 경로부터 다시 확인한다. 필요한 경우
   사용자가 해당 설치본의 토글을 껐다 켜고 앱을 재실행한 뒤 진단을 재확인한다.
   전체 앱의 권한을 일괄 초기화하지 않는다. 기존 데이터나 unrelated 앱을 삭제하지 않는다.

수동 검증이 실패하면 안전 진단의 권한 상태·bundle ID·관찰 상태·실패 코드와
macOS/Firefox 버전만 기록한다. 제목·전체 URL이나 인증 비밀을 첨부하지 않는다.
실제 AX UI 호환성, macOS TCC 재허용, 다른 언어의 비공개 표식은 수동 검증 항목이다.

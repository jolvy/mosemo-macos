# macOS Collector Feasibility Spike

이 디렉터리는 네이티브 수집 방식의 가능성을 검증하는 macOS 앱과 서버 인증
경계를 함께 담는다. 앱은 고정 bundle ID `io.mosemo.app`을 사용한다.
`CollectorCore`는 네트워크를 모르며, 수집 데이터는 SQLite·파일·서버·영속
로그에 기록하지 않고 최근 600개의 안전 이벤트와 테스트용 브라우저 원시
맥락만 메모리 ring buffer에 둔다. 서버 통신은 `MosemoAPI`의 로그인과 현재
계정 조회와 Device 등록으로 제한된다.

현재 빌드는 feasibility 확인을 위해 일반 Chrome·Firefox의 활성 탭 제목과 전체
URL을 진단 화면에 표시하는 임시 테스트 모드다. 이 두 값은 안전 이벤트와
`안전 진단 복사` 결과에는 들어가지 않고, 파일·console·서버로도 보내지 않는다.
앱을 종료하거나 새 집중 세션을 시작하면 메모리에서 사라진다. 제품 개인정보
경계에는 포함할 수 없는 개발 진단 예외다.

## 설계 문서

- [macOS 활동 라벨 검토와 집계 PRD](PRD_MACOS_ACTIVITY_LABELING.md): 제안 표시,
  사용자 확정, 라벨 타임라인과 대시보드의 앱 동작
- [macOS OpenAPI·인증 아키텍처](OPENAPI_AUTH_ARCHITECTURE.md): 모듈 경계,
  생성 코드 관리, Kakao 로그인, Keychain, 오류·Privacy·CI 정책
- [ADR-0001: OpenAPI 생성 코드를 MosemoAPI 내부에 둔다](adr/0001-keep-generated-openapi-inside-mosemo-api.md)
- [ADR-0002: 브라우저 OAuth와 generated API 호출을 분리한다](adr/0002-separate-browser-oauth-from-generated-api.md)
- [Kakao 로그인 수동 runtime 검증](AUTH_RUNTIME_CHECKLIST.md)

## 구현 경계

- `NSWorkspace` 알림으로 전면 앱 전환을 받는다.
- Google Chrome이 전면이고 집중 관찰이 활성일 때만 0.5초 간격으로 Chrome
  Apple Events를 호출한다.
- 일반 Chrome 창에서는 창 ID, 탭 ID, URL, 제목을 읽는다. URL은 등록 도메인과
  surface type 및 변화 fingerprint를 만들며, 원시 URL과 제목은 테스트 진단용
  ring buffer 항목에만 함께 보관한다.
- 시크릿 창은 `mode`를 먼저 확인하고 URL·제목을 요청하는 Apple Event 분기로
  들어가지 않는다.
- Firefox가 전면이면 System Events UI scripting으로 Accessibility tree의 활성
  web area 또는 주소 표시줄에서 제목·URL을 0.5초 간격으로 읽는다. Firefox는 Chrome과 같은 탭 ID API를
  제공하지 않으므로 `firefoxPageChange`는 탭 전환과 같은 탭 이동을 구분하지
  않는다. Firefox UI 구조가 바뀌거나 값을 노출하지 않으면 추측하지 않고
  `firefox_page_context` 관찰 불가로 기록한다.
- 일반 앱 복귀는 PID로 앱을 활성화하고, Chrome 복귀는 창·탭 ID를 사용한다.
  현재 화면이나 탭을 닫지 않는다.
- 화면 잠금, 사용자 세션 비활성, sleep 중에는 자동 일시정지한다. 명시적
  휴식과 세션 종료 중에도 collector를 중지한다.

등록 도메인은 외부 Public Suffix List 없이 보수적인 마지막 2개 label과 자주
쓰는 compound suffix 목록으로 계산한다. 낯선 public suffix는 도메인을 덜
구체적으로 만들 수 있으나 subdomain을 그대로 노출하지 않는다.

## 구현 파일과 책임

| 경로 | 책임 |
| --- | --- |
| `Package.swift` | CollectorCore, MosemoAPI, 실행 앱과 XCTest를 로컬 Swift Package로 연결 |
| `Package.resolved` | OpenAPI generator와 runtime 의존성 버전 고정 |
| `Mosemo.xcodeproj/` | Swift package product를 사용하는 macOS 앱 target과 공유 scheme 정의 |
| `Info.plist` | bundle ID, 인증 callback scheme, Apple Events 사용 목적 선언 |
| `Sources/CollectorCore/SessionStateMachine.swift` | 집중 시작·휴식·재개·종료와 수집 허용 상태 |
| `Sources/CollectorCore/SafeActivityEvent.swift` | 안전 이벤트 allow-list와 보호 맥락 필드 제거 |
| `Sources/CollectorCore/SurfaceClassifier.swift` | 등록 도메인·Chrome surface·브라우저 transition 분류 |
| `Sources/CollectorCore/ReturnTracking.swift` | 복귀 시도와 성공·실패 결과 모델링 |
| `Sources/CollectorCore/DetectionStatistics.swift` | ring buffer와 지연·누락 통계 |
| `Sources/MosemoApp/MosemoApp.swift` | 기본 창, 메뉴 막대 UI와 진단 창 구성 |
| `Sources/MosemoApp/DesktopRootView.swift` | 로그인, 권한 온보딩과 홈 화면 전환 |
| `Sources/MosemoApp/CollectorViewModel.swift` | 세션, 관찰 adapter, ring buffer, 진단 상태 조정 |
| `Sources/MosemoApp/WorkspaceObserver.swift` | 전면 앱·Chrome 수명·sleep·사용자 세션 알림 수신 |
| `Sources/MosemoApp/ChromeAppleEventClient.swift` | Chrome 권한 요청, 활성 창·탭 관찰, 저장된 탭 활성화 |
| `Sources/MosemoApp/SystemEventsClient.swift` | System Events 자동화 권한과 실험적 Firefox 맥락 관찰 |
| `Sources/MosemoApp/ReturnAnchorStore.swift` | 앱 활성화와 Chrome 창·탭 복귀 지점 |
| `Sources/MosemoApp/PerformanceSampler.swift` | 프로세스 CPU·메모리 표본 |
| `Sources/MosemoApp/AuthCoordinator.swift` | PKCE와 ASWebAuthenticationSession 로그인 생명주기 |
| `Sources/MosemoAPI/` | internal 생성 코드, generator 설정, Keychain·오류·모델 경계 |
| `Tests/CollectorCoreTests/` | OS API와 분리된 Core 조건·경계 XCTest |
| `Tests/MosemoAPITests/` | fake generated API를 사용한 인증·오류·PKCE 단위 테스트 |
| `scripts/update_openapi.sh` | 서버 OpenAPI 계약으로부터 생성·테스트 검증 |
| `scripts/check_collector_privacy.sh` | CollectorCore 네트워크 경계와 화면 캡처·영속 기록·금지 필드 정적 검사 |
| `scripts/check_safe_diagnostics.sh` | 복사한 안전 진단에서 금지 데이터 검사 |
| `scripts/sample_collector_process.sh` | 장시간 CPU·RSS 표본 CSV 생성 |
| `scripts/summarize_collector_samples.sh` | 장시간 표본 평균 CPU·최대 RSS 요약 |
| `docs/TRANSITION_RESULTS.csv` | 100회 수동 전환의 행별 기록 양식 |
| `docs/RESULT_TEMPLATE.md` | 새 측정 실행을 위한 빈 결과 양식 |
| `docs/RESULT_2026-08-22.md` | 이번 구현에서 실제 측정한 결과와 미측정 항목 |
| `docs/AUTH_RUNTIME_CHECKLIST.md` | 실제 Kakao 계정이 필요한 수동 로그인 검증 기록 |

## 빌드, 테스트, 실행

Swift 6.1을 포함한 Xcode와 macOS 14 이상이 필요하다. 이 디렉터리를 작업
루트로 두고 실행한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Mosemo.xcodeproj \
  -scheme Mosemo \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/MosemoDerivedData \
  build
```

패키지 테스트는 `swift test`를 기준으로 실행한다. Xcode에서는
`Mosemo.xcodeproj`를 열고 `Mosemo` scheme의
My Mac 대상을 선택해 Run한다. 유료 Apple Developer 계정은 필요하지 않으며
`Sign to Run Locally` ad-hoc 서명을 사용한다.

명령행 build 결과는 TCC가 동일한 로컬 앱으로 식별할 수 있도록 사용자 전용
Applications 디렉터리의 고정 경로에 복사해 실행한다. `/tmp`의 build product를
직접 반복 실행하면 ad-hoc 서명 hash가 바뀔 때 자동화 권한 등록이 불안정할 수
있다.

```sh
mkdir -p "$HOME/Applications"
ditto \
  /tmp/MosemoDerivedData/Build/Products/Debug/Mosemo.app \
  "$HOME/Applications/Mosemo.app"
open "$HOME/Applications/Mosemo.app"
```

Release archive에는 배포 API URL을 build setting으로 전달한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Mosemo.xcodeproj \
  -scheme Mosemo \
  -configuration Release \
  -archivePath /tmp/Mosemo.xcarchive \
  MOSEMO_API_BASE_URL=https://api.example.com \
  archive
```

## OpenAPI client 갱신

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
scripts/update_openapi.sh
```

자세한 내용은 [OpenAPI 갱신 절차](OPENAPI_AUTH_ARCHITECTURE.md#openapi-갱신-절차)를
참고한다.

## 필요한 macOS 권한

| 권한 | 사용 목적 | 허용 방법 |
| --- | --- | --- |
| 자동화 → System Events | Firefox 전면 창의 활성 탭 제목·URL 읽기 | Firefox를 먼저 실행하고 진단 창의 `System Events 권한 요청`을 누른 뒤 macOS prompt를 허용. 이미 거부했다면 자동으로 열린 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 Mosemo 아래 System Events 허용 |
| 자동화 → Google Chrome | 전면 Chrome 창의 mode, 활성 탭 ID·URL 읽기와 저장된 탭 활성화 | Chrome을 먼저 실행하고 진단 창의 `Chrome 자동화 권한 요청`을 누른 뒤 macOS prompt를 허용. 이미 거부했다면 자동으로 열린 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 Mosemo 아래 Google Chrome 허용 |

화면 기록 권한은 요청하지 않는다. `Info.plist`에도 화면 기록 usage description이
없다. 권한을 거부하거나 철회하면 값을 추측하지 않고 `observationUnavailable`
또는 구체적인 복귀 실패 이유를 남긴다.

Xcode의 ad-hoc 로컬 서명은 고정 bundle ID와 동일 build path를 사용한다. macOS가
재빌드된 binary를 새 code requirement로 판단하는 환경에서는 권한 toggle을
다시 켜야 할 수 있다. 이는 유료 Developer ID 없이 수행하는 로컬 spike의
제약이다. 현재 Mac에는 재사용할 code-signing identity가 없으므로 이 빌드의
designated requirement는 `CDHash` 기반이며, 바이너리를 교체한 뒤에는 기존
토글을 껐다가 다시 켜야 할 수 있다. 권한 상태는 각 자동화 요청과 실제 관찰
결과에 따라 진단 화면에 반영한다.

Chrome 자동화 권한 요청 버튼은 권한 항목을 노출하기 위해 Chrome의 버전만 한 번
확인하고 결과 값을 즉시 버린다. 이 요청은 집중 세션 밖에서도 사용할 수 있지만
활동 이벤트를 만들거나 창·탭·URL·제목을 읽지 않는다. 최초 요청을 거부한 뒤에는
macOS가 같은 팝업을 다시 띄우지 않을 수 있으므로 앱이 자동화 설정 화면을 연다.

## 기본 사용 순서

1. 관찰할 작업 앱이나 Chrome 화면을 전면에 둔 채 메뉴 막대 아이콘을 연다.
2. 집중 의도 한 줄을 입력하고 `집중 시작`을 누른다. 이때 현재 화면을 최초
   복귀 지점으로 메모리에 잡는다.
3. 필요하면 `현재 화면을 복귀 지점으로`를 눌러 개발자용 anchor를 갱신한다.
4. `의도된 휴식` 동안 이벤트 수가 변하지 않는지 확인하고 `집중 재개`한다.
5. 다른 화면으로 이동한 뒤 `복귀 테스트`를 누르고 attempt/result를 각각
   확인한다.
6. `집중 종료` 뒤 이벤트 수가 변하지 않는지 확인한다.

진단 창의 화면에는 테스트용 제목·전체 URL이 보이지만 `안전 진단 복사`는 기존
허용 필드와 누적 통계만 clipboard에 복사한다. 앱은 파일을 만들지 않는다.

## 이벤트가 쌓이지 않을 때

권한 허용만으로는 수집을 시작하지 않는다. 다음 순서로 세션 상태부터 확인한다.

1. 메뉴 막대 창에서 비어 있지 않은 `이번 집중 의도`를 입력한다.
2. `집중 시작`을 누르고 상태 문구가 `집중 중입니다.`인지 확인한다.
3. 진단 창의 ring buffer가 탭을 바꾸기 전에도 최초 맥락을 포함해 `1/600`
   이상인지 확인한다.
4. `안전 진단 복사` 결과에서 다음 값인지 확인한다.

   ```text
   sessionPhase=active
   observationState=observed
   ```

`sessionPhase`가 `notStarted`, `intendedRest`, `ended`이면 활동 이벤트를 만들지
않는 것이 정상이다. `observationState=paused`이면 화면 잠금, sleep, 비활성 사용자
세션 등 자동 일시정지 원인을 상태 문구에서 확인한다. Chrome 내부 이벤트는
Chrome이 전면이고 `Chrome 자동화: 허용됨`인 동안에만 관찰한다.

위 조건이 모두 맞는데 최초 맥락도 생기지 않으면 `안전 진단 복사` 내용을 결과
기록에 첨부한다. 이 복사본에는 테스트 화면에 표시되는 원시 URL과 제목이
포함되지 않는다.

## 100회 전환 검증

먼저 진단 창에서 전환 통계를 초기화한다. 앱 전환은 `다음 앱 전환`, Chrome
내부 동작은 `다음 Chrome 전환`을 누른 직후 수행한다. marker와 같은 종류의
다음 이벤트만 expected transition과 일치시킨다. marker 기반 latency에는
사람이 실제 동작을 시작한 시간이 포함되므로 보수적 값이며, Chrome marker를
사용하지 않았을 때 표시되는 latency는 직전 성공 poll 이후의 상한값이다.

다음 10개 그룹을 각각 10회 수행해 총 100회를 만든다.

| 그룹 | 반복 | 기대 이벤트/확인 |
| --- | ---: | --- |
| 앱 A → 앱 B | 10 | `appSwitch`, 대상 bundle ID |
| Chrome 탭 1 ↔ 탭 2 | 10 | `chromeTabSwitch` |
| 같은 탭의 일반 navigation | 10 | `chromeURLChange` 또는 surface가 바뀌면 `chromeSurfaceChange` |
| 같은 탭의 SPA route 변경 | 10 | `chromeURLChange` |
| Chrome 창 1 ↔ 창 2 | 10 | `chromeWindowSwitch` |
| Chrome 전체 화면 진입·이탈 뒤 탭/URL 변경 | 10 | 대응하는 Chrome transition, `observationUnavailable` 없음 |
| Chrome 종료 → 재실행 → 전면화 | 10 | 종료 뒤 다른 앱의 `appSwitch`, 재실행 뒤 `chromeRestart`; 자동화 실패 때만 `observationUnavailable` |
| YouTube `/watch` → `/shorts` | 10 | `chromeSurfaceChange`, `youtubeWatch` → `youtubeShorts` |
| 일반 앱/AX 창 복귀 | 10 | `returnAttempt`와 `returnSuccess` 또는 명시적 실패 이유 |
| Chrome 탭 복귀 | 10 | `returnAttempt`와 `returnSuccess` 또는 명시적 실패 이유 |

각 행은 [TRANSITION_RESULTS.csv](TRANSITION_RESULTS.csv)에 기록한다. Chrome
URL·제목·영상 ID는 notes에 적지 않는다. expected 100, matched 99 이상,
missed 1 이하이고 p95가 2,000ms 이하인지 확인한다. 앱 전환의 latency는
NSWorkspace notification 수신 뒤 pipeline latency이고, OS에서 실제 전면 전환을
시작한 시각은 API가 제공하지 않으므로 별도 end-to-end 수치로 주장하지 않는다.

추가 경계 검증:

- 집중 전 2분, 의도된 휴식 2분, 종료 후 2분 동안 앱·Chrome·입력을 바꾸고
  ring buffer event 수가 각각 0 증가인지 확인한다.
- 시크릿 창에서 2분 동안 전환하고 진단 행에 시각과 `protected`만 나타나는지
  확인한다.
- Chrome 창·탭을 anchor 저장 뒤 닫고 복귀하여 `windowUnavailable` 또는
  `tabUnavailable`가 숨김없이 나타나는지 확인한다.

## 8시간 성능 측정

Xcode에서 앱을 실행한 다음 PID를 찾고 외부 sampler를 실행한다. 출력에는
CPU, RSS, elapsed time만 있고 activity context는 없다.

```sh
pgrep -x Mosemo
scripts/sample_collector_process.sh <PID> 28800 5 > /tmp/collector-8h.csv
scripts/summarize_collector_samples.sh /tmp/collector-8h.csv
```

8시간 동안 위 100회 시나리오와 평상시 집중·휴식을 섞는다. 완료 뒤 다음을
함께 기록한다.

- sampler `average_cpu_percent <= 3.0`
- sampler `maximum_rss_mb <= 200.0`
- 앱 진단 `p95LatencyMs <= 2000`, `missedTransitions <= 1`
- 앱이 살아 있고 세션 state가 일관적인지
- Chrome 종료·재시작 뒤 관찰이 회복됐는지

`ps %CPU`는 sample 시점의 프로세스 CPU 비율이다. 앱 진단의 실행 평균은 5초
간격 `getrusage` delta이며 보조 지표다. 최종 CPU 판정은 동일 Mac에서 sampler
CSV 평균을 사용한다.

## 금지 데이터 검사

정적 검사:

```sh
scripts/check_collector_privacy.sh
```

테스트용 제목·전체 URL은 앱 계층의 비영속 진단 record에 의도적으로 존재한다.
따라서 정적 검사는 `CollectorCore`의 네트워크 부재, 전체 production source의
화면 캡처·DB·파일 저장·application logging 부재, 인증 비밀의 logging 부재를
검사한다. `안전 진단 복사` 결과 검사는 아래 스크립트로 별도 수행한다.

진단 clipboard 내용을 임시 파일로 저장한 경우:

```sh
scripts/check_safe_diagnostics.sh /tmp/collector-safe-diagnostics.txt
```

추가로 Xcode console과 실행 중 process output을 검색한다. 앱 코드에는 `print`,
`Logger`, `NSLog`, `os_log` 호출이 없으므로 정상 실행에서 application output이
없어야 한다. 테스트 fixture에만 의도적인 금지 field 이름과 URL 예제가 있다.
따라서 저장소 전체를 무차별 검색한 결과가 아니라 production source, 실제
진단 snapshot, Xcode console을 서로 나눠 판정한다.

완료 결과는 [RESULT_TEMPLATE.md](RESULT_TEMPLATE.md)에 적는다. 측정하지 않은
항목은 `미측정`으로 유지하며 추정값으로 통과 처리하지 않는다.

이번 구현 시점의 실제 결과와 판정은
[RESULT_2026-08-22.md](RESULT_2026-08-22.md)에 기록했다.

## 알려진 실패 조건

- Firefox 관찰은 공식 탭 API가 아닌 System Events UI scripting과 Accessibility UI
  구조에 의존하는 실험적 경로다. 탭 ID가 없어 탭 전환과 같은 탭 navigation을 구분하지 못하며 Firefox
  버전·UI·전체 화면 상태에 따라 관찰 불가가 될 수 있다.
- Firefox 개인정보 보호 창은 접근성 트리의 비공개 브라우징 표식을 발견하면
  원시 값을 읽거나 표시하지 않는다. 표식 노출은 Firefox UI 구현에 의존하므로
  원시 테스트 모드에서는 개인정보 보호 창을 사용하지 않는다.
- System Events UI 구조나 macOS Automation 정책이 바뀌면 Firefox 관찰이 불가할
  수 있다. Chrome AppleScript dictionary가 바뀌면 Chrome 관찰이 불가하다.
- 닫힌 앱·Chrome 탭은 이 spike에서 복원하지 않으며 복귀 실패다.
- 시크릿 Chrome은 상세 관찰과 상세 복귀 대상에서 제외한다.
- 등록 도메인 계산은 전체 Public Suffix List 구현이 아니다.
- 0.5초 polling은 이론상 Chrome 감지 지연 상한을 만들지만 실제 CPU와 battery
  적합성은 반드시 8시간 측정으로 확인해야 한다.

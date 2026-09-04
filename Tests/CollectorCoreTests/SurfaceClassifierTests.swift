import XCTest
@testable import CollectorCore

final class SurfaceClassifierTests: XCTestCase {
    func testClassifiesYouTubeWatchAndShortsWithoutKeepingURL() {
        let watch = SurfaceClassifier.classify(
            urlString: "https://www.youtube.com/watch?v=sensitive",
            protectedContext: false
        )
        let shorts = SurfaceClassifier.classify(
            urlString: "https://m.youtube.com/shorts/sensitive?feature=share",
            protectedContext: false
        )
        let shortsRoot = SurfaceClassifier.classify(
            urlString: "https://youtube.com/shorts",
            protectedContext: false
        )

        XCTAssertEqual(watch.registeredDomain, "youtube.com")
        XCTAssertEqual(watch.surfaceType, .youtubeWatch)
        XCTAssertEqual(shorts.registeredDomain, "youtube.com")
        XCTAssertEqual(shorts.surfaceType, .youtubeShorts)
        XCTAssertEqual(shortsRoot.surfaceType, .youtubeShorts)
    }

    func testClassifiesOrdinaryAndCompoundSuffixDomains() {
        let ordinary = SurfaceClassifier.classify(
            urlString: "https://private.subdomain.example.com/path",
            protectedContext: false
        )
        let korean = SurfaceClassifier.classify(
            urlString: "https://private.example.co.kr/path",
            protectedContext: false
        )

        XCTAssertEqual(ordinary.registeredDomain, "example.com")
        XCTAssertEqual(ordinary.surfaceType, .browserPage)
        XCTAssertEqual(korean.registeredDomain, "example.co.kr")
    }

    func testInvalidInternalLocalAndIPURLsAreUnavailable() {
        for value in [nil, "chrome://settings", "file:///private/document", "https://localhost/a", "https://127.0.0.1/a"] {
            let classification = SurfaceClassifier.classify(urlString: value, protectedContext: false)
            XCTAssertNil(classification.registeredDomain)
            XCTAssertEqual(classification.surfaceType, .unavailable)
            XCTAssertEqual(classification.observationState, .unavailable)
        }
    }

    func testProtectedClassificationDoesNotParseURL() {
        let classification = SurfaceClassifier.classify(
            urlString: "https://secret.example.com/private",
            protectedContext: true
        )
        XCTAssertNil(classification.registeredDomain)
        XCTAssertEqual(classification.surfaceType, .protectedActivity)
        XCTAssertEqual(classification.observationState, .protected)
        XCTAssertTrue(classification.protectedContext)
    }

    func testChromeTransitionConditions() {
        let page = SurfaceClassification(
            registeredDomain: "example.com",
            surfaceType: .browserPage,
            observationState: .observed,
            protectedContext: false
        )
        let shorts = SurfaceClassification(
            registeredDomain: "youtube.com",
            surfaceType: .youtubeShorts,
            observationState: .observed,
            protectedContext: false
        )
        let base = ChromeObservationIdentity(windowID: 1, tabID: 2, urlFingerprint: 3, classification: page)

        XCTAssertEqual(ChromeTransitionDetector.transition(from: nil, to: base), .initialContext)
        XCTAssertNil(ChromeTransitionDetector.transition(from: base, to: base))
        XCTAssertEqual(
            ChromeTransitionDetector.transition(
                from: base,
                to: ChromeObservationIdentity(windowID: 9, tabID: 2, urlFingerprint: 3, classification: page)
            ),
            .chromeWindowSwitch
        )
        XCTAssertEqual(
            ChromeTransitionDetector.transition(
                from: base,
                to: ChromeObservationIdentity(windowID: 1, tabID: 9, urlFingerprint: 3, classification: page)
            ),
            .chromeTabSwitch
        )
        XCTAssertEqual(
            ChromeTransitionDetector.transition(
                from: base,
                to: ChromeObservationIdentity(windowID: 1, tabID: 2, urlFingerprint: 9, classification: page)
            ),
            .chromeURLChange
        )
        XCTAssertEqual(
            ChromeTransitionDetector.transition(
                from: base,
                to: ChromeObservationIdentity(windowID: 1, tabID: 2, urlFingerprint: 9, classification: shorts)
            ),
            .chromeSurfaceChange
        )
    }

    func testFirefoxTransitionConditions() {
        let base = FirefoxObservationIdentity(windowFingerprint: 1, contentFingerprint: 2)

        XCTAssertEqual(FirefoxTransitionDetector.transition(from: nil, to: base), .initialContext)
        XCTAssertNil(FirefoxTransitionDetector.transition(from: base, to: base))
        XCTAssertEqual(
            FirefoxTransitionDetector.transition(
                from: base,
                to: FirefoxObservationIdentity(windowFingerprint: 9, contentFingerprint: 2)
            ),
            .firefoxWindowSwitch
        )
        XCTAssertEqual(
            FirefoxTransitionDetector.transition(
                from: base,
                to: FirefoxObservationIdentity(windowFingerprint: 1, contentFingerprint: 9)
            ),
            .firefoxPageChange
        )
    }
}

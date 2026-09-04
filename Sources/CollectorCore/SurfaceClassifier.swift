import Foundation

public struct SurfaceClassification: Equatable, Sendable {
    public let registeredDomain: String?
    public let surfaceType: ActivitySurfaceType
    public let observationState: ActivityObservationState
    public let protectedContext: Bool

    public init(
        registeredDomain: String?,
        surfaceType: ActivitySurfaceType,
        observationState: ActivityObservationState,
        protectedContext: Bool
    ) {
        self.registeredDomain = registeredDomain
        self.surfaceType = surfaceType
        self.observationState = observationState
        self.protectedContext = protectedContext
    }
}

public enum SurfaceClassifier {
    public static func classify(urlString: String?, protectedContext: Bool) -> SurfaceClassification {
        guard !protectedContext else {
            return SurfaceClassification(
                registeredDomain: nil,
                surfaceType: .protectedActivity,
                observationState: .protected,
                protectedContext: true
            )
        }

        guard
            let urlString,
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            let domain = RegisteredDomain.from(host: host)
        else {
            return SurfaceClassification(
                registeredDomain: nil,
                surfaceType: .unavailable,
                observationState: .unavailable,
                protectedContext: false
            )
        }

        let path = components.path.lowercased()
        let surface: ActivitySurfaceType
        if domain == "youtube.com" && (path == "/shorts" || path.hasPrefix("/shorts/")) {
            surface = .youtubeShorts
        } else if domain == "youtube.com" && path == "/watch" {
            surface = .youtubeWatch
        } else {
            surface = .browserPage
        }

        return SurfaceClassification(
            registeredDomain: domain,
            surfaceType: surface,
            observationState: .observed,
            protectedContext: false
        )
    }
}

public enum RegisteredDomain {
    private static let commonCompoundSuffixes: Set<String> = [
        "ac.kr", "co.jp", "co.kr", "co.uk", "com.au", "com.br", "com.cn",
        "com.mx", "com.sg", "com.tr", "go.kr", "gov.uk", "ne.jp", "net.au",
        "net.cn", "or.jp", "or.kr", "org.au", "org.cn", "org.uk",
    ]

    public static func from(host: String) -> String? {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty, !isIPAddress(normalized) else { return nil }

        let labels = normalized.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        if commonCompoundSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static func isIPAddress(_ value: String) -> Bool {
        if value.contains(":") { return true }
        let pieces = value.split(separator: ".")
        guard pieces.count == 4 else { return false }
        return pieces.allSatisfy { piece in
            guard let number = Int(piece) else { return false }
            return (0...255).contains(number)
        }
    }
}

public struct ChromeObservationIdentity: Equatable, Sendable {
    public let windowID: Int
    public let tabID: Int
    public let urlFingerprint: Int
    public let classification: SurfaceClassification

    public init(
        windowID: Int,
        tabID: Int,
        urlFingerprint: Int,
        classification: SurfaceClassification
    ) {
        self.windowID = windowID
        self.tabID = tabID
        self.urlFingerprint = urlFingerprint
        self.classification = classification
    }
}

public enum ChromeTransitionDetector {
    public static func transition(
        from previous: ChromeObservationIdentity?,
        to current: ChromeObservationIdentity
    ) -> ActivityTransitionType? {
        guard let previous else { return .initialContext }
        if previous.windowID != current.windowID { return .chromeWindowSwitch }
        if previous.tabID != current.tabID { return .chromeTabSwitch }
        guard previous.urlFingerprint != current.urlFingerprint else { return nil }
        if previous.classification.surfaceType != current.classification.surfaceType {
            return .chromeSurfaceChange
        }
        return .chromeURLChange
    }
}

public struct FirefoxObservationIdentity: Equatable, Sendable {
    public let windowFingerprint: Int
    public let contentFingerprint: Int

    public init(windowFingerprint: Int, contentFingerprint: Int) {
        self.windowFingerprint = windowFingerprint
        self.contentFingerprint = contentFingerprint
    }
}

public enum FirefoxTransitionDetector {
    public static func transition(
        from previous: FirefoxObservationIdentity?,
        to current: FirefoxObservationIdentity
    ) -> ActivityTransitionType? {
        guard let previous else { return .initialContext }
        if previous.windowFingerprint != current.windowFingerprint {
            return .firefoxWindowSwitch
        }
        if previous.contentFingerprint != current.contentFingerprint {
            return .firefoxPageChange
        }
        return nil
    }
}

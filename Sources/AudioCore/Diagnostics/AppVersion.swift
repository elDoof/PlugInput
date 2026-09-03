import Foundation

/// The running build's identity, in the form it should be quoted in a bug report.
///
/// This app is diagnosed from its unified log and from `session.json`, both of which are read
/// long after the fact and neither of which said until now *which build* produced them. With
/// users on a released `.pkg` and fixes landing behind it, "it still freezes" is not actionable
/// without knowing whether the reporter is running the build that fixed it.
///
/// The marketing version and the build number come from the bundle rather than from a constant
/// compiled in here, because `make-app.sh` already derives both — `./VERSION` and the git commit
/// count — and a second source of truth would eventually disagree with the installer's.
public struct AppVersion: Equatable, Sendable, CustomStringConvertible {
    /// `CFBundleShortVersionString`, e.g. `0.9.0`.
    public let shortVersion: String?
    /// `CFBundleVersion`, the monotonic build number.
    public let build: String?

    public init(shortVersion: String?, build: String?) {
        self.shortVersion = shortVersion
        self.build = build
    }

    /// Reads the running bundle. Both keys are absent when the SwiftPM binary is run directly
    /// rather than from `PlugInput.app` — which is a real thing to do while developing and is
    /// worth naming as such, because a version line reading `0.0.0` would look like a release.
    public static var current: AppVersion {
        let info = Bundle.main.infoDictionary
        return AppVersion(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }

    /// Names what is missing rather than substituting a plausible-looking value for it.
    public var description: String {
        switch (shortVersion, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "unbundled development build"
        }
    }
}

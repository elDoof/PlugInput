import Testing

@testable import AudioCore

/// The only thing that can be wrong about a version line is that it lies. A build run outside
/// `PlugInput.app` has no Info.plist at all, and the tempting fallbacks — `0.0.0`, an empty
/// string, the word "unknown" pasted where a number goes — all read as a real version in the
/// bug report they end up in.
@Suite("App version reporting")
struct AppVersionTests {
    @Test("reads as version and build when the bundle carries both")
    func bothPresent() {
        // Arrange
        let version = AppVersion(shortVersion: "0.9.1", build: "412")

        // Act
        let described = version.description

        // Assert
        #expect(described == "0.9.1 (412)")
    }

    @Test("drops the parenthesis rather than showing an empty one when the build is missing")
    func buildMissing() {
        // Arrange
        let version = AppVersion(shortVersion: "0.9.1", build: nil)

        // Act
        let described = version.description

        // Assert
        #expect(described == "0.9.1")
    }

    @Test("says it is unbundled rather than inventing a version number")
    func nothingPresent() {
        // Arrange
        let version = AppVersion(shortVersion: nil, build: nil)

        // Act
        let described = version.description

        // Assert
        #expect(described == "unbundled development build")
        #expect(!described.contains("0"))
    }

    @Test("reports the build alone as unbundled, since a build number is not a version")
    func onlyBuildPresent() {
        // Arrange
        let version = AppVersion(shortVersion: nil, build: "412")

        // Act
        let described = version.description

        // Assert
        #expect(described == "unbundled development build")
    }
}

import Foundation
import Testing

@testable import AudioCore

/// The update check talks to the network and then decides something on the strength of a string a
/// server sent. Everything that could be *wrong* about that decision is here: offering an update
/// to a version the user already has, failing to offer a real one because the comparison was
/// lexicographic, or offering something because a malformed response happened to sort high.
///
/// The failure mode that matters most is the quiet one. This app is not sandboxed and the check is
/// advisory, so a broken check costs nothing visible — it just silently stops telling anyone that
/// fixes exist, which is precisely the situation v0.9.0 users are in now.
@Suite("Update availability")
struct UpdateCheckTests {
    private func release(tag: String, prerelease: Bool = false, draft: Bool = false) -> Data {
        let json = """
        {
          "tag_name": "\(tag)",
          "name": "PlugInput \(tag)",
          "html_url": "https://github.com/elDoof/PlugInput/releases/tag/\(tag)",
          "prerelease": \(prerelease),
          "draft": \(draft)
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Version ordering

    @Test("a higher patch version is an update")
    func higherPatchIsNewer() {
        // Arrange / Act
        let result = UpdateCheck.decide(responseBody: release(tag: "v0.9.2"), currentVersion: "0.9.1")

        // Assert
        #expect(result?.version == "0.9.2")
        #expect(result?.url.absoluteString == "https://github.com/elDoof/PlugInput/releases/tag/v0.9.2")
    }

    @Test("the same version is not an update")
    func sameVersionIsNotNewer() {
        #expect(UpdateCheck.decide(responseBody: release(tag: "v0.9.1"), currentVersion: "0.9.1") == nil)
    }

    @Test("an older published release is not an update")
    func olderIsNotNewer() {
        // Arrange — a rollback, or a machine running an unreleased local build.
        #expect(UpdateCheck.decide(responseBody: release(tag: "v0.9.0"), currentVersion: "0.9.1") == nil)
    }

    @Test("versions compare numerically, not as text")
    func comparesNumericallyNotLexicographically() {
        // Arrange — "0.10.0" sorts BELOW "0.9.0" as a string, which would hide every release
        // after 0.9 for the rest of the app's life. This is the bug this test exists for.
        let result = UpdateCheck.decide(responseBody: release(tag: "v0.10.0"), currentVersion: "0.9.1")

        // Assert
        #expect(result?.version == "0.10.0")
    }

    @Test("a shorter version is padded rather than mis-ranked")
    func twoComponentVersionsCompare() {
        // Arrange — 1.0 is newer than 0.9.1, and 0.9 is not newer than 0.9.1.
        #expect(UpdateCheck.decide(responseBody: release(tag: "v1.0"), currentVersion: "0.9.1")?.version == "1.0")
        #expect(UpdateCheck.decide(responseBody: release(tag: "v0.9"), currentVersion: "0.9.1") == nil)
    }

    @Test("a tag with or without a leading v is read the same way")
    func tagPrefixIsOptional() {
        #expect(UpdateCheck.decide(responseBody: release(tag: "0.9.2"), currentVersion: "0.9.1")?.version == "0.9.2")
    }

    // MARK: - Refusing to guess

    @Test("a draft or prerelease is never offered")
    func draftsAndPrereleasesAreIgnored() {
        #expect(UpdateCheck.decide(responseBody: release(tag: "v1.0.0", prerelease: true), currentVersion: "0.9.1") == nil)
        #expect(UpdateCheck.decide(responseBody: release(tag: "v1.0.0", draft: true), currentVersion: "0.9.1") == nil)
    }

    @Test("a malformed response offers nothing rather than something")
    func malformedResponseIsSilent() {
        // Arrange — rate limiting, an HTML error page, a truncated body, an empty file.
        let bodies = [
            Data("not json at all".utf8),
            Data("{}".utf8),
            Data("""
            {"tag_name": "nightly", "html_url": "https://example.com", "prerelease": false, "draft": false}
            """.utf8),
            Data(),
        ]

        // Act / Assert
        for body in bodies {
            #expect(UpdateCheck.decide(responseBody: body, currentVersion: "0.9.1") == nil)
        }
    }

    @Test("an unbundled development build is never told to update")
    func unbundledBuildIsNotOfferedAnUpdate() {
        // Arrange — AppVersion reports "unbundled development build" rather than inventing a
        // number when there is no Info.plist. Comparing that to a real tag must not resolve to
        // "you are out of date", and must not crash.
        #expect(UpdateCheck.decide(responseBody: release(tag: "v9.9.9"), currentVersion: "unbundled development build") == nil)
    }

    @Test("a release whose URL is unusable is not offered")
    func unusableURLIsSkipped() {
        // Arrange — there is nowhere to send the user, so there is nothing to offer.
        let body = Data("""
        {"tag_name": "v1.0.0", "name": "x", "html_url": "", "prerelease": false, "draft": false}
        """.utf8)

        // Assert
        #expect(UpdateCheck.decide(responseBody: body, currentVersion: "0.9.1") == nil)
    }
}

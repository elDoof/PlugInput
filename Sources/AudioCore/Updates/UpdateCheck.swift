import Foundation

/// Tells the user a newer release exists. It does not install anything.
///
/// ## Why this is the shape it is
///
/// With v0.9.0 installed on other machines and v0.9.1 published, there is currently no way for
/// anyone to learn that fixes exist — every user is on the version with all the bugs, and that
/// gets worse with each release rather than better. This is the cheap end of solving that: read
/// the releases API at launch, compare against the running bundle's version, and offer a link.
///
/// No Sparkle, no signing keys, no auto-install, no new entitlement. The deliberate cost is that
/// the user does the download and the install themselves; the deliberate benefit is that nothing
/// in this app acquires the ability to replace its own binary.
///
/// **It fails silent, in the direction of saying nothing.** Every uncertainty — a malformed body,
/// a tag that is not a version, a rate-limited response, an unbundled build with no version of
/// its own — resolves to "no update", never to a prompt. An advisory check that occasionally
/// stays quiet is a minor loss; one that tells people to reinstall the version they are already
/// running destroys their trust in the next real notice.
public enum UpdateCheck {
    /// Where the releases API lives. `latest` already excludes drafts and prereleases server-side;
    /// the fields are checked anyway, because this decides what to tell a user and the cost of
    /// the extra check is one comparison.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/elDoof/PlugInput/releases/latest")!

    /// A release worth telling the user about.
    public struct Available: Equatable, Sendable {
        /// Normalised, without any leading `v` — this is shown to the user.
        public let version: String
        /// The release page, not the asset: the user should see the notes before downloading.
        public let url: URL
    }

    /// What the server sent. Decoded permissively on purpose — a field this app does not
    /// understand must not fail the whole decode.
    private struct Payload: Decodable {
        let tag_name: String?
        let html_url: String?
        let prerelease: Bool?
        let draft: Bool?
    }

    /// Decides whether to offer an update, given a response body and the running version.
    ///
    /// Pure, so every branch is testable without a network: the network half is
    /// `fetchLatest(using:)` and has no decisions in it.
    public static func decide(responseBody: Data, currentVersion: String) -> Available? {
        guard let running = SemanticVersion(currentVersion) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: responseBody) else { return nil }
        guard payload.draft != true, payload.prerelease != true else { return nil }
        guard let tag = payload.tag_name, let candidate = SemanticVersion(tag) else { return nil }
        guard candidate > running else { return nil }
        guard let link = payload.html_url, let url = URL(string: link), url.scheme != nil else { return nil }

        return Available(version: candidate.description, url: url)
    }

    /// Fetches the latest release body. No decisions, no retries, no logging of the user's IP
    /// anywhere — and a short timeout, because nothing waits on this and a launch must not.
    public static func fetchLatest(using session: URLSession = .shared) async -> Data? {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

/// A dotted numeric version, compared component by component.
///
/// Exists because the obvious comparison is wrong in a way that would hide every future release:
/// `"0.10.0" < "0.9.0"` as text. Anything that is not a dotted number — a `nightly` tag, or
/// `AppVersion`'s "unbundled development build" — fails to parse rather than sorting somewhere
/// arbitrary.
struct SemanticVersion: Comparable, CustomStringConvertible {
    private let components: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // A build number in parentheses, as AppVersion renders it for display.
        if let paren = text.firstIndex(of: " ") { text = String(text[text.startIndex..<paren]) }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    /// Missing trailing components read as zero, so `1.0` and `1.0.0` are the same version and
    /// `1.0` is correctly newer than `0.9.1`.
    private func component(_ index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width where lhs.component(index) != rhs.component(index) {
            return lhs.component(index) < rhs.component(index)
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        return (0..<width).allSatisfy { lhs.component($0) == rhs.component($0) }
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

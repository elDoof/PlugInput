import Foundation

/// Reads and writes the session snapshot as JSON under Application Support.
///
/// JSON rather than `UserDefaults` because the file is worth being able to inspect and delete
/// by hand: a saved plugin that crashes on load would otherwise be reinstated on every launch
/// with no obvious way out. `rm ~/Library/Application Support/PlugInput/session.json` is that
/// way out.
public struct SessionStore: Sendable {
    public let fileURL: URL

    private static let directoryName = "PlugInput"
    private static let fileName = "session.json"

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/PlugInput/session.json`.
    public static func `default`() throws -> SessionStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SessionStore(
            fileURL: support.appending(path: directoryName).appending(path: fileName)
        )
    }

    /// `nil` means first launch. A file that exists but cannot be parsed throws — quietly
    /// resetting would read as "my settings vanished" with nothing to explain it.
    public func load() throws -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic: a partial write interrupted by a plugin crash would be indistinguishable
        // from corruption on the next launch.
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// Used when a restored session turns out to be unusable, so the next launch starts clean.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

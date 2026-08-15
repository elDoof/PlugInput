import Foundation
import OSLog

/// One line of the app's own log, ready to display.
public struct EngineLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
    public let isError: Bool

    public var timestamp: String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Reads back what `EngineLog` wrote, so the app can show its own activity.
///
/// The same entries a terminal sees through `/usr/bin/log show`, surfaced in the UI — because
/// the failures this app produces are silent, and a user watching a dead meter deserves to read
/// "engine start failed: …" rather than guess. `OSLogStore` scoped to this process needs no
/// entitlement and cannot reach anyone else's logs.
public enum EngineLogReader {
    /// How far back to look. Bounding this is what keeps the read cheap: without a start
    /// position `getEntries` walks the process's whole log from launch, and the level meter
    /// writes an entry every second, so the scan grows for as long as the app stays open.
    public static let defaultWindow: TimeInterval = 15 * 60

    /// Blocking and comparatively slow — **never call this on the main thread.**
    ///
    /// `OSLogStore.getEntries` is a synchronous scan, and at 20 Hz metering the store fills
    /// fast. Called on the main actor every couple of seconds, as the Activity panel first did,
    /// it froze the UI for progressively longer the longer the app ran. The window and the
    /// category exclusion below cut the work; running it off the main actor is what keeps the
    /// interface responsive regardless.
    public static func recent(
        limit: Int = 100,
        window: TimeInterval = defaultWindow
    ) throws -> [EngineLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: Date().addingTimeInterval(-window)),
            // Excluding the level category in the *predicate* rather than after the fact
            // matters: it is by far the highest-volume category, and filtering it here means
            // those entries are never materialised into objects at all.
            matching: NSPredicate(
                format: "subsystem == %@ AND category != %@",
                EngineLog.subsystem,
                EngineLog.levelCategory
            )
        )

        let logEntries = entries.compactMap { $0 as? OSLogEntryLog }
            .map {
                EngineLogEntry(
                    date: $0.date,
                    message: $0.composedMessage,
                    isError: $0.level == .error || $0.level == .fault
                )
            }

        return Array(logEntries.suffix(limit))
    }
}

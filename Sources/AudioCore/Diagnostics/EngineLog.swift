import OSLog

/// Structured logging for the audio path.
///
/// This is not debug scaffolding. Every failure mode in this file tree is *silent* — a wrong
/// channel map, an unbound device, or a microphone macOS has not authorized all produce
/// plausible-looking success and inaudible output. The unified log is the only way to see
/// inside the running app, since a menu bar app has no console to print to:
///
/// ```bash
/// log stream --predicate 'subsystem == "com.pluginput.app"' --style compact
/// ```
public enum EngineLog {
    public static let subsystem = "com.pluginput.app"

    /// Lifecycle and failures — the transcript worth showing a user.
    public static let logger = Logger(subsystem: subsystem, category: "engine")

    /// Level metering, once a second. Separated so it can be excluded from that transcript:
    /// a steady drip of peak values would bury the one line that explains a failure.
    public static let levelCategory = "level"
    public static let levels = Logger(subsystem: subsystem, category: levelCategory)
}

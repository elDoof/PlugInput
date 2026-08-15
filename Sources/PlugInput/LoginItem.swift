import ServiceManagement

/// "Open at Login", backed by `SMAppService`.
///
/// Registration is per-bundle-identifier and only works on a real `.app` — the same reason
/// `make-app.sh` exists. Moving or renaming the bundle after registering leaves a stale login
/// item that macOS resolves to nothing, so `status` is read live rather than cached.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}

import AVFoundation
import AppKit
// requestViewController is declared on AUAudioUnit by CoreAudioKit, not AudioToolbox.
import CoreAudioKit
import Observation
import SwiftUI

/// Hosts a plugin's own interface in a plain `NSWindow`.
///
/// `requestViewController` is what makes hosting Audio Units worth it: the real FabFilter,
/// soothe2, or iZotope interface appears, drawn by the vendor's own code. It bridges AUv2
/// plugins as well as AUv3, so it covers essentially the whole installed library.
@MainActor
@Observable
final class PluginWindowController {
    private var window: NSWindow?
    /// Which unit the open window belongs to. Without this, swapping the effect and clicking
    /// "Open" again re-shows the *previous* plugin's interface, still wired to an audio unit
    /// that has already been detached from the engine.
    private var presentedUnit: AVAudioUnit?

    func show(_ effect: AVAudioUnit, title: String) {
        // Reuse the open window rather than stacking duplicates on repeated clicks — but only
        // when it is already showing this same plugin.
        if let window, presentedUnit === effect {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close()
        presentedUnit = effect

        effect.auAudioUnit.requestViewController { [weak self] viewController in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.present(viewController, title: title)
            }
        }
    }

    private func present(_ viewController: NSViewController?, title: String) {
        let content: NSView

        if let viewController, viewController.view.frame.width > 0 {
            content = viewController.view
        } else {
            // Not every plugin ships a view. A generic parameter list would be the fuller
            // answer; for v1 say plainly that there is nothing to show rather than open blank.
            let label = NSTextField(labelWithString: "\(title) has no custom interface.")
            label.frame = NSRect(x: 20, y: 20, width: 360, height: 24)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 64))
            container.addSubview(label)
            content = container
        }

        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
        window = nil
        presentedUnit = nil
    }
}

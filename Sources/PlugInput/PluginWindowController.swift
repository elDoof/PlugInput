import AVFoundation
import AppKit
// requestViewController is declared on AUAudioUnit by CoreAudioKit, not AudioToolbox.
import CoreAudioKit
import Observation
import SwiftUI

/// Hosts plugins' own interfaces in plain `NSWindow`s, one per chain slot.
///
/// `requestViewController` is what makes hosting Audio Units worth it: the real FabFilter,
/// soothe2, or iZotope interface appears, drawn by the vendor's own code. It bridges AUv2
/// plugins as well as AUv3, so it covers essentially the whole installed library.
///
/// Keyed by **slot id** rather than by unit or by index. A chain can hold the same plugin twice,
/// which makes the unit a poor key for telling two windows apart, and any index-based key would
/// repoint every open window at its neighbour the moment the chain is reordered.
@MainActor
@Observable
final class PluginWindowController {
    private var windows: [UUID: NSWindow] = [:]
    /// Which unit each open window belongs to. Without this, removing a slot and adding another
    /// re-shows the *previous* plugin's interface, still wired to a unit the engine has detached.
    private var presentedUnits: [UUID: AVAudioUnit] = [:]

    func show(_ effect: AVAudioUnit, id: UUID, title: String) {
        // Reuse the open window rather than stacking duplicates on repeated clicks — but only
        // when it is already showing this same plugin.
        if let window = windows[id], presentedUnits[id] === effect {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close(id)
        presentedUnits[id] = effect

        effect.auAudioUnit.requestViewController { [weak self] viewController in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.present(viewController, id: id, title: title)
            }
        }
    }

    private func present(_ viewController: NSViewController?, id: UUID, title: String) {
        let content: NSView

        if let viewController, viewController.view.frame.width > 0 {
            content = viewController.view
        } else {
            // Not every plugin ships a view. A generic parameter list would be the fuller
            // answer; for now say plainly that there is nothing to show rather than open blank.
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
        // Cascade the rest. Centring every window stacks a chain's plugins exactly on top of one
        // another, and the ones underneath look like they never opened.
        if !windows.isEmpty {
            let offset = CGFloat(windows.count) * 24
            window.setFrameOrigin(
                NSPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset)
            )
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[id] = window
    }

    /// Closes one slot's window. Called when a slot is removed, so an interface never outlives
    /// the unit behind it.
    func close(_ id: UUID) {
        windows[id]?.close()
        windows[id] = nil
        presentedUnits[id] = nil
    }

    func closeAll() {
        for id in windows.keys { close(id) }
    }
}

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
    /// Content size for the "this plugin has no interface" window.
    private static let placeholderSize = NSRect(x: 0, y: 0, width: 400, height: 64)

    private var windows: [UUID: NSWindow] = [:]
    /// Which unit each open window belongs to. Without this, removing a slot and adding another
    /// re-shows the *previous* plugin's interface, still wired to a unit the engine has detached.
    private var presentedUnits: [UUID: AVAudioUnit] = [:]

    /// The interface request currently outstanding for each slot, and the counter that numbers
    /// them. `requestViewController` is asynchronous, so a slot can have a request in flight
    /// with no window to show for it yet — a state neither `windows` nor `presentedUnits` can
    /// represent, and the one every stale-callback bug here lives in.
    private var pendingRequests: [UUID: Int] = [:]
    private var requestCounter = 0

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

        requestCounter += 1
        let request = requestCounter
        pendingRequests[id] = request

        // The unit rides along inside the completion so it cannot be deallocated while the
        // vendor is still building a view against it. Removing a slot drops the model's
        // reference immediately, and the engine drops its own as soon as the restart detaches
        // the node — neither waits for a GUI request nobody told them about.
        let held = HeldUnit(unit: effect)

        effect.auAudioUnit.requestViewController { [weak self] viewController in
            MainActor.assumeIsolated {
                guard let self else { return }
                withExtendedLifetime(held) {
                    // A heavy plugin takes hundreds of milliseconds to build its GUI, which is
                    // ample time to remove the slot behind it or to click the button a second
                    // time. Both used to open a window anyway: the first for a plugin the user
                    // had just deleted, wired to a unit the engine had already detached, and
                    // the second on top of the first — overwriting `windows[id]` and stranding
                    // a window on screen that nothing could close again.
                    //
                    // Numbering the requests is what distinguishes them; unit identity cannot,
                    // since two requests for the same slot name the same unit.
                    guard self.pendingRequests[id] == request else { return }
                    self.pendingRequests[id] = nil
                    self.present(viewController, id: id, title: title)
                }
            }
        }
    }

    private func present(_ viewController: NSViewController?, id: UUID, title: String) {
        // Sized for the fallback below. Assigning `contentViewController` resizes the window to
        // the plugin's own view; assigning `contentView` does not, so the placeholder path needs
        // a content rect that was right to begin with.
        let window = NSWindow(
            contentRect: Self.placeholderSize,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title

        if let viewController, viewController.view.frame.width > 0 {
            // `contentViewController`, never `contentView = viewController.view`.
            //
            // An `NSViewController` is not retained by its own view, and nothing else here held
            // one: the vendor's controller was released the moment this method returned, leaving
            // its view on screen wired to a deallocated owner. Every AU interface built the
            // normal way — bindings, target/action, KVO on the `AUAudioUnit`, a redraw timer —
            // is reaching through that owner, so the window drew fine and then died on the next
            // interaction or on close. Assigning it here makes the window the owner and gives
            // the controller exactly the lifetime of the window it is in.
            window.contentViewController = viewController
        } else {
            // Not every plugin ships a view. A generic parameter list would be the fuller
            // answer; for now say plainly that there is nothing to show rather than open blank.
            let label = NSTextField(labelWithString: "\(title) has no custom interface.")
            label.frame = NSRect(x: 20, y: 20, width: 360, height: 24)
            let container = NSView(frame: Self.placeholderSize)
            container.addSubview(label)
            window.contentView = container
        }
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
        // Abandons any request still in flight for this slot, which is the whole point: the
        // window it would have opened belongs to a plugin that is on its way out.
        pendingRequests[id] = nil
    }

    func closeAll() {
        // Over the union of both, not just `windows`: a slot with a request in flight has no
        // window yet, and leaving its request live would let a plugin interface open during or
        // after teardown.
        for id in Set(windows.keys).union(pendingRequests.keys) { close(id) }
    }
}

/// Carries an `AVAudioUnit` into a `@Sendable` completion for one reason: to hold it alive
/// until the vendor's view-controller request has finished with it.
///
/// `@unchecked Sendable` on the same terms as `ReleaseBox` in `AudioCore` — the unit is never
/// touched through this box, only kept. The completion runs on the main thread, so if this box
/// does hold the last reference, the vendor's teardown runs there too (gotcha #29).
private struct HeldUnit: @unchecked Sendable {
    let unit: AVAudioUnit
}

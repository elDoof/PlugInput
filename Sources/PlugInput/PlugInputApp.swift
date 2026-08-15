import AudioCore
import SwiftUI

@main
struct PlugInputApp: App {
    @State private var model = AppModel()

    /// Identifies the console window so the menu bar can raise it.
    static let consoleWindowID = "console"

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            // The icon doubles as the on/off indicator, so the app's state is readable from
            // the menu bar without opening anything.
            Image(systemName: model.isRunning ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        // The app is `LSUIElement`, so this window only exists when asked for: it does not
        // appear at launch, and closing it does not quit the app.
        Window("PlugInput", id: Self.consoleWindowID) {
            ConsoleView(model: model)
        }
        .defaultSize(width: 760, height: 500)
    }
}

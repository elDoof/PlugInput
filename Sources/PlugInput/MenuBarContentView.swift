import AudioCore
import SwiftUI

struct MenuBarContentView: View {
    let model: AppModel
    @State private var pluginWindow = PluginWindowController()
    @Environment(\.openWindow) private var openWindow

    /// The app has no dock icon (`LSUIElement`), so a window opened from the menu bar arrives
    /// behind whatever the user was doing unless the app is activated explicitly.
    private func openConsole() {
        openWindow(id: PlugInputApp.consoleWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            inputPicker
            pluginPicker
            monitorToggle
            if model.isRunning { meter }
            if !model.status.isEmpty { statusLine }
            Divider()
            loginToggle
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.refresh() }
    }

    private var monitorToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Monitor through \(model.monitorDevice?.name ?? "output")", isOn: monitorBinding)
                .toggleStyle(.checkbox)
                .font(.caption)

            Text(model.isMonitorEnabled
                 ? "Turn off if your speakers are feeding back into the mic."
                 : "Muted — \(model.virtualMicrophoneName) still receives the processed signal.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var monitorBinding: Binding<Bool> {
        Binding(
            get: { model.isMonitorEnabled },
            set: { enabled in Task { await model.setMonitorEnabled(enabled) } }
        )
    }

    private var header: some View {
        HStack {
            Text("PlugInput").font(.headline)
            Spacer()
            Button(model.isRunning ? "Stop" : "Start") { Task { await model.toggle() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.virtualDevice == nil)
        }
    }

    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: inputSelection) {
                ForEach(model.inputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
        }
    }

    /// Routed through the model rather than bound to its property directly: selecting a device
    /// also has to persist the choice and cycle the engine, and that belongs in one place.
    private var inputSelection: Binding<String?> {
        Binding(
            get: { model.selectedInputUID },
            set: { uid in Task { await model.selectInput(uid) } }
        )
    }

    private var pluginPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Effect").font(.caption).foregroundStyle(.secondary)
            HStack {
                // Choosing happens in the window, where there is room to search. A flat picker
                // over 677 components was never a usable chooser.
                Button {
                    openConsole()
                } label: {
                    HStack {
                        Text(model.selectedPlugin?.name ?? "No effect")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                Button("Open") {
                    if let effect = model.loadedEffect {
                        pluginWindow.show(effect, title: model.selectedPlugin?.name ?? "Effect")
                    }
                }
                .disabled(model.loadedEffect == nil)
            }

            if model.effectLatencyMilliseconds > 5 {
                // Linear-phase EQs and mastering plugins report tens of milliseconds, which
                // makes live monitoring unusable. Say so rather than let it feel broken.
                Text(String(format: "Adds %.0f ms latency — too much for live monitoring",
                            model.effectLatencyMilliseconds))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var pluginSelection: Binding<PluginDescriptor?> {
        Binding(
            get: { model.selectedPlugin },
            set: { newValue in Task { await model.selectPlugin(newValue) } }
        )
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input level").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(min(model.inputPeak, 1)))
                .progressViewStyle(.linear)
        }
    }

    private var statusLine: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(model.virtualDevice == nil ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var loginToggle: some View {
        Toggle("Open at Login", isOn: loginBinding)
            .toggleStyle(.checkbox)
            .font(.caption)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { model.opensAtLogin },
            set: { model.setOpensAtLogin($0) }
        )
    }

    private var footer: some View {
        HStack {
            Button("Window…") { openConsole() }
            Spacer()
            Button("Quit") {
                // Saves the session — including the plugin's current settings and the fact
                // that it was running — and destroys the aggregate device.
                model.prepareForQuit()
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.caption)
    }
}

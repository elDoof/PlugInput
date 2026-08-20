import AudioCore
import SwiftUI

struct MenuBarContentView: View {
    let model: AppModel
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
            if model.isDefaultInputHijacked { defaultInputWarning }
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

    /// Shown when PlugInput's own driver has become the system's default microphone.
    ///
    /// Installing the driver tends to cause this, and the symptom is severe and confusing: every
    /// app that follows the system default hears silence, and nothing points at PlugInput as the
    /// reason. The fix is one click, so it is offered as one rather than as instructions.
    private var defaultInputWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(model.virtualMicrophoneName) is your system microphone",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)

            Text("Other apps that follow the system default will hear silence. "
                 + "Set it back to a real microphone — apps that should hear the processed "
                 + "signal can still choose \(model.virtualMicrophoneName) themselves.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Use \(model.selectedInputDevice?.name ?? "a real microphone")") {
                Task { await model.restoreDefaultInput() }
            }
            .controlSize(.small)
            .disabled(model.inputDevices.isEmpty)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var monitorToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Monitor through \(model.monitorDevice?.name ?? "output")", isOn: monitorBinding)
                .toggleStyle(.checkbox)
                .font(.caption)

            // The "off" wording is deliberately specific. Off does not mute a channel pair — it
            // leaves the output device out of the aggregate altogether, so PlugInput stops
            // opening it. That is the difference that keeps a DAW on the same interface happy,
            // and it is worth the user knowing the switch does something that concrete.
            Text(model.isMonitorEnabled
                 ? "Turn off if your speakers are feeding back into the mic."
                 : "Off — your output device is left alone. \(model.virtualMicrophoneName) "
                   + "still receives the processed signal.")
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

            channelPicker
        }
    }

    /// Shown only when the device has more than one input to choose between.
    ///
    /// A built-in microphone has exactly one, and a picker with a single entry is noise. On an
    /// interface it is the difference between working and silence: capture used to be hardcoded
    /// to the device's first channel, so a microphone in input 2 produced exact digital silence
    /// while every layer reported success and the console blamed microphone permissions.
    ///
    /// Note the tag type. `selectedInputChannel` is non-optional, so rows tag a plain `Int` —
    /// tagging `Optional(channel)` here is exactly the mismatch gotcha #16 is about, and SwiftUI
    /// answers it by silently discarding every click.
    @ViewBuilder
    private var channelPicker: some View {
        if !model.selectableInputChannels.isEmpty {
            Picker("", selection: channelSelection) {
                ForEach(model.selectableInputChannels, id: \.self) { channel in
                    // One-based, because interfaces number their inputs from 1 on the case.
                    Text("Channel \(channel + 1)").tag(channel)
                }
            }
            .labelsHidden()
            .help("Which input on your interface the microphone is plugged into.")
        }
    }

    private var channelSelection: Binding<Int> {
        Binding(
            get: { model.selectedInputChannel },
            set: { channel in Task { await model.selectInputChannel(channel) } }
        )
    }

    /// Routed through the model rather than bound to its property directly: selecting a device
    /// also has to persist the choice and cycle the engine, and that belongs in one place.
    private var inputSelection: Binding<String?> {
        Binding(
            get: { model.selectedInputUID },
            set: { uid in Task { await model.selectInput(uid) } }
        )
    }

    /// A read-only summary. Editing the chain — adding, reordering, bypassing — happens in the
    /// window, where there is room for it. This popover is 320pt wide, and its job is to answer
    /// "what is on my voice right now?" at a glance and then get out of the way.
    private var pluginPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Effect chain").font(.caption).foregroundStyle(.secondary)

            Button {
                openConsole()
            } label: {
                HStack {
                    if model.chain.isEmpty {
                        Text("No effects").foregroundStyle(.secondary)
                    } else {
                        Text(chainSummary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

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

    /// Signal order, with bypassed slots struck through in words rather than styling — this is
    /// one `Text`, and a bypassed plugin still sitting in the chain is worth saying out loud.
    private var chainSummary: String {
        model.chain.slots
            .map { $0.isBypassed ? "(\($0.plugin.name))" : $0.plugin.name }
            .joined(separator: " → ")
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

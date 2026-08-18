import AudioCore
import SwiftUI

/// The window: pick a plugin, watch the signal, read what the app is doing.
///
/// The menu bar popover stays the quick control — start, stop, glance at the level. This is
/// where the answers live when something is wrong, which for this app is the common case:
/// every failure mode is silent, so the routing chain and the engine's own log are shown rather
/// than left to a terminal.
struct ConsoleView: View {
    let model: AppModel

    var body: some View {
        HSplitView {
            PluginBrowserView(model: model)
                .frame(minWidth: 260, idealWidth: 300)

            VStack(alignment: .leading, spacing: 16) {
                transport
                SignalChainView(model: model)
                ChainEditorView(model: model)
                LevelMeterView(peak: model.inputPeak, isRunning: model.isRunning)
                ActivityView()
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 420)
        }
        .frame(minWidth: 680, minHeight: 460)
        .task { await model.refresh() }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(model.isRunning ? "Stop" : "Start") {
                Task { await model.toggle() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.virtualDevice == nil)

            statusBadge

            Toggle("Monitor", isOn: monitorBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Send the processed signal to your speakers or headphones as well. "
                      + "Turn off to stop speaker output feeding back into the microphone.")

            Spacer()

            if model.effectLatencyMilliseconds > 0 {
                Text(String(format: "%.1f ms", model.effectLatencyMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.effectLatencyMilliseconds > 5 ? .orange : .secondary)
                    .help("Latency added by the plugin. Above ~5 ms is hard to talk over.")
            }
        }
    }

    private var monitorBinding: Binding<Bool> {
        Binding(
            get: { model.isMonitorEnabled },
            set: { enabled in Task { await model.setMonitorEnabled(enabled) } }
        )
    }

    private var statusBadge: some View {
        Label(model.isRunning ? "Running" : "Stopped", systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(model.isRunning ? .green : .secondary)
            .imageScale(.small)
    }
}

/// Mic → effect → outputs, drawn as the chain it actually is.
///
/// Worth showing because the interesting failures are routing failures: the wrong input
/// selected, the PlugInput driver missing, or the system output pointed at it so the app refuses to
/// start. Seeing the chain makes those obvious instead of mysterious.
private struct SignalChainView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signal chain").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                stage(inputName, systemImage: "mic")
                arrow
                // Summarised rather than enumerated. The editor directly below lists every slot
                // in order, and eight boxes would overflow this row; what this view is *for* is
                // the routing around the effects — which mic in, which devices out.
                stage(effectsLabel, systemImage: "slider.horizontal.3")
                arrow
                VStack(alignment: .leading, spacing: 4) {
                    stage(model.virtualDevice?.name ?? "PlugInput driver missing", systemImage: "waveform")
                    stage(monitorLabel, systemImage: model.isMonitorEnabled ? "headphones" : "speaker.slash")
                        .opacity(model.isMonitorEnabled ? 1 : 0.5)
                }
            }
        }
    }

    private var inputName: String {
        model.inputDevices.first { $0.uid == model.selectedInputUID }?.name ?? "No input"
    }

    /// One effect is worth naming; several are not worth crowding the row with. Bypassed slots
    /// are counted out of the total, because "3 effects" while two are bypassed would be a
    /// quietly wrong answer to "what is on my voice right now?".
    private var effectsLabel: String {
        let slots = model.chain.slots
        let active = slots.filter { !$0.isBypassed }

        switch (slots.count, active.count) {
        case (0, _): return "No effect"
        case (1, 0): return "\(slots[0].plugin.name) (bypassed)"
        case (1, _): return slots[0].plugin.name
        case (_, 0): return "\(slots.count) effects, all bypassed"
        case let (total, live) where live < total: return "\(live) of \(total) effects"
        default: return "\(slots.count) effects"
        }
    }

    private var monitorLabel: String {
        guard model.isMonitorEnabled else { return "Monitor off" }
        return model.monitorDevice?.name ?? "No output"
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
    }

    private func stage(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Input level on a dB scale, with the number spelled out.
private struct LevelMeterView: View {
    let peak: Float
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input level").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isRunning ? .primary : .secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(peak > 0.9 ? Color.red : Color.green)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 8)

            // Silence while running is the signature of an unauthorized microphone: macOS feeds
            // zeros rather than reporting an error, so say so instead of showing a dead bar and
            // letting it read as a broken app.
            if isRunning, peak == 0 {
                Text("No signal. If this persists, macOS may not have granted microphone access.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var fraction: Double {
        isRunning ? AudioLevel.meterFraction(fromAmplitude: peak) : 0
    }

    private var readout: String {
        guard isRunning else { return "—" }

        let decibels = AudioLevel.decibels(fromAmplitude: peak)
        return decibels <= AudioLevel.floorDecibels
            ? "−∞ dBFS"
            : String(format: "%.1f dBFS", decibels)
    }
}

/// The engine's own log, in the app.
private struct ActivityView: View {
    @State private var entries: [EngineLogEntry] = []
    @State private var failure: String?

    private let refreshInterval: TimeInterval = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let failure {
                        Text(failure).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(entries.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.timestamp)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.caption2)
                                .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    /// The read itself happens off the main actor; only the assignment comes back.
    ///
    /// `.task` inherits this view's main-actor isolation, so calling `EngineLogReader.recent()`
    /// directly ran a synchronous `OSLogStore` scan on the main thread every two seconds — the
    /// UI froze for a beat each time, and for longer the longer the app had been open. The
    /// detached hop is the fix; the bounded window inside the reader keeps the work small.
    private func reload() async {
        let result = await Task.detached(priority: .utility) {
            Result { try EngineLogReader.recent() }
        }.value

        switch result {
        case .success(let loaded):
            entries = loaded
            failure = loaded.isEmpty ? "Nothing logged yet." : nil
        case .failure(let error):
            failure = "Could not read the log: \(error.localizedDescription)"
        }
    }
}

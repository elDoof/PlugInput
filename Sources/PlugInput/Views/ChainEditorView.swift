import AudioCore
import SwiftUI

/// The effect chain, top to bottom in signal order, with the controls to rearrange it.
///
/// Reordering is ↑/↓ buttons rather than drag-to-reorder, deliberately. Gotcha #16 is the
/// precedent: SwiftUI's `List` silently discarded every click in the browser because rows were
/// tagged `Optional`, with no error and no warning — and this app cannot be clicked from the
/// terminal session that builds it, so an interaction that fails silently costs a whole
/// build-and-ask cycle to notice. A button's action is unambiguous and its disabled state is
/// visible.
struct ChainEditorView: View {
    let model: AppModel
    /// The model owns these, so a window cannot outlive the view that opened it.
    private var pluginWindow: PluginWindowController { model.pluginWindows }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if model.chain.isEmpty {
                empty
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(model.chain.slots.enumerated()), id: \.element.id) { index, slot in
                        row(slot, at: index)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Effect chain").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(model.chain.slots.count) of \(PluginChain.maximumSlots)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(model.chain.isFull ? Color.orange : Color.secondary)
        }
    }

    private var empty: some View {
        Text("No effects. Choose one from the list to add it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func row(_ slot: PluginSlot, at index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 0) {
                Text(slot.plugin.name)
                    .font(.callout)
                    .lineLimit(1)
                    .strikethrough(slot.isBypassed, color: .secondary)
                Text(slot.plugin.manufacturer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .opacity(slot.isBypassed ? 0.5 : 1)

            Spacer(minLength: 4)

            // No engine restart behind this one — bypass is a live property on the unit, which is
            // what makes it usable for A/B-ing a plugin while actually talking.
            Toggle("Bypass", isOn: bypassBinding(slot))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Bypass \(slot.plugin.name) without removing it or losing its settings")

            Button {
                guard let unit = model.loadedUnits[slot.id] else { return }
                pluginWindow.show(unit, id: slot.id, title: slot.plugin.name)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(model.loadedUnits[slot.id] == nil)
            .help("Open \(slot.plugin.name)'s own interface")

            Button {
                Task { await model.moveSlot(slot.id, by: -1) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move earlier in the chain")

            Button {
                Task { await model.moveSlot(slot.id, by: 1) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == model.chain.slots.count - 1)
            .help("Move later in the chain")

            Button {
                // Close the interface first: the window's view belongs to a unit that is about to
                // be detached from the engine and released.
                pluginWindow.close(slot.id)
                Task { await model.removeSlot(slot.id) }
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove \(slot.plugin.name) from the chain")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func bypassBinding(_ slot: PluginSlot) -> Binding<Bool> {
        Binding(
            get: { slot.isBypassed },
            set: { model.setBypass($0, for: slot.id) }
        )
    }
}

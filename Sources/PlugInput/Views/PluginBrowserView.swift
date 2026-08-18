import AudioCore
import SwiftUI

/// Search-first chooser for the installed effects.
///
/// A flat `Picker` over 677 components is unusable, so the list is filtered by a search field
/// and grouped by manufacturer. Selecting reloads the engine, which costs a brief dropout —
/// hence a single click to choose and a separate button to open the plugin's own interface,
/// rather than anything that swaps plugins as you arrow through the list.
struct PluginBrowserView: View {
    let model: AppModel

    @State private var query = ""
    @State private var pluginWindow = PluginWindowController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            list
            Divider()
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(model.availablePlugins.count) effects", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    /// Rows are buttons rather than `List` selection on purpose.
    ///
    /// `List(selection:)` binds `Binding<SelectionValue?>`, so rows must be tagged with the
    /// *non-optional* value — tagging `Optional(plugin)`, which is what `Picker` wants, makes
    /// the tag type disagree with the selection type and SwiftUI then ignores every click with
    /// no error. A button's action is unambiguous, and it also gives "No effect" somewhere to
    /// live, which a selection binding cannot express.
    private var list: some View {
        List {
            ForEach(manufacturers, id: \.self) { manufacturer in
                Section(manufacturer) {
                    ForEach(results.filter { $0.manufacturer == manufacturer }) { plugin in
                        row(title: plugin.name, count: count(of: plugin)) {
                            await model.addPlugin(plugin)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if results.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var footer: some View {
        HStack {
            // Opening a plugin's interface belongs to the chain editor now — there is one button
            // per slot there, which is the only place that can say *which* instance to open.
            Text(model.chain.isFull
                 ? "Chain is full (\(PluginChain.maximumSlots))"
                 : "Click to add to the chain")
                .foregroundStyle(model.chain.isFull ? .orange : .secondary)

            Spacer()

            Button("Rescan") { Task { await model.rescanPlugins() } }
                .help("Re-reads the installed Audio Units")
        }
        .font(.caption)
        .padding(10)
    }

    /// A row adds its plugin to the end of the chain. `count` is how many times it is already in
    /// there — shown rather than prevented, because loading the same plugin twice is a legitimate
    /// thing to want, and a badge answers "did my click register?" for a plugin already present.
    private func row(
        title: String,
        count: Int,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 {
                    Text(count == 1 ? "in chain" : "×\(count)")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(model.chain.isFull ? .tertiary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.chain.isFull)
    }

    private func count(of plugin: PluginDescriptor) -> Int {
        model.chain.slots.count { $0.plugin == plugin }
    }

    private var results: [PluginDescriptor] {
        PluginSearch.matches(query: query, in: model.availablePlugins)
    }

    /// Manufacturers in first-appearance order — the catalog is already sorted by manufacturer
    /// then name, so this preserves that ordering without sorting a second time.
    private var manufacturers: [String] {
        var seen = Set<String>()
        return results.compactMap { seen.insert($0.manufacturer).inserted ? $0.manufacturer : nil }
    }

}

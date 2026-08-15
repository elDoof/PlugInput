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
            Section {
                row(title: "No effect", isSelected: model.selectedPlugin == nil) {
                    await model.selectPlugin(nil)
                }
                .foregroundStyle(.secondary)
            }

            ForEach(manufacturers, id: \.self) { manufacturer in
                Section(manufacturer) {
                    ForEach(results.filter { $0.manufacturer == manufacturer }) { plugin in
                        row(title: plugin.name, isSelected: model.selectedPlugin == plugin) {
                            await model.selectPlugin(plugin)
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
            Button("Open Plugin Window") {
                guard let effect = model.loadedEffect else { return }
                pluginWindow.show(effect, title: model.selectedPlugin?.name ?? "Effect")
            }
            .disabled(model.loadedEffect == nil)
            .help("Shows the plugin's own interface, drawn by the vendor")

            Spacer()

            Button("Rescan") { Task { await model.rescanPlugins() } }
                .help("Re-reads the installed Audio Units")
        }
        .font(.caption)
        .padding(10)
    }

    /// Loading a plugin rebuilds the graph, so a row shows it is working rather than appearing
    /// to do nothing for the moment the engine cycles.
    private func row(
        title: String,
        isSelected: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

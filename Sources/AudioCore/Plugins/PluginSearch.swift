import Foundation

/// Filters the installed library down to something a person can pick from.
///
/// This machine has 677 AU effects. A flat list of that length is not a chooser, it is a
/// haystack — so search is the primary way in, not a convenience.
public enum PluginSearch {
    /// Every whitespace-separated term must appear in the name or the manufacturer, in any
    /// order. That makes "izotope dynamics" and "dynamics izotope" both work, which matters
    /// when the user half-remembers a vendor and half-remembers a module.
    public static func matches(query: String, in plugins: [PluginDescriptor]) -> [PluginDescriptor] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return plugins }

        return plugins.filter { plugin in
            let haystack = "\(plugin.name) \(plugin.manufacturer)"
            return terms.allSatisfy { term in
                haystack.localizedCaseInsensitiveContains(term)
            }
        }
    }
}

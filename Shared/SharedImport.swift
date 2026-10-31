import Foundation

/// Hand-off between the share extension and the app, through the shared App Group container.
enum SharedImport {
    static let appGroup = "group.com.chaoyi.echoshadow"
    static let scheme = "echoshadow"

    struct Item: Codable, Equatable {
        enum Kind: String, Codable { case youtube, file, text, article }
        var kind: Kind
        /// A YouTube link, plain text, or a file name inside the shared Inbox folder.
        var value: String
        var title: String?
        var date = Date()
    }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var inbox: URL? {
        guard let dir = container?.appendingPathComponent("Inbox", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var queueURL: URL? { container?.appendingPathComponent("pending-imports.json") }

    @discardableResult
    static func enqueue(_ item: Item) -> Bool {
        guard let url = queueURL else { return false }
        var items = read()
        items.removeAll { $0.kind == item.kind && $0.value == item.value }
        items.append(item)
        guard let data = try? JSONEncoder().encode(items) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func dequeueAll() -> [Item] {
        let items = read()
        if let url = queueURL { try? FileManager.default.removeItem(at: url) }
        return items
    }

    private static func read() -> [Item] {
        guard let url = queueURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func fileURL(for item: Item) -> URL? {
        guard item.kind == .file else { return nil }
        return inbox?.appendingPathComponent(item.value)
    }

    /// Removes shared files that were imported (or abandoned) more than a day ago.
    static func cleanInbox() {
        guard let dir = inbox,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// echoshadow://import opens the app and drains the queue. Links and text can also travel inline,
    /// so they still arrive if the App Group is unavailable.
    static func link(inline item: Item?) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "import"
        if let item, item.kind != .file {
            comps.queryItems = [URLQueryItem(name: "kind", value: item.kind.rawValue), URLQueryItem(name: "value", value: item.value)]
            if let t = item.title { comps.queryItems?.append(URLQueryItem(name: "title", value: t)) }
        }
        return comps.url ?? URL(string: "\(scheme)://import")!
    }

    static func item(from url: URL) -> Item? {
        guard url.scheme == scheme, url.host == "import",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let kindRaw = q.first(where: { $0.name == "kind" })?.value, let kind = Item.Kind(rawValue: kindRaw),
              let value = q.first(where: { $0.name == "value" })?.value, !value.isEmpty else { return nil }
        return Item(kind: kind, value: value, title: q.first(where: { $0.name == "title" })?.value)
    }

    /// The whole text is one web link (as Safari shares a page), not a passage that mentions one.
    static func soleWebLink(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), let url = URL(string: t),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return t
    }

    /// The first YouTube link in a block of text, if any.
    static func youTubeLink(in text: String) -> String? {
        let pattern = #"https?://(?:www\.|m\.)?(?:youtube\.com/(?:watch\?[^\s]*v=|shorts/|live/|embed/)|youtu\.be/)[A-Za-z0-9_-]{11}[^\s]*"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}

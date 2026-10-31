import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share-sheet entry point: accepts a YouTube link, a web article, a PDF, an audio/video file, or text, and hands it to Echo Shadow.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareView(model: model,
                             onOpen: { [weak self] in self?.openApp() },
                             onDone: { [weak self] in self?.finish() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let context = extensionContext
        Task { await model.load(from: context) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Share extensions can't call UIApplication.open directly. The extension's UIApplication is still reachable
    /// through the responder chain, so call open(_:options:completionHandler:) through the Objective-C runtime.
    private func openApp() {
        let url = SharedImport.link(inline: model.queued ? nil : model.item)
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if NSStringFromClass(type(of: r)).contains("Application"), r.responds(to: selector), let imp = r.method(for: selector) {
                typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(imp, to: OpenURL.self)
                let completion: @convention(block) (Bool) -> Void = { [weak self] ok in
                    DispatchQueue.main.async {
                        if ok {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.finish() }
                        } else {
                            self?.model.openFailed = true
                        }
                    }
                }
                open(r, selector, url as NSURL, NSDictionary(), completion)
                return
            }
            responder = r.next
        }
        model.openFailed = true
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }

    @Published var phase: Phase = .loading
    @Published var openFailed = false
    private(set) var item: SharedImport.Item?
    /// True when the item was written to the App Group queue (the app will find it on next launch).
    private(set) var queued = false

    var summary: String {
        guard let item else { return "" }
        switch item.kind {
        case .youtube: return "YouTube video:\n\(item.value)"
        case .file: return "Imported file: \(item.title ?? item.value)"
        case .text: return "Text: \(String(item.value.prefix(140)))\(item.value.count > 140 ? "…" : "")"
        case .article: return "Article to read aloud:\n\(item.title ?? item.value)"
        }
    }

    func load(from context: NSExtensionContext?) async {
        let inputs = (context?.inputItems as? [NSExtensionItem]) ?? []
        let providers = inputs.flatMap { $0.attachments ?? [] }
        let title = inputs.first?.attributedContentText?.string

        var found: SharedImport.Item?
        // 1. A PDF or media file.
        for p in providers {
            if let type = p.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .pdf) }),
               let name = await copyFile(p, type: type) {
                found = SharedImport.Item(kind: .file, value: name, title: title ?? p.suggestedName)
                break
            }
        }
        // 2. A link (web, or a file URL to a PDF or media).
        if found == nil {
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                guard let url = await loadURL(p) else { continue }
                if url.isFileURL, let type = UTType(filenameExtension: url.pathExtension), (type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)),
                   let name = copy(url) {
                    found = SharedImport.Item(kind: .file, value: name, title: url.deletingPathExtension().lastPathComponent)
                } else if let link = SharedImport.youTubeLink(in: url.absoluteString) {
                    found = SharedImport.Item(kind: .youtube, value: link, title: title)
                } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    // Any other web page: import it as an article to read aloud.
                    found = SharedImport.Item(kind: .article, value: url.absoluteString, title: title)
                }
                if found != nil { break }
            }
        }
        // 3. Plain text, possibly containing a YouTube link.
        if found == nil {
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                guard let text = await loadText(p), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let link = SharedImport.youTubeLink(in: text) {
                    found = SharedImport.Item(kind: .youtube, value: link, title: title)
                } else if let link = SharedImport.soleWebLink(in: text) {
                    found = SharedImport.Item(kind: .article, value: link, title: title)
                } else {
                    found = SharedImport.Item(kind: .text, value: text, title: title)
                }
                break
            }
        }
        guard let found else {
            phase = .failed("Echo Shadow can import YouTube links, web articles, PDFs, audio or video files, and text. This item isn't one of those.")
            return
        }
        item = found
        queued = SharedImport.enqueue(found)
        if found.kind == .file && !queued {
            phase = .failed("Couldn't hand the file to Echo Shadow. Use “Open in Echo Shadow” from the Files app instead.")
            return
        }
        phase = .ready
    }

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                if let url = value as? URL { cont.resume(returning: url) }
                else if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { cont.resume(returning: url) }
                else if let s = value as? String, let url = URL(string: s) { cont.resume(returning: url) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                if let s = value as? String { cont.resume(returning: s) }
                else if let data = value as? Data { cont.resume(returning: String(data: data, encoding: .utf8)) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    /// The provider's temporary file disappears when the handler returns, so copy it inside the handler.
    private func copyFile(_ p: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                cont.resume(returning: url.flatMap { Self.copyIntoInbox($0) })
            }
        }
    }

    private func copy(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Self.copyIntoInbox(url)
    }

    nonisolated private static func copyIntoInbox(_ url: URL) -> String? {
        guard let inbox = SharedImport.inbox else { return nil }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = UUID().uuidString + "." + ext
        do {
            try FileManager.default.copyItem(at: url, to: inbox.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onOpen: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch model.phase {
                case .loading:
                    ProgressView("Reading…")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                    Button("Close", action: onDone).buttonStyle(.bordered)
                case .ready:
                    Image(systemName: "waveform.badge.plus").font(.system(size: 48)).foregroundStyle(Color.accentColor)
                    Text("Ready for Echo Shadow").font(.title3.bold())
                    Text(model.summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: onOpen) {
                        Label("Open Echo Shadow", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.queued {
                        Button("Later", action: onDone)
                        Text("It will be waiting the next time you open Echo Shadow.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if model.openFailed {
                        Text("Couldn't switch apps automatically. Open Echo Shadow yourself; the item is waiting there.")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Echo Shadow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
        }
    }
}

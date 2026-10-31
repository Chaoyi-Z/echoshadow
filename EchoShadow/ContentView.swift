import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var importRequest: LessonPrefill?
    @State private var pdfImportRequest: PDFImportRequest?

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(importRequest: $importRequest)
                .tabItem { Label("Lessons", systemImage: "waveform") }
                .tag(0)
            ConversationView()
                .tabItem { Label("Talk", systemImage: "bubble.left.and.bubble.right") }
                .tag(1)
            WordsView()
                .tabItem { Label("Words", systemImage: "character.book.closed") }
                .tag(2)
            LiteratureLibraryView(importRequest: $pdfImportRequest)
                .tabItem { Label("Literature", systemImage: "books.vertical") }
                .tag(4)
            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(3)
        }
        .onOpenURL { handle($0) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkPending() } }
        .task {
            SharedImport.cleanInbox()
            checkPending()
        }
    }

    /// echoshadow:// links from the share extension, or files sent with "Open in Echo Shadow".
    private func handle(_ url: URL) {
        if url.isFileURL {
            present(LessonPrefill(content: .file(url), title: url.deletingPathExtension().lastPathComponent))
            return
        }
        if let item = SharedImport.item(from: url) { present(item) }
        checkPending()
    }

    private func checkPending() {
        let items = SharedImport.dequeueAll()
        guard let newest = items.max(by: { $0.date < $1.date }) else { return }
        present(newest)
    }

    private func present(_ item: SharedImport.Item) {
        switch item.kind {
        case .youtube:
            present(LessonPrefill(content: .youtube(item.value), title: item.title))
        case .article:
            present(LessonPrefill(content: .article(item.value), title: item.title))
        case .text:
            if let link = SharedImport.youTubeLink(in: item.value) {
                present(LessonPrefill(content: .youtube(link), title: item.title))
            } else if let link = SharedImport.soleWebLink(in: item.value) {
                present(LessonPrefill(content: .article(link), title: item.title))
            } else {
                present(LessonPrefill(content: .text(item.value), title: item.title))
            }
        case .file:
            if let url = SharedImport.fileURL(for: item) {
                present(LessonPrefill(content: .file(url), title: item.title))
            }
        }
    }

    private func present(_ prefill: LessonPrefill) {
        if case .file(let url) = prefill.content, url.pathExtension.lowercased() == "pdf" {
            pdfImportRequest = PDFImportRequest(url: url, title: prefill.title)
            tab = 4
            return
        }
        tab = 0
        // Don't stack sheets: replace a pending request only when it's a different item.
        if importRequest?.content != prefill.content { importRequest = prefill }
    }
}

import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PDFImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    var title: String? = nil
}

struct LiteratureLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LiteratureDocument.createdAt, order: .reverse) private var documents: [LiteratureDocument]
    @Binding var importRequest: PDFImportRequest?
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var error: String?
    @State private var openedDocument: LiteratureDocument?

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("Your reading library", systemImage: "books.vertical")
                    } description: {
                        Text("Import a PDF book or paper. Read it, listen to a page, and explore the ideas with AI.")
                    } actions: {
                        Button("Import PDF", systemImage: "plus") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(documents) { document in
                            NavigationLink {
                                LiteratureReaderView(document: document)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(document.title).font(.headline).lineLimit(2)
                                        Text("\(document.pages.count) pages · Page \(document.currentPage + 1)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if !document.summary.isEmpty {
                                            Label("Summary saved", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Literature")
            .navigationDestination(item: $openedDocument) { LiteratureReaderView(document: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import PDF", systemImage: "plus") { showImporter = true }.disabled(importing)
                }
            }
            .overlay {
                if importing {
                    ProgressView("Importing PDF…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): Task { await importPDF(url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("PDF import failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: importRequest?.id, initial: true) { _, _ in
                guard let request = importRequest else { return }
                importRequest = nil
                Task { await importPDF(request.url, title: request.title) }
            }
        }
    }

    @MainActor
    private func importPDF(_ url: URL, title: String? = nil) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var storedName: String?
        do {
            let name = try MediaStore.importFile(from: url)
            storedName = name
            let storedURL = MediaStore.url(for: name)
            let pages = try await Task.detached(priority: .userInitiated) {
                try LiteratureImport.extract(from: storedURL)
            }.value
            let document = LiteratureDocument(title: title ?? url.deletingPathExtension().lastPathComponent, fileName: name, pages: pages)
            context.insert(document)
            do { try context.save() } catch { context.delete(document); throw error }
            openedDocument = document
        } catch {
            if let storedName { MediaStore.remove(storedName) }
            self.error = error.localizedDescription
        }
    }

    private func delete(_ offsets: IndexSet) {
        let removed = offsets.map { documents[$0] }
        for document in removed { context.delete(document) }
        do {
            try context.save()
            for document in removed { MediaStore.remove(document.fileName) }
        } catch {
            context.rollback()
            self.error = error.localizedDescription
        }
    }
}

struct LiteratureReaderView: View {
    @Bindable var document: LiteratureDocument
    @Environment(\.modelContext) private var context
    @StateObject private var voice = SpeechVoice()
    @StateObject private var ai = LiteratureAI()
    @State private var showAI = false
    @State private var showText = false

    private var pageText: String {
        document.pages.indices.contains(document.currentPage) ? document.pages[document.currentPage] : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            PDFReader(url: MediaStore.url(for: document.fileName), page: $document.currentPage)
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Button("Previous page", systemImage: "chevron.left") { document.currentPage -= 1 }
                        .labelStyle(.iconOnly).disabled(document.currentPage == 0)
                    Spacer()
                    Text("Page \(document.currentPage + 1) of \(document.pages.count)").font(.subheadline.monospacedDigit())
                    Spacer()
                    Button("Next page", systemImage: "chevron.right") { document.currentPage += 1 }
                        .labelStyle(.iconOnly).disabled(document.currentPage >= document.pages.count - 1)
                }
                if document.pages.count > 1 {
                    Slider(value: Binding(get: { Double(document.currentPage) }, set: { document.currentPage = Int($0) }),
                           in: 0...Double(document.pages.count - 1), step: 1)
                        .accessibilityLabel("PDF page")
                }
                HStack {
                    Button(voice.isSpeaking ? "Stop reading" : "Read page", systemImage: voice.isSpeaking ? "stop.fill" : "speaker.wave.2") {
                        if voice.isSpeaking { voice.stop() } else { voice.speak(pageText, rate: 1) }
                    }.disabled(pageText.isEmpty)
                    Spacer()
                    Button("Page text", systemImage: "text.alignleft") { showText = true }
                }.font(.subheadline)
            }.padding().background(.bar)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ask AI", systemImage: "sparkles") { voice.stop(); showAI = true }
            }
        }
        .sheet(isPresented: $showAI) {
            LiteratureAIView(document: document, ai: ai)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showText) {
            NavigationStack {
                ScrollView {
                    Text(pageText.isEmpty ? "No selectable text on this page. A scanned page needs OCR before it can be read aloud or analyzed." : pageText)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("PDF page \(document.currentPage + 1)")
                .toolbar { Button("Done") { showText = false } }
            }
        }
        .onChange(of: document.currentPage) { _, _ in voice.stop() }
        .onDisappear { voice.stop(); ai.cancel(); try? context.save() }
    }
}

/// PDFKit retains zoom and scroll position while SwiftUI updates the page controls.
struct PDFReader: UIViewRepresentable {
    let url: URL
    @Binding var page: Int

    func makeCoordinator() -> Coordinator { Coordinator(page: $page) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        if let target = view.document?.page(at: page) { view.go(to: target) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.page = $page
        if let document = view.document, let target = document.page(at: page),
           view.currentPage != target { view.go(to: target) }
    }

    final class Coordinator: NSObject {
        var page: Binding<Int>
        init(page: Binding<Int>) { self.page = page }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: view)
        }
        @objc private func changed(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let current = view.currentPage,
                  let document = view.document else { return }
            let index = document.index(for: current)
            guard index != NSNotFound, page.wrappedValue != index else { return }
            // Avoid publishing a binding mutation during updateUIView.
            DispatchQueue.main.async { [weak self] in self?.page.wrappedValue = index }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct LiteratureAIView: View {
    @Bindable var document: LiteratureDocument
    @ObservedObject var ai: LiteratureAI
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var voice = SpeechVoice()
    @State private var question = ""
    @State private var showSettings = false
    @State private var mode = 0
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("AI window", selection: $mode) {
                    Text("Summary").tag(0)
                    Text("Ask questions").tag(1)
                }.pickerStyle(.segmented).padding()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(settings.chatProvider == .apple
                                 ? "Using on-device Apple AI."
                                 : "Using \(settings.chatProvider.label). Summary and question requests send extracted text to your configured AI service.")
                                .font(.caption).foregroundStyle(.secondary)
                            if document.readablePageCount < document.pages.count {
                                Label("\(document.pages.count - document.readablePageCount) pages have no selectable text. AI can use only the other pages; images and figures are not analyzed.", systemImage: "doc.viewfinder")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if mode == 0 { summaryContent } else { chatContent }
                            if ai.busy {
                                HStack {
                                    ProgressView()
                                    Text(ai.progress).font(.caption)
                                    Spacer()
                                    Button("Cancel") { ai.cancel() }
                                }
                            }
                            if let error = ai.error {
                                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }
                    .onChange(of: document.messages.count) { _, _ in
                        question = ""
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                if mode == 1 {
                    HStack(alignment: .bottom) {
                        TextField("Ask about this PDF…", text: $question, axis: .vertical)
                            .lineLimit(1...4).textFieldStyle(.roundedBorder)
                            .onChange(of: question) { _, value in if value.count > 2_000 { question = String(value.prefix(2_000)) } }
                        Button("Send", systemImage: "arrow.up.circle.fill") {
                            voice.stop()
                            ai.ask(question.trimmingCharacters(in: .whitespacesAndNewlines), document: document, context: context)
                        }
                        .labelStyle(.iconOnly).font(.title)
                        .disabled(ai.busy || document.readablePageCount == 0 || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding().background(.bar)
                }
            }
            .navigationTitle("Literature AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("AI settings", systemImage: "gearshape") { showSettings = true }
                        Button("Clear questions", systemImage: "trash", role: .destructive) { confirmClear = true }
                            .disabled(ai.busy || document.messages.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("Clear this document's question history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear questions", role: .destructive) {
                    let old = document.messages
                    document.messages = []
                    do { try context.save() } catch { document.messages = old; ai.error = error.localizedDescription }
                }
            }
            .onDisappear { voice.stop(); ai.cancel() }
        }
    }

    @ViewBuilder private var summaryContent: some View {
        if document.summary.isEmpty {
            ContentUnavailableView("Understand the big picture", systemImage: "sparkles", description: Text("Summarize the document's main ideas, evidence, and limitations. Long books require multiple AI requests. You can cancel at any time."))
        } else {
            Text(document.summary).textSelection(.enabled)
            Button(voice.isSpeaking ? "Stop reading" : "Read summary", systemImage: voice.isSpeaking ? "stop.fill" : "speaker.wave.2") {
                if voice.isSpeaking { voice.stop() } else { voice.speak(document.summary, rate: 1) }
            }
        }
        Button(document.summary.isEmpty ? "Summarize document" : "Regenerate summary", systemImage: "sparkles") {
            voice.stop()
            ai.summarize(document, context: context)
        }.buttonStyle(.borderedProminent).disabled(ai.busy || document.readablePageCount == 0)
        if document.readablePageCount == 0 { Text(LiteratureError.noText.localizedDescription).font(.callout) }
    }

    @ViewBuilder private var chatContent: some View {
        Text("Answers use selected text excerpts and cite physical PDF pages. Check the sources for accuracy.")
            .font(.caption).foregroundStyle(.secondary)
        if document.messages.isEmpty {
            ForEach(["What is the main argument?", "Explain the methods and key findings.", "What are the limitations?"], id: \.self) { prompt in
                Button(prompt) { question = prompt }.buttonStyle(.bordered).disabled(ai.busy)
            }
        }
        ForEach(document.messages) { message in
            VStack(alignment: .leading, spacing: 10) {
                Label(message.isUser ? "You" : "Literature AI", systemImage: message.isUser ? "person" : "sparkles")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
                if !message.sourcePages.isEmpty {
                    Text("Source excerpts supplied to AI").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(message.sourcePages, id: \.self) { page in
                                Button("Page \(page + 1)") { document.currentPage = page; dismiss() }
                                    .buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(message.isUser ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

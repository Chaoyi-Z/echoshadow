// Standalone macOS checks: production literature code + a deterministic AI, no API credentials.
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import SwiftData
import SwiftUI

@MainActor final class AppSettings {
    enum Kind { case apple, cloud }
    static let shared = AppSettings()
    var chatProvider = Kind.apple
}
@MainActor protocol ChatProvider: AnyObject {
    func reset(instructions: String)
    func send(_ text: String) async throws -> String
}
enum TestFailure: Error { case service }
@MainActor final class FakeProvider: ChatProvider {
    var requests: [String] = []
    var fail = false
    var delay = false
    func reset(instructions: String) {}
    func send(_ text: String) async throws -> String {
        requests.append(text)
        if fail { throw TestFailure.service }
        if delay { try await Task.sleep(for: .seconds(10)) }
        return "Key findings and limitations [p. 1]."
    }
}
@MainActor enum ChatProviderFactory {
    static var provider = FakeProvider()
    static func make(from settings: AppSettings) throws -> any ChatProvider { provider }
}

@main struct LiteratureChecks {
    @MainActor static func wait(_ ai: LiteratureAI) async throws {
        for _ in 0..<1_000 {
            if !ai.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("AI task did not finish")
    }

    @MainActor static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("literature-checks-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Extraction preserves physical page offsets, including a scanned/blank page in the middle.
        let pdfURL = scratch.appendingPathComponent("paper.pdf")
        let consumer = CGDataConsumer(url: pdfURL as CFURL)!
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for text in ["First page: methods and results", "", "Third page: limitations"] {
            canvas.beginPDFPage(nil)
            canvas.textPosition = CGPoint(x: 40, y: 700)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            CTLineDraw(line, canvas)
            canvas.endPDFPage()
        }
        canvas.closePDF()
        let pages = try LiteratureImport.extract(from: pdfURL)
        precondition(pages.count == 3 && pages[0].contains("methods") && pages[1].isEmpty && pages[2].contains("limitations"))
        let invalid = scratch.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        do { _ = try LiteratureImport.extract(from: invalid); fatalError("Invalid PDF accepted") }
        catch LiteratureError.invalidPDF { }
        let locked = scratch.appendingPathComponent("locked.pdf")
        precondition(PDFDocument(url: pdfURL)!.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        do { _ = try LiteratureImport.extract(from: locked); fatalError("Locked PDF accepted") }
        catch LiteratureError.locked { }

        // Chunking must preserve Unicode and the final page of a long document.
        let longText = String(repeating: "研究 📖 findings. ", count: 1_000)
        let chunks = LiteratureContext.chunks(pages: [longText, "", "Last page conclusion"], size: 777)
        precondition(chunks.filter { $0.page == 0 }.map(\.text).joined() == longText)
        precondition(chunks.last?.page == 2 && chunks.last?.text == "Last page conclusion")
        precondition(chunks.allSatisfy { $0.text.count <= 777 })

        // A rare topic must beat generic text; explicit page 10 must not match page 1.
        let corpus = (0..<12).map { $0 == 8 ? "The catalyst is palladium." : "The study reports general findings." }
        let evidence = LiteratureContext.relevant(pages: corpus, question: "What is the catalyst?", currentPage: 0, budget: 100)
        precondition(evidence.contains { $0.page == 8 })
        let numbered = LiteratureContext.relevant(pages: corpus, question: "Explain page 10", currentPage: 0, budget: 75)
        precondition(numbered.first?.page == 9)
        let current = LiteratureContext.relevant(pages: corpus, question: "Explain this page", currentPage: 7, budget: 75)
        precondition(current.first?.page == 7)
        precondition(LiteratureContext.relevant(pages: corpus, question: "test", currentPage: 0, budget: 0).isEmpty)
        precondition(evidence.map(\.labeled).joined().count <= 100)

        // Persistence survives reopening: text, position, summary, and per-document chat.
        let config = ModelConfiguration(url: scratch.appendingPathComponent("library.store"))
        do {
            let container = try ModelContainer(for: LiteratureDocument.self, configurations: config)
            let doc = LiteratureDocument(title: "Paper", fileName: "paper.pdf", pages: pages)
            doc.currentPage = 2
            doc.summary = "Saved summary"
            doc.messages = [LiteratureMessage(isUser: false, text: "Answer", sourcePages: [0, 2])]
            container.mainContext.insert(doc)
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: LiteratureDocument.self, configurations: config)
        let restored = try reopened.mainContext.fetch(FetchDescriptor<LiteratureDocument>()).first!
        precondition(restored.pages == pages && restored.currentPage == 2 && restored.summary == "Saved summary")
        precondition(restored.messages.first?.sourcePages == [0, 2])

        // Summary visits every chunk; failed/cancelled operations never overwrite saved work.
        let container = try ModelContainer(for: LiteratureDocument.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let doc = LiteratureDocument(title: "Book", fileName: "book.pdf", pages: [longText, "Final page conclusion"])
        context.insert(doc)
        try context.save()
        let ai = LiteratureAI()
        ai.summarize(doc, context: context)
        try await wait(ai)
        precondition(ai.error == nil && !doc.summary.isEmpty)
        precondition(ChatProviderFactory.provider.requests.contains { $0.contains("Final page conclusion") })
        precondition(ChatProviderFactory.provider.requests.count > 2)
        let saved = doc.summary
        ChatProviderFactory.provider = FakeProvider()
        ChatProviderFactory.provider.fail = true
        ai.summarize(doc, context: context)
        try await wait(ai)
        precondition(ai.error != nil && doc.summary == saved)
        ai.ask("What failed?", document: doc, context: context)
        try await wait(ai)
        precondition(doc.messages.isEmpty)
        ChatProviderFactory.provider = FakeProvider()
        ChatProviderFactory.provider.delay = true
        ai.summarize(doc, context: context)
        try await Task.sleep(for: .milliseconds(30))
        ai.cancel()
        try await wait(ai)
        precondition(doc.summary == saved && ai.error == nil)
        ChatProviderFactory.provider = FakeProvider()
        ai.ask("What are the findings?", document: doc, context: context)
        try await wait(ai)
        precondition(doc.messages.count == 2 && !doc.messages[1].sourcePages.isEmpty)
        print("PASS: PDF extraction, blank/locked/invalid PDFs, Unicode chunking, retrieval, persistence, full-book summary, failure, cancellation, and saved Q&A")
    }
}

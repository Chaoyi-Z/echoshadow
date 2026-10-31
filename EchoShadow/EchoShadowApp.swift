import SwiftUI
import SwiftData

@main
struct EchoShadowApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Lesson.self, Sentence.self, SavedWord.self, PracticeDay.self, PhonemeSample.self, RehearsalRun.self, LiteratureDocument.self)
        } catch {
            fatalError("Could not open the lesson database: \(error)")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") { DemoData.seed(into: container.mainContext) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

#if DEBUG
/// Simulator-only sample data: due review sentences and scored sounds, so those screens can be checked without a mic.
@MainActor
enum DemoData {
    static func seed(into context: ModelContext) {
        let lessons = (try? context.fetch(FetchDescriptor<Lesson>())) ?? []
        if let lesson = lessons.first(where: { !$0.sentences.isEmpty }) {
            for (i, s) in lesson.orderedSentences.prefix(4).enumerated() {
                s.attempts = max(1, s.attempts)
                s.recordAttempt(score: 0.5 + Double(i) * 0.05, now: Date().addingTimeInterval(-2 * 86_400))
            }
        }
        let profile: [(String, Double, [String])] = [
            ("θ", 52, ["think", "three", "thank"]), ("ɹ", 61, ["really", "results", "research"]),
            ("v", 66, ["very", "video", "every"]), ("ð", 71, ["the", "this", "together"]),
            ("l", 76, ["lab", "will", "little"]), ("i", 89, ["see", "need"]), ("s", 93, ["so", "this"]),
        ]
        for day in 0..<20 {
            let date = Date().addingTimeInterval(-Double(day) * 86_400)
            for (p, avg, words) in profile {
                for k in 0..<3 {
                    // Recent days a bit better, so the trend arrow shows.
                    let drift = day < 7 ? 4.0 : -2.0
                    let value = max(5, min(100, avg + drift + Double((k * 7 + day * 3) % 21) - 10))
                    context.insert(PhonemeSample(phoneme: p, accuracy: value, word: words[(k + day) % words.count], date: date))
                }
            }
        }
        try? context.save()
    }

    /// A delivery of the script that skips the third sentence, adds a filler and one long pause.
    static func sampleDelivery(of script: [String]) -> [Cue] {
        var cues: [Cue] = []
        var t = 0.0
        for (i, sentence) in script.enumerated() where i != 2 {
            if i == 1 { cues.append(Cue(start: t, end: t + 0.3, text: "um")); t += 2.2 }
            for word in sentence.split(separator: " ") {
                cues.append(Cue(start: t, end: t + 0.3, text: String(word)))
                t += 0.38
            }
            t += 0.6
        }
        return cues
    }
}
#endif

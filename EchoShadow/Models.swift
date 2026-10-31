import Foundation
import SwiftData
import UniformTypeIdentifiers

enum LessonSource: String, Codable {
    case youtube
    case localFile
    case text

    var label: String {
        switch self {
        case .youtube: return "YouTube"
        case .localFile: return "File"
        case .text: return "Text"
        }
    }

    var symbol: String {
        switch self {
        case .youtube: return "play.rectangle"
        case .localFile: return "doc.badge.ellipsis"
        case .text: return "text.quote"
        }
    }
}

/// What a lesson is for. Stored as a string so new kinds never break old data.
enum LessonCategory: String, CaseIterable {
    case lesson, article, rehearsal, drill

    var sectionTitle: String {
        switch self {
        case .lesson: return "Lessons"
        case .article: return "Articles"
        case .rehearsal: return "Talk scripts"
        case .drill: return "Sound drills"
        }
    }
}

@Model
final class Lesson {
    var title: String
    var source: LessonSource
    var youtubeID: String?
    var fileName: String?
    var isVideo: Bool
    var createdAt: Date
    var lastPracticedAt: Date?
    var currentIndex: Int
    /// False when a YouTube transcript had no timestamps: the video is shown with its own controls and
    /// sentences are read by the synthetic voice instead of being played from the video.
    var isTimed: Bool = true
    /// LessonCategory raw value: "lesson", "rehearsal" (a talk script) or "drill" (generated sound practice).
    var category: String = "lesson"
    /// Web address an article lesson was imported from.
    var articleURL: String?
    /// Bookmarked lessons are pinned to the top of their section.
    var isBookmarked: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \Sentence.lesson) var sentences: [Sentence]
    @Relationship(deleteRule: .cascade, inverse: \RehearsalRun.lesson) var runs: [RehearsalRun]? = []

    init(title: String, source: LessonSource, youtubeID: String? = nil, fileName: String? = nil, isVideo: Bool = false, isTimed: Bool = true, category: LessonCategory = .lesson, articleURL: String? = nil) {
        self.title = title
        self.source = source
        self.youtubeID = youtubeID
        self.fileName = fileName
        self.isVideo = isVideo
        self.createdAt = .now
        self.currentIndex = 0
        self.isTimed = isTimed
        self.category = category.rawValue
        self.articleURL = articleURL
        self.sentences = []
    }

    var kind: LessonCategory { LessonCategory(rawValue: category) ?? .lesson }

    /// "nytimes.com" for an article lesson.
    var siteName: String? {
        guard let s = articleURL, let host = URL(string: s)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var wordCount: Int { sentences.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    var orderedSentences: [Sentence] { sentences.sorted { $0.index < $1.index } }
    var practicedCount: Int { sentences.filter { $0.attempts > 0 }.count }
    var averageScore: Double? {
        let scored = sentences.filter { $0.attempts > 0 }
        guard !scored.isEmpty else { return nil }
        return scored.map(\.bestScore).reduce(0, +) / Double(scored.count)
    }
}

@Model
final class Sentence {
    var index: Int
    var start: Double
    var end: Double
    var text: String
    var bestScore: Double
    var attempts: Int
    var lesson: Lesson?
    /// Review queue: when this sentence should come back (nil = not in the queue).
    var dueAt: Date?
    var reviewInterval: Double = 0
    var lastScore: Double = 0
    var lastAttemptAt: Date?

    init(index: Int, start: Double, end: Double, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.bestScore = 0
        self.attempts = 0
    }

    var isDue: Bool { dueAt.map { $0 <= .now } ?? false }

    /// Spaced repetition for weak sentences. Under 70% puts the sentence in tomorrow's review;
    /// strong attempts (85%+) push it further out until it graduates after about three weeks.
    func recordAttempt(score: Double, now: Date = .now) {
        lastScore = score
        lastAttemptAt = now
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        if score < 0.7 {
            reviewInterval = 1
            dueAt = cal.date(byAdding: .day, value: 1, to: startOfDay)
        } else if dueAt != nil || reviewInterval > 0 {
            if score >= 0.85 {
                reviewInterval = max(2, reviewInterval * 2.5)
                if reviewInterval > 21 {
                    reviewInterval = 0
                    dueAt = nil
                } else {
                    dueAt = cal.date(byAdding: .day, value: Int(reviewInterval.rounded()), to: startOfDay)
                }
            } else {
                reviewInterval = max(1, reviewInterval)
                dueAt = cal.date(byAdding: .day, value: 1, to: startOfDay)
            }
        }
    }
}

/// One scored sound from an Azure pronunciation assessment. Aggregated into the weak-sound tracker.
@Model
final class PhonemeSample {
    var phoneme: String
    var accuracy: Double
    var word: String
    var date: Date

    init(phoneme: String, accuracy: Double, word: String, date: Date = .now) {
        self.phoneme = phoneme
        self.accuracy = accuracy
        self.word = word
        self.date = date
    }
}

/// One full run-through of a talk script.
@Model
final class RehearsalRun {
    var date: Date
    var duration: Double
    var wordsPerMinute: Double
    var coverage: Double
    var longPauses: Int
    var fillers: Int
    var transcript: String
    var feedback: String
    var lesson: Lesson?

    init(duration: Double, wordsPerMinute: Double, coverage: Double, longPauses: Int, fillers: Int, transcript: String, feedback: String = "") {
        self.date = .now
        self.duration = duration
        self.wordsPerMinute = wordsPerMinute
        self.coverage = coverage
        self.longPauses = longPauses
        self.fillers = fillers
        self.transcript = transcript
        self.feedback = feedback
    }
}

@Model
final class SavedWord {
    var word: String
    var context: String
    var lessonTitle: String
    var createdAt: Date
    var dueAt: Date
    var intervalDays: Double
    var reviews: Int

    init(word: String, context: String, lessonTitle: String) {
        self.word = word
        self.context = context
        self.lessonTitle = lessonTitle
        self.createdAt = .now
        self.dueAt = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        self.intervalDays = 1
        self.reviews = 0
    }

    var isDue: Bool { dueAt <= .now }

    func review(remembered: Bool) {
        reviews += 1
        if remembered {
            intervalDays = max(1, (intervalDays * 2.2).rounded())
        } else {
            intervalDays = 1
        }
        dueAt = Calendar.current.date(byAdding: .day, value: Int(intervalDays), to: .now) ?? .now
    }
}

@Model
final class PracticeDay {
    var day: Date
    var sentencesPracticed: Int

    init(day: Date, sentencesPracticed: Int = 0) {
        self.day = day
        self.sentencesPracticed = sentencesPracticed
    }
}

enum MediaStore {
    static var directory: URL {
        let dir = URL.documentsDirectory.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for name: String) -> URL { directory.appending(path: name) }

    /// Copies a picked file into the app's own storage and returns its stored name.
    static func importFile(from source: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let name = UUID().uuidString + "." + ext
        let destination = url(for: name)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

extension Double {
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

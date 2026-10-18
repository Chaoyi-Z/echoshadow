import SwiftData
import SwiftUI

struct ReviewRoute: Hashable {}

enum ReviewQueue {
    static let sessionSize = 10

    /// Most overdue first, then the weakest.
    static func due(from sentences: [Sentence], now: Date = .now) -> [Sentence] {
        sentences
            .filter { $0.lesson != nil && ($0.dueAt.map { $0 <= now } ?? false) }
            .sorted { a, b in
                let da = a.dueAt ?? now, db = b.dueAt ?? now
                return da == db ? a.lastScore < b.lastScore : da < db
            }
    }

    static func upcoming(from sentences: [Sentence], now: Date = .now) -> Int {
        sentences.filter { ($0.dueAt.map { $0 > now } ?? false) }.count
    }
}

/// Walks through up to ten due sentences from any lesson, reusing the full practice screen for each.
struct ReviewSessionView: View {
    @State private var queue: [Sentence]
    @State private var position = 0
    @State private var startScores: [PersistentIdentifier: Double] = [:]

    init(due: [Sentence]) {
        let picked = Array(due.prefix(ReviewQueue.sessionSize))
        _queue = State(initialValue: picked)
        _startScores = State(initialValue: Dictionary(picked.map { ($0.persistentModelID, $0.lastScore) }, uniquingKeysWith: { a, _ in a }))
    }

    var body: some View {
        Group {
            if position < queue.count, let lesson = queue[position].lesson {
                PracticeView(lesson: lesson, only: [queue[position]],
                             review: ReviewContext(position: position, total: queue.count, onNext: { position += 1 }))
                    .id(queue[position].persistentModelID)
            } else {
                summary
            }
        }
    }

    private var summary: some View {
        let practised = queue.filter { ($0.lastAttemptAt ?? .distantPast) > Date().addingTimeInterval(-3 * 3600) }
        let improved = practised.filter { $0.lastScore > (startScores[$0.persistentModelID] ?? 0) + 0.01 }
        let cleared = practised.filter { !$0.isDue }
        return ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Review done").font(.title.bold())
                HStack(spacing: 12) {
                    tile("\(practised.count)", "practised")
                    tile("\(improved.count)", "improved")
                    tile("\(cleared.count)", "cleared for today")
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(queue, id: \.persistentModelID) { s in
                        HStack(alignment: .top) {
                            Text(s.text).font(.subheadline).lineLimit(2)
                            Spacer()
                            Text("\(Int((s.lastScore * 100).rounded()))%")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(s.lastScore >= 0.85 ? .green : (s.lastScore >= 0.7 ? .orange : .red))
                        }
                        if let due = s.dueAt {
                            Text("Next review \(due, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Graduated: out of the queue").font(.caption).foregroundStyle(.green)
                        }
                        Divider()
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("Sentences you score under 70% anywhere in the app come back here the next day. Scoring 85% or more pushes them further out until they graduate.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The "Review N" row on the Lessons tab.
struct ReviewBanner: View {
    let dueCount: Int
    let upcomingCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(dueCount > 0 ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if dueCount > 0 {
                    Text("Review \(min(dueCount, ReviewQueue.sessionSize)) sentence\(dueCount == 1 ? "" : "s")").font(.headline)
                    Text(dueCount > ReviewQueue.sessionSize
                         ? "\(dueCount) due. Your weakest sentences from all lessons."
                         : "Your weakest sentences from all lessons.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Review queue is clear").font(.headline)
                    Text(upcomingCount > 0 ? "\(upcomingCount) sentence\(upcomingCount == 1 ? "" : "s") coming back on later days." : "Sentences under 70% will come back here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

import Charts
import SwiftData
import SwiftUI

struct StatsView: View {
    @Query(sort: \PracticeDay.day) private var days: [PracticeDay]
    @Query private var lessons: [Lesson]
    @Query private var sentences: [Sentence]
    @Query private var words: [SavedWord]
    @Query(sort: \PhonemeSample.date) private var phonemeSamples: [PhonemeSample]
    @State private var drillLesson: Lesson?

    private var streak: Int {
        let cal = Calendar.current
        let practiced = Set(days.filter { $0.sentencesPracticed > 0 }.map { cal.startOfDay(for: $0.day) })
        var day = cal.startOfDay(for: .now)
        if !practiced.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day), practiced.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while practiced.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    private var last14: [(day: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let byDay = Dictionary(days.map { (cal.startOfDay(for: $0.day), $0.sentencesPracticed) }, uniquingKeysWith: +)
        return (0..<14).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (d, byDay[d] ?? 0)
        }
    }

    private var averageScore: Double? {
        let scored = sentences.filter { $0.attempts > 0 }
        guard !scored.isEmpty else { return nil }
        return scored.map(\.bestScore).reduce(0, +) / Double(scored.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        tile(value: "\(streak)", label: streak == 1 ? "day streak" : "day streak", symbol: "flame.fill", color: .orange)
                        tile(value: "\(days.map(\.sentencesPracticed).reduce(0, +))", label: "sentences", symbol: "text.bubble.fill", color: .blue)
                    }
                    HStack(spacing: 12) {
                        tile(value: averageScore.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "avg score", symbol: "star.fill", color: .green)
                        tile(value: "\(words.count)", label: "saved words", symbol: "character.book.closed.fill", color: .purple)
                    }

                    WeakSoundsCard(samples: phonemeSamples, drillLesson: $drillLesson)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last 14 days").font(.headline)
                        Chart(last14, id: \.day) { item in
                            BarMark(x: .value("Day", item.day, unit: .day), y: .value("Sentences", item.count))
                                .foregroundStyle(Color.accentColor.gradient)
                                .cornerRadius(3)
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                        .frame(height: 160)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lessons").font(.headline)
                        if lessons.isEmpty {
                            Text("Nothing yet. Add a lesson to get started.").foregroundStyle(.secondary)
                        }
                        ForEach(lessons.sorted { ($0.lastPracticedAt ?? $0.createdAt) > ($1.lastPracticedAt ?? $1.createdAt) }) { lesson in
                            HStack {
                                Image(systemName: lesson.source.symbol).foregroundStyle(Color.accentColor)
                                Text(lesson.title).lineLimit(1)
                                Spacer()
                                Text("\(lesson.practicedCount)/\(lesson.sentences.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Progress")
            .navigationDestination(for: SoundRoute.self) { SoundDetailView(phoneme: $0.phoneme, samples: phonemeSamples) }
            .navigationDestination(item: $drillLesson) { PracticeView(lesson: $0) }
        }
    }

    private func tile(value: String, label: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
